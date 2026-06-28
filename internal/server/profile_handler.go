package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/firegraph/firegraph/internal/metrics"
	"github.com/firegraph/firegraph/internal/profile"
	"github.com/firegraph/firegraph/internal/store"
)

func (s *Server) registerProfileRoutes() {
	s.router.HandleFunc("POST /api/profiles/upload", s.handleProfileUpload)
	s.router.HandleFunc("GET /api/profiles", s.handleProfileList)
	s.router.HandleFunc("GET /api/profiles/{id}", s.handleProfileGet)
	s.router.HandleFunc("GET /api/profiles/{id}/speedscope.json", s.handleProfileSpeedscope)
	s.router.HandleFunc("GET /api/profiles/{id}/folded.txt", s.handleProfileFolded)
}

// profileUploadRequest 上报请求体
type profileUploadRequest struct {
	ServiceName string `json:"service_name"`
	Node        string `json:"node"`
	SampledAt   int64  `json:"sampled_at"`    // unix 秒，0 则用服务端时间
	DurationSec int    `json:"duration_sec"`  // 采样持续时长
	FoldedText  string `json:"folded_text"`   // 折叠栈原文
}

func (s *Server) handleProfileUpload(w http.ResponseWriter, r *http.Request) {
	var req profileUploadRequest
	// 限制 body 大小 32MB，防止超大上报打爆内存
	r.Body = http.MaxBytesReader(w, r.Body, 32<<20)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json: "+err.Error())
		return
	}
	if req.ServiceName == "" || req.FoldedText == "" {
		writeError(w, http.StatusBadRequest, "service_name and folded_text required")
		return
	}
	if req.SampledAt == 0 {
		req.SampledAt = time.Now().Unix()
	}

	stacks, err := profile.ParseFolded(strings.NewReader(req.FoldedText))
	if err != nil {
		writeError(w, http.StatusBadRequest, "parse folded: "+err.Error())
		return
	}
	sampleCount := profile.SampleCount(stacks)

	p := &store.Profile{
		ServiceName: req.ServiceName,
		Node:        req.Node,
		SampledAt:   req.SampledAt,
		DurationSec: req.DurationSec,
		FoldedText:  req.FoldedText,
		SampleCount: sampleCount,
	}
	id, err := s.store.InsertProfile(r.Context(), p)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "insert: "+err.Error())
		return
	}
	// Prometheus 指标埋点
	metrics.RecordProfile(req.ServiceName, sampleCount)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"id":           id,
		"sample_count": sampleCount,
	})
}

func (s *Server) handleProfileList(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	f := store.ProfileFilter{
		ServiceName: q.Get("service"),
		Node:        q.Get("node"),
	}
	if v := q.Get("from"); v != "" {
		f.From, _ = strconv.ParseInt(v, 10, 64)
	}
	if v := q.Get("to"); v != "" {
		f.To, _ = strconv.ParseInt(v, 10, 64)
	}
	f.Limit = 100
	if v := q.Get("limit"); v != "" {
		if n, _ := strconv.Atoi(v); n > 0 && n <= 1000 {
			f.Limit = n
		}
	}
	if v := q.Get("offset"); v != "" {
		f.Offset, _ = strconv.Atoi(v)
	}
	list, err := s.store.ListProfiles(r.Context(), f)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"items": list,
	})
}

func (s *Server) handleProfileGet(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	p, err := s.store.GetProfile(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if p == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func (s *Server) handleProfileSpeedscope(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	p, err := s.store.GetProfile(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if p == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	stacks, err := profile.ParseFolded(strings.NewReader(p.FoldedText))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "parse folded: "+err.Error())
		return
	}
	name := fmt.Sprintf("%s@%s %s",
		p.ServiceName, p.Node,
		time.Unix(p.SampledAt, 0).Format("2006-01-02 15:04:05"),
	)
	ss := profile.ToSpeedscope(stacks, name)
	// speedscope 通过 hash fragment 远程加载，需 CORS
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if err := ss.WriteJSON(w); err != nil {
		// 头已写出，只能记录日志
		_ = err
	}
}

// handleProfileFolded 返回原始折叠栈文本（便于用 FlameGraph.pl 离线生成 SVG）
func (s *Server) handleProfileFolded(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	p, err := s.store.GetProfile(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if p == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=profile_%d.folded", id))
	_, _ = w.Write([]byte(p.FoldedText))
}
