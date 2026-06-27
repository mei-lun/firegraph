package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// Profile 完整 profile 记录（含折叠栈原文）
type Profile struct {
	ID          int64  `json:"id"`
	ServiceName string `json:"service_name"`
	Node        string `json:"node"`
	SampledAt   int64  `json:"sampled_at"`   // unix 秒
	DurationSec int    `json:"duration_sec"` // 采样持续时长
	FoldedText  string `json:"folded_text,omitempty"`
	SampleCount int    `json:"sample_count"`
	CreatedAt   int64  `json:"created_at"`
}

// ProfileSummary 列表摘要（不含 folded_text 大字段）
type ProfileSummary struct {
	ID          int64  `json:"id"`
	ServiceName string `json:"service_name"`
	Node        string `json:"node"`
	SampledAt   int64  `json:"sampled_at"`
	DurationSec int    `json:"duration_sec"`
	SampleCount int    `json:"sample_count"`
	CreatedAt   int64  `json:"created_at"`
}

// ProfileFilter 列表查询过滤条件
type ProfileFilter struct {
	ServiceName string
	Node        string
	From        int64 // unix 秒，0 不限
	To          int64
	Limit       int
	Offset      int
}

// InsertProfile 插入一条 profile，返回新 ID
func (s *Store) InsertProfile(ctx context.Context, p *Profile) (int64, error) {
	if p.CreatedAt == 0 {
		p.CreatedAt = time.Now().Unix()
	}
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO profiles(service_name, node, sampled_at, duration_sec, folded_text, sample_count, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		p.ServiceName, p.Node, p.SampledAt, p.DurationSec, p.FoldedText, p.SampleCount, p.CreatedAt,
	)
	if err != nil {
		return 0, fmt.Errorf("insert profile: %w", err)
	}
	return res.LastInsertId()
}

// GetProfile 按 ID 查询完整记录（含 folded_text）
func (s *Store) GetProfile(ctx context.Context, id int64) (*Profile, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT id, service_name, node, sampled_at, duration_sec, folded_text, sample_count, created_at
		 FROM profiles WHERE id = ?`, id)
	p := &Profile{}
	err := row.Scan(&p.ID, &p.ServiceName, &p.Node, &p.SampledAt, &p.DurationSec, &p.FoldedText, &p.SampleCount, &p.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get profile: %w", err)
	}
	return p, nil
}

// ListProfiles 分页查询摘要列表（按 sampled_at 倒序）
func (s *Store) ListProfiles(ctx context.Context, f ProfileFilter) ([]*ProfileSummary, error) {
	q := `SELECT id, service_name, node, sampled_at, duration_sec, sample_count, created_at FROM profiles WHERE 1=1`
	args := []interface{}{}
	if f.ServiceName != "" {
		q += " AND service_name = ?"
		args = append(args, f.ServiceName)
	}
	if f.Node != "" {
		q += " AND node = ?"
		args = append(args, f.Node)
	}
	if f.From > 0 {
		q += " AND sampled_at >= ?"
		args = append(args, f.From)
	}
	if f.To > 0 {
		q += " AND sampled_at <= ?"
		args = append(args, f.To)
	}
	q += " ORDER BY sampled_at DESC"
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
		return nil, fmt.Errorf("list profiles: %w", err)
	}
	defer rows.Close()
	var result []*ProfileSummary
	for rows.Next() {
		p := &ProfileSummary{}
		if err := rows.Scan(&p.ID, &p.ServiceName, &p.Node, &p.SampledAt, &p.DurationSec, &p.SampleCount, &p.CreatedAt); err != nil {
			return nil, err
		}
		result = append(result, p)
	}
	return result, rows.Err()
}

// DeleteOldProfiles 删除 created_at 早于 beforeTs 的 profile
func (s *Store) DeleteOldProfiles(ctx context.Context, beforeTs int64) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM profiles WHERE created_at < ?`, beforeTs)
	if err != nil {
		return 0, fmt.Errorf("delete old profiles: %w", err)
	}
	return res.RowsAffected()
}
