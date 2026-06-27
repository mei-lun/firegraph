package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Config 后端配置
type Config struct {
	Server struct {
		Addr   string `yaml:"addr"`    // 监听地址
		WebDir string `yaml:"web_dir"` // 前端静态资源目录
	} `yaml:"server"`
	Store struct {
		DSN           string `yaml:"dsn"`            // SQLite 文件路径
		RetentionDays int    `yaml:"retention_days"` // 数据保留天数（0=永久）
	} `yaml:"store"`
}

// Default 返回默认配置
func Default() *Config {
	c := &Config{}
	c.Server.Addr = ":8080"
	c.Server.WebDir = "./web"
	c.Store.DSN = "firegraph.db"
	c.Store.RetentionDays = 7
	return c
}

// Load 从 YAML 文件加载配置，未指定路径则返回默认值
func Load(path string) (*Config, error) {
	c := Default()
	if path == "" {
		return c, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	if err := yaml.Unmarshal(data, c); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	return c, nil
}
