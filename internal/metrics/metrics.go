// Package metrics 定义 Prometheus 指标，供 handler 埋点
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// TraceCount 接收的 trace 总数（按 cmd/service/ok 分维）
var TraceCount = promauto.NewCounterVec(prometheus.CounterOpts{
	Name: "firegraph_trace_count_total",
	Help: "Total traces received, partitioned by cmd/service/ok",
}, []string{"cmd", "service", "ok"})

// TraceLatency 单条 trace 耗时分布（毫秒）
// buckets 覆盖 10ms~10s，适配游戏服务器接口延迟
var TraceLatency = promauto.NewHistogramVec(prometheus.HistogramOpts{
	Name:    "firegraph_trace_latency_ms",
	Help:    "Trace latency in milliseconds",
	Buckets: []float64{10, 25, 50, 100, 200, 300, 500, 1000, 2000, 5000, 10000},
}, []string{"cmd"})

// ProfileCount 接收的 profile 总数（按 service 分维）
var ProfileCount = promauto.NewCounterVec(prometheus.CounterOpts{
	Name: "firegraph_profile_count_total",
	Help: "Total profiles received, partitioned by service",
}, []string{"service"})

// ProfileSamples 单个 profile 的采样点数分布
var ProfileSamples = promauto.NewHistogramVec(prometheus.HistogramOpts{
	Name:    "firegraph_profile_samples",
	Help:    "Sample count per profile",
	Buckets: prometheus.ExponentialBuckets(100, 2, 10), // 100~51200
}, []string{"service"})

// RecordTrace 记录单条 trace 指标
func RecordTrace(cmd, service string, costMs int, ok bool) {
	okStr := "true"
	if !ok {
		okStr = "false"
	}
	TraceCount.WithLabelValues(cmd, service, okStr).Inc()
	TraceLatency.WithLabelValues(cmd).Observe(float64(costMs))
}

// RecordProfile 记录单个 profile 指标
func RecordProfile(service string, sampleCount int) {
	ProfileCount.WithLabelValues(service).Inc()
	ProfileSamples.WithLabelValues(service).Observe(float64(sampleCount))
}
