package store

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strings"
)

// Trace 一条接口耗时记录
type Trace struct {
	ID      int64  `json:"id"`
	Ts      int64  `json:"ts"`      // unix 秒
	Service string `json:"service"`
	Proto   string `json:"proto"`
	Cmd     string `json:"cmd"`
	Session int64  `json:"session"` // -1 表示无 session
	CostMs  int    `json:"cost_ms"`
	Ok      bool   `json:"ok"`
}

// TraceFilter 查询过滤
type TraceFilter struct {
	Service string
	Cmd     string
	From    int64 // unix 秒
	To      int64
	Limit   int
	Offset  int
}

// TraceStat 聚合统计行
type TraceStat struct {
	Service string `json:"service"`
	Cmd     string `json:"cmd"`
	Count   int    `json:"count"`
	OkCount int    `json:"ok_count"`
	AvgMs   int    `json:"avg_ms"`
	MaxMs   int    `json:"max_ms"`
	MinMs   int    `json:"min_ms"`
	P50Ms   int    `json:"p50_ms"`
	P95Ms   int    `json:"p95_ms"`
	P99Ms   int    `json:"p99_ms"`
}

// TraceBucket 时间序列一个桶
type TraceBucket struct {
	Ts     int64 `json:"ts"`      // 桶起始 unix 秒
	Count  int   `json:"count"`
	AvgMs  int   `json:"avg_ms"`
	P95Ms  int   `json:"p95_ms"`
}

// InsertTraces 批量插入 trace
// session 为 -1 时写 NULL
func (s *Store) InsertTraces(ctx context.Context, traces []Trace) (int64, error) {
	if len(traces) == 0 {
		return 0, nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx,
		`INSERT INTO traces(ts, service, proto, cmd, session, cost_ms, ok) VALUES (?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return 0, fmt.Errorf("prepare: %w", err)
	}
	defer stmt.Close()

	var inserted int64
	for _, t := range traces {
		var sessionVal interface{}
		if t.Session > 0 {
			sessionVal = t.Session
		}
		okVal := 0
		if t.Ok {
			okVal = 1
		}
		res, err := stmt.ExecContext(ctx, t.Ts, t.Service, t.Proto, t.Cmd, sessionVal, t.CostMs, okVal)
		if err != nil {
			return inserted, fmt.Errorf("insert trace: %w", err)
		}
		n, _ := res.RowsAffected()
		inserted += n
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}
	return inserted, nil
}

// QueryTraces 分页查询明细
func (s *Store) QueryTraces(ctx context.Context, f TraceFilter) ([]*Trace, error) {
	q := `SELECT id, ts, service, proto, cmd, session, cost_ms, ok FROM traces WHERE 1=1`
	args := []interface{}{}
	if f.Service != "" {
		q += " AND service = ?"
		args = append(args, f.Service)
	}
	if f.Cmd != "" {
		q += " AND cmd = ?"
		args = append(args, f.Cmd)
	}
	if f.From > 0 {
		q += " AND ts >= ?"
		args = append(args, f.From)
	}
	if f.To > 0 {
		q += " AND ts <= ?"
		args = append(args, f.To)
	}
	q += " ORDER BY ts DESC"
	if f.Limit > 0 {
		q += " LIMIT ?"
		args = append(args, f.Limit)
		if f.Offset > 0 {
			q += " OFFSET ?"
			args = append(args, f.Offset)
		}
	}
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("query traces: %w", err)
	}
	defer rows.Close()
	var result []*Trace
	for rows.Next() {
		t := &Trace{Session: -1}
		var session sql.NullInt64
		var okInt int
		if err := rows.Scan(&t.ID, &t.Ts, &t.Service, &t.Proto, &t.Cmd, &session, &t.CostMs, &okInt); err != nil {
			return nil, err
		}
		if session.Valid {
			t.Session = session.Int64
		}
		t.Ok = okInt == 1
		result = append(result, t)
	}
	return result, rows.Err()
}

// AggregateStats 聚合统计：按 service+cmd 分组，返回 count/avg/max + 分位数（内存计算）
// percentiles 参数当前固定返回 50/95/99
func (s *Store) AggregateStats(ctx context.Context, f TraceFilter) ([]*TraceStat, error) {
	// 1. 拉分组基础统计
	q := `SELECT service, cmd, COUNT(*), SUM(CASE WHEN ok=1 THEN 1 ELSE 0 END), AVG(cost_ms), MAX(cost_ms), MIN(cost_ms)
	      FROM traces WHERE 1=1`
	args := []interface{}{}
	if f.Service != "" {
		q += " AND service = ?"
		args = append(args, f.Service)
	}
	if f.Cmd != "" {
		q += " AND cmd = ?"
		args = append(args, f.Cmd)
	}
	if f.From > 0 {
		q += " AND ts >= ?"
		args = append(args, f.From)
	}
	if f.To > 0 {
		q += " AND ts <= ?"
		args = append(args, f.To)
	}
	q += " GROUP BY service, cmd ORDER BY AVG(cost_ms) DESC"
	if f.Limit > 0 {
		q += " LIMIT ?"
		args = append(args, f.Limit)
	}
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("aggregate stats: %w", err)
	}
	defer rows.Close()
	var stats []*TraceStat
	for rows.Next() {
		st := &TraceStat{}
		var avg float64
		if err := rows.Scan(&st.Service, &st.Cmd, &st.Count, &st.OkCount, &avg, &st.MaxMs, &st.MinMs); err != nil {
			return nil, err
		}
		st.AvgMs = int(avg)
		stats = append(stats, st)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// 2. 每组拉 cost_ms 排序数组，计算分位数
	for _, st := range stats {
		costs, err := s.queryCostsSorted(ctx, st.Service, st.Cmd, f.From, f.To)
		if err != nil {
			return nil, err
		}
		st.P50Ms = percentile(costs, 50)
		st.P95Ms = percentile(costs, 95)
		st.P99Ms = percentile(costs, 99)
	}
	return stats, nil
}

// queryCostsSorted 拉取指定 service+cmd 的所有 cost_ms（已排序）
func (s *Store) queryCostsSorted(ctx context.Context, service, cmd string, from, to int64) ([]int, error) {
	q := `SELECT cost_ms FROM traces WHERE service = ? AND cmd = ?`
	args := []interface{}{service, cmd}
	if from > 0 {
		q += " AND ts >= ?"
		args = append(args, from)
	}
	if to > 0 {
		q += " AND ts <= ?"
		args = append(args, to)
	}
	q += " ORDER BY cost_ms"
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var costs []int
	for rows.Next() {
		var c int
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		costs = append(costs, c)
	}
	return costs, rows.Err()
}

// percentile 计算分位数（costs 已升序）
func percentile(sorted []int, p int) int {
	if len(sorted) == 0 {
		return 0
	}
	if len(sorted) == 1 {
		return sorted[0]
	}
	// 线性插值法
	idx := float64(p) / 100.0 * float64(len(sorted)-1)
	lower := int(idx)
	upper := lower + 1
	if upper >= len(sorted) {
		return sorted[len(sorted)-1]
	}
	frac := idx - float64(lower)
	return int(float64(sorted[lower])*(1-frac) + float64(sorted[upper])*frac)
}

// QueryTimeseries 时间序列聚合（按 bucket_sec 分桶）
func (s *Store) QueryTimeseries(ctx context.Context, f TraceFilter, bucketSec int) ([]*TraceBucket, error) {
	if bucketSec <= 0 {
		bucketSec = 60
	}
	// 用 SQL 按 bucket 分组拉 count 和 avg，P95 在内存计算
	q := `SELECT (ts / ?) * ? AS bucket, COUNT(*), AVG(cost_ms) FROM traces WHERE 1=1`
	args := []interface{}{bucketSec, bucketSec}
	if f.Service != "" {
		q += " AND service = ?"
		args = append(args, f.Service)
	}
	if f.Cmd != "" {
		q += " AND cmd = ?"
		args = append(args, f.Cmd)
	}
	if f.From > 0 {
		q += " AND ts >= ?"
		args = append(args, f.From)
	}
	if f.To > 0 {
		q += " AND ts <= ?"
		args = append(args, f.To)
	}
	q += " GROUP BY bucket ORDER BY bucket"
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("timeseries: %w", err)
	}
	defer rows.Close()
	var buckets []*TraceBucket
	for rows.Next() {
		b := &TraceBucket{}
		var avg float64
		if err := rows.Scan(&b.Ts, &b.Count, &avg); err != nil {
			return nil, err
		}
		b.AvgMs = int(avg)
		buckets = append(buckets, b)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// 每个桶的 P95：单独查询（数据量大时可优化为 window function）
	for _, b := range buckets {
		costs, err := s.queryCostsInBucket(ctx, f, b.Ts, b.Ts+int64(bucketSec))
		if err != nil {
			return nil, err
		}
		sort.Ints(costs)
		b.P95Ms = percentile(costs, 95)
	}
	return buckets, nil
}

func (s *Store) queryCostsInBucket(ctx context.Context, f TraceFilter, from, to int64) ([]int, error) {
	q := `SELECT cost_ms FROM traces WHERE ts >= ? AND ts < ?`
	args := []interface{}{from, to}
	if f.Service != "" {
		q += " AND service = ?"
		args = append(args, f.Service)
	}
	if f.Cmd != "" {
		q += " AND cmd = ?"
		args = append(args, f.Cmd)
	}
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var costs []int
	for rows.Next() {
		var c int
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		costs = append(costs, c)
	}
	return costs, rows.Err()
}

// DeleteOldTraces 删除 ts 早于 beforeTs 的 trace
func (s *Store) DeleteOldTraces(ctx context.Context, beforeTs int64) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM traces WHERE ts < ?`, beforeTs)
	if err != nil {
		return 0, fmt.Errorf("delete old traces: %w", err)
	}
	return res.RowsAffected()
}

// parseNDJSONTraces 解析 NDJSON（每行一个 JSON 对象）为 Trace 数组
// 容错：跳过格式错误的行
func ParseNDJSONTraces(data string) ([]Trace, error) {
	var traces []Trace
	lines := strings.Split(data, "\n")
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		t, err := parseOneTrace(line)
		if err != nil {
			// 跳过错误行，记录到 stderr 由调用方处理
			_ = fmt.Errorf("line %d parse error: %w", i, err)
			continue
		}
		traces = append(traces, t)
	}
	return traces, nil
}

// parseOneTrace 解析单行 JSON（手写以避免引入 encoding/json 的反射开销）
// 期望字段：ts, service, proto, cmd, session(可空), cost_ms, ok
func parseOneTrace(line string) (Trace, error) {
	t := Trace{Session: -1}
	// 简易 JSON 字段提取（足够 NDJSON 上报格式）
	if v, ok := jsonGetNumber(line, "ts"); ok {
		t.Ts = int64(v)
	}
	t.Service, _ = jsonGetString(line, "service")
	t.Proto, _ = jsonGetString(line, "proto")
	t.Cmd, _ = jsonGetString(line, "cmd")
	if v, ok := jsonGetNumber(line, "session"); ok {
		t.Session = int64(v)
	}
	if v, ok := jsonGetNumber(line, "cost_ms"); ok {
		t.CostMs = int(v)
	}
	// ok 字段：优先按 boolean 解析，兼容字符串 "true"/"false"
	if v, found := jsonGetBool(line, "ok"); found {
		t.Ok = v
	} else if v, ok := jsonGetString(line, "ok"); ok {
		t.Ok = v == "true"
	}
	if t.Service == "" || t.Cmd == "" {
		return t, fmt.Errorf("missing service or cmd")
	}
	return t, nil
}

// jsonGetBool 提取 boolean 字段（"key":true / "key":false）
func jsonGetBool(s, key string) (bool, bool) {
	pat := `"` + key + `":`
	idx := indexOf(s, pat)
	if idx < 0 {
		return false, false
	}
	start := idx + len(pat)
	for start < len(s) && (s[start] == ' ' || s[start] == '\t') {
		start++
	}
	if start+4 <= len(s) && s[start:start+4] == "true" {
		return true, true
	}
	if start+5 <= len(s) && s[start:start+5] == "false" {
		return false, true
	}
	return false, false
}

// --- 极简 JSON 字段提取（仅适配本工具上报格式） ---
func jsonGetString(s, key string) (string, bool) {
	// 匹配 "key":"value"
	pat := `"` + key + `":"`
	idx := indexOf(s, pat)
	if idx < 0 {
		return "", false
	}
	start := idx + len(pat)
	end := start
	for end < len(s) {
		if s[end] == '\\' {
			end += 2
			continue
		}
		if s[end] == '"' {
			break
		}
		end++
	}
	if end > len(s) {
		return "", false
	}
	return s[start:end], true
}

func jsonGetNumber(s, key string) (float64, bool) {
	// 匹配 "key":number 或 "key":null
	pat := `"` + key + `":`
	idx := indexOf(s, pat)
	if idx < 0 {
		return 0, false
	}
	start := idx + len(pat)
	// 跳过空白
	for start < len(s) && (s[start] == ' ' || s[start] == '\t') {
		start++
	}
	if start >= len(s) {
		return 0, false
	}
	if s[start] == 'n' { // null
		return 0, false
	}
	end := start
	for end < len(s) && (isDigit(s[end]) || s[end] == '.' || s[end] == '-' || s[end] == '+' || s[end] == 'e' || s[end] == 'E') {
		end++
	}
	numStr := s[start:end]
	if numStr == "" {
		return 0, false
	}
	var f float64
	_, err := fmt.Sscanf(numStr, "%f", &f)
	if err != nil {
		return 0, false
	}
	return f, true
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
