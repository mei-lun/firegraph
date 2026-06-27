// Package store 封装 SQLite 存储层
package store

import (
	"database/sql"
	_ "embed"
	"fmt"

	_ "modernc.org/sqlite" // 纯 Go SQLite 驱动，无需 CGO
)

//go:embed schema.sql
var schemaSQL string

// Store SQLite 存储句柄
type Store struct {
	db *sql.DB
}

// Open 打开 SQLite 数据库并初始化 schema
func Open(dsn string) (*Store, error) {
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// 启用 WAL 模式，提升并发写入性能
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("set WAL: %w", err)
	}
	// 设置忙等待，避免并发写入报错
	if _, err := db.Exec("PRAGMA busy_timeout=5000"); err != nil {
		db.Close()
		return nil, fmt.Errorf("set busy_timeout: %w", err)
	}
	if _, err := db.Exec(schemaSQL); err != nil {
		db.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &Store{db: db}, nil
}

// Close 关闭数据库
func (s *Store) Close() error {
	return s.db.Close()
}

// DB 暴露底层 *sql.DB 供 repo 使用
func (s *Store) DB() *sql.DB {
	return s.db
}
