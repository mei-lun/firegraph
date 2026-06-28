// Package server 实现 HTTP API + 前端静态资源服务
package server

import (
	"context"
	"log"
	"net/http"
	"strings"

	"github.com/firegraph/firegraph/internal/config"
	"github.com/firegraph/firegraph/internal/store"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Server HTTP 服务
type Server struct {
	cfg     *config.Config
	store   *store.Store
	router  *http.ServeMux
	httpSrv *http.Server
}

// New 创建服务实例
func New(cfg *config.Config, st *store.Store) *Server {
	s := &Server{
		cfg:    cfg,
		store:  st,
		router: http.NewServeMux(),
	}
	s.registerRoutes()
	return s
}

func (s *Server) registerRoutes() {
	// 健康检查
	s.router.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// API 路由（具体 handler 在后续阶段注册）
	s.registerProfileRoutes()
	s.registerTraceRoutes()

	// Prometheus 指标端点
	s.router.Handle("/metrics", promhttp.Handler())

	// 前端静态资源（SPA 风格：/ 直接访问首页，其它路径映射到 web/ 下文件）
	fs := http.FileServer(http.Dir(s.cfg.Server.WebDir))
	s.router.HandleFunc("/", s.serveWeb(fs))
}

// serveWeb 处理前端静态资源，对未知路径返回 index.html
func (s *Server) serveWeb(fs http.Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// API / 健康检查 / metrics 路径不走静态资源
		if strings.HasPrefix(r.URL.Path, "/api/") || r.URL.Path == "/healthz" || r.URL.Path == "/metrics" {
			http.NotFound(w, r)
			return
		}
		fs.ServeHTTP(w, r)
	}
}

// Start 启动 HTTP 服务（阻塞）
func (s *Server) Start() error {
	s.httpSrv = &http.Server{
		Addr:    s.cfg.Server.Addr,
		Handler: s.router,
	}
	log.Printf("firegraph server listening on %s", s.cfg.Server.Addr)
	return s.httpSrv.ListenAndServe()
}

// Shutdown 优雅关闭
func (s *Server) Shutdown(ctx context.Context) error {
	if s.httpSrv == nil {
		return nil
	}
	return s.httpSrv.Shutdown(ctx)
}
