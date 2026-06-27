package server

import (
	"io"
	"net/http"
	"strconv"

	"github.com/firegraph/firegraph/internal/store"
)

// registerTraceRoutes 注册 trace 相关路由（覆盖占位实现）
func (s *Server) registerTraceRoutes() {
	s.router.HandleFunc("POST /api/traces/batch", s.handleTraceBatch)
	s.router.HandleFunc("GET /api/traces", s.handleTraceList)
	s.router.HandleFunc("GET /api/traces/stats", s.handleTraceStats)
	s.router.HandleFunc("GET /api/traces/timeseries", s.handleTraceTimeseries)
}

// handleTraceBatch 接收 NDJSON 批量上报
// Body：每行一个 JSON 对象
func (s *Server) handleTraceBatch(w http.ResponseWriter, r *http.Request) {
	// 限制 body 8MB
	r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "read body: "+err.Error())
		return
	}
	traces, err := store.ParseNDJSONTraces(string(data))
	if err != nil {
		writeError(w, http.StatusBadRequest, "parse: "+err.Error())
		return
	}
	if len(traces) == 0 {
		writeJSON(w, http.StatusOK, map[string]interface{}{"inserted": 0})
		return
	}
	n, err := s.store.InsertTraces(r.Context(), traces)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "insert: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"inserted":  n,
		"received":  len(traces),
	})
}

// handleTraceList 明细列表
func (s *Server) handleTraceList(w http.ResponseWriter, r *http.Request) {
	f := parseTraceFilter(r)
	list, err := s.store.QueryTraces(r.Context(), f)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"items": list})
}

// handleTraceStats 聚合统计
func (s *Server) handleTraceStats(w http.ResponseWriter, r *http.Request) {
	f := parseTraceFilter(r)
	stats, err := s.store.AggregateStats(r.Context(), f)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"items": stats})
}

// handleTraceTimeseries 时间序列
func (s *Server) handleTraceTimeseries(w http.ResponseWriter, r *http.Request) {
	f := parseTraceFilter(r)
	bucketSec := 60
	if v := r.URL.Query().Get("bucket_sec"); v != "" {
		if n, _ := strconv.Atoi(v); n > 0 {
			bucketSec = n
		}
	}
	buckets, err := s.store.QueryTimeseries(r.Context(), f, bucketSec)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"items": buckets})
}

// parseTraceFilter 从 query 解析过滤条件
func parseTraceFilter(r *http.Request) store.TraceFilter {
	q := r.URL.Query()
	f := store.TraceFilter{
		Service: q.Get("service"),
		Cmd:     q.Get("cmd"),
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
	return f
}
