# firegraph 代码设计文档

| 项 | 内容 |
|---|---|
| 文档版本 | v1.0 |
| 上游输入 | [需求文档](./01-REQUIREMENTS.md)、[需求分析文档](./02-REQUIREMENTS_ANALYSIS.md) |
| 创建日期 | 2026-06-28 |
| 文档状态 | 已实现 |
| 目标读者 | 研发 / 架构师 / AI 辅助开发工具 |
| 用途 | 系统架构设计、模块接口定义、数据结构、核心算法、技术选型的权威说明 |

---

## 目录

1. [设计概述](#1-设计概述)
2. [系统架构设计](#2-系统架构设计)
3. [模块接口定义](#3-模块接口定义)
4. [数据结构设计](#4-数据结构设计)
5. [核心算法设计](#5-核心算法设计)
6. [技术选型说明](#6-技术选型说明)
7. [关键流程时序图](#7-关键流程时序图)
8. [异常处理与容错设计](#8-异常处理与容错设计)
9. [部署与构建设计](#9-部署与构建设计)
10. [设计权衡与决策记录](#10-设计权衡与决策记录)

---

## 1. 设计概述

### 1.1 设计目标

围绕 [PRD](./01-REQUIREMENTS.md) §2 的可量化目标，本设计达成：

| 目标 | 设计回应 |
|---|---|
| G-1 CPU 火焰图可视化 | Lua `debug.sethook` 采样 → Folded Stacks → speedscope `sampled` JSON → 浏览器三视图 |
| G-2 接口耗时分位统计 | 包装 `skynet.dispatch` → 批量 NDJSON 上报 → SQL 聚合 + 内存分位数 → SVG 趋势图 |
| G-3 无侵入接入 | skynet preload 钩子 + dispatch 函数替换，业务代码零改动 |
| G-4 单二进制部署 | Go 静态编译 + `modernc.org/sqlite` 纯 Go 驱动，无 CGO |
| G-5 内网零依赖 | 前端原生 JS + SVG + speedscope 离线包，无 CDN |
| G-6 性能开销可控 | 采样阈值 5000 行/次、批量 100 条/5s 上报、`skynet.fork` 异步上报 |

### 1.2 设计原则

1. **契约优先**：模块间通过明确接口（HTTP/JSON、Go 方法签名、Lua 模块 API）通信。
2. **关注点分离**：存储层不写 SQL 到 handler；profile 包纯函数无状态；前端无业务逻辑。
3. **最小侵入**：Skynet 端仅通过 preload 注入，业务无感知。
4. **渐进增强**：内置采样器兜底，swt 可选升级；MVP 不做鉴权，公网部署可加反代。
5. **失败隔离**：上报失败不阻塞业务；解析错误跳过单行不阻塞整批。

### 1.3 系统边界

- **本系统负责**：采集、上报、存储、聚合、可视化。
- **本系统不负责**：业务逻辑、Skynet 调度、玩家数据、鉴权、告警（v2+）。

---

## 2. 系统架构设计

### 2.1 分层架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    表现层（Presentation）                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐      │
│  │ index.html  │  │ profiles.html│  │ traces.html         │      │
│  │ 首页导航    │  │ + app.js     │  │ + app.js            │      │
│  │             │  │ ProfilesPage │  │ TracesPage + SVG    │      │
│  └─────────────┘  └─────────────┘  └─────────────────────┘      │
│  ┌─────────────────────────────────────────────────────┐        │
│  │ speedscope 离线包（vendor/speedscope/）              │        │
│  └─────────────────────────────────────────────────────┘        │
└────────────────────────────┬────────────────────────────────────┘
                             │ HTTP/JSON
┌────────────────────────────┴────────────────────────────────────┐
│                    接入层（API Gateway）                         │
│  internal/server/                                               │
│  ┌─────────────────────────────────────────────────────┐        │
│  │ Go 1.22+ http.ServeMux                              │        │
│  │ ├ /healthz                                          │        │
│  │ ├ /api/profiles/*  (5 routes)                       │        │
│  │ ├ /api/traces/*    (4 routes)                       │        │
│  │ └ /                (静态资源)                       │        │
│  └─────────────────────────────────────────────────────┘        │
└────────────────────────────┬────────────────────────────────────┘
                             │ 函数调用
┌────────────────────────────┴────────────────────────────────────┐
│                    业务层（Business）                            │
│  ┌─────────────────────┐  ┌─────────────────────────────┐       │
│  │ internal/profile/   │  │ internal/store/ (repo)      │       │
│  │ ├ folded.go         │  │ ├ profile_repo.go           │       │
│  │ │  ParseFolded()    │  │ │  InsertProfile/Query...   │       │
│  │ └ speedscope.go     │  │ └ trace_repo.go             │       │
│  │    ToSpeedscope()   │  │    InsertTraces/Aggregate.. │       │
│  └─────────────────────┘  └─────────────────────────────┘       │
└────────────────────────────┬────────────────────────────────────┘
                             │ SQL
┌────────────────────────────┴────────────────────────────────────┐
│                    存储层（Storage）                             │
│  ┌─────────────────────────────────────────────────────┐        │
│  │ SQLite (modernc.org/sqlite 纯 Go 驱动)              │        │
│  │ ├ WAL 模式 + busy_timeout=5000ms                    │        │
│  │ ├ profiles 表（含 folded_text 大字段）              │        │
│  │ └ traces 表（含 service/cmd/ts 索引）               │        │
│  └─────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────┘

           ╔═══════════════════════════════════════════╗
           ║   采集层（独立部署单元：Skynet 端 Lua）   ║
           ║                                           ║
           ║   preload.lua                             ║
           ║      ↓                                    ║
           ║   firegraph/init.lua                      ║
           ║      ├ swt_bridge.lua (采样器)            ║
           ║      ├ tracer.lua      (dispatch 埋点)    ║
           ║      └ reporter.lua    (HTTP 上报)       ║
           ║                                           ║
           ║   通过 HTTP/JSON 上报到接入层             ║
           ╚═══════════════════════════════════════════╝
```

### 2.2 部署架构

```
┌──────────────────────┐       ┌──────────────────────┐
│  Skynet 服务器集群   │       │  firegraph 后端      │
│  (Linux, 多节点)     │       │  (Linux, 单实例)     │
│                      │       │                      │
│  node1:              │       │  firegraph.exe       │
│   ├ snlua: login     │ HTTP  │   ├ HTTP :8080       │
│   ├ snlua: game      │ ────► │   ├ SQLite WAL       │
│   └ snlua: chat      │       │   └ web/ 静态资源    │
│                      │       │                      │
│  node2: ...          │       │  数据卷:             │
│                      │       │   firegraph.db       │
└──────────────────────┘       │   firegraph.db-wal   │
                               │   firegraph.db-shm   │
                               └──────┬───────────────┘
                                      │ HTTP
                                      ▼
                               ┌──────────────────────┐
                               │  运维浏览器          │
                               │  (内网)              │
                               │   ├ /profiles.html   │
                               │   ├ /traces.html     │
                               │   └ speedscope       │
                               └──────────────────────┘
```

### 2.3 组件职责

| 组件 | 部署单元 | 职责 | 关键约束 |
|---|---|---|---|
| preload | Skynet 端 | snlua 启动钩子 | 仅运行一次 |
| sampler | Skynet 端 | Lua 调用栈采样 | 不阻塞业务协程 |
| tracer | Skynet 端 | dispatch 包装 | 异步上报 |
| reporter | Skynet 端 | HTTP 上报 | 重试 3 次后丢弃 |
| server | 后端 | HTTP 路由 + 静态资源 | 单二进制 |
| store | 后端 | SQLite CRUD + 聚合 | WAL 模式 |
| profile | 后端 | 折叠栈解析 + 转换 | 纯函数无状态 |
| 前端 | 浏览器 | UI + SVG 图表 | 无构建链 |

---

## 3. 模块接口定义

### 3.1 Skynet 端 Lua API

#### 3.1.1 `firegraph` 模块（`skynet-agent/lua/firegraph/init.lua`）

```lua
local M = {}

-- 初始化（必调用一次）
-- @param opts table
--   server_host           string  后端地址（默认 "127.0.0.1"）
--   server_port           number  后端端口（默认 8080）
--   service               string  当前服务名
--   node                  string  节点名（默认 "default"）
--   auto_profile_interval number  自动采样间隔秒（0=不自动，默认 0）
--   auto_profile_duration number  每次采样持续秒（默认 30）
function M.init(opts) end

-- 启动一次采样
-- @param duration_sec number 采样持续秒数（默认 30）
-- @return boolean 是否成功启动（已在采样中返回 false）
function M.start_profile(duration_sec) end

-- 手动停止采样
-- @return boolean 是否成功停止（未在采样返回 false）
function M.stop_profile() end

-- 安装接口埋点（替换 skynet.dispatch）
-- @return boolean 是否安装成功
function M.install_tracer() end

-- 业务在 handler 内调用，标记当前消息的 cmd
-- @param cmd string 命令名
function M.tag_cmd(cmd) end

-- 读取运行时配置（供 tracer 内部使用）
function M.get_config() end

return M
```

#### 3.1.2 `sampler` 模块（`swt_bridge.lua`）

```lua
local M = {}

-- 注册采样完成回调
-- @param cb function(folded_text string, sample_total number)
function M.on_complete(cb) end

-- 启动采样
-- @param duration_sec number 采样持续秒数（仅用于记录）
-- @return boolean
function M.start(duration_sec) end

-- 停止采样，触发 on_complete 回调
-- @return nil
function M.stop() end

return M
```

#### 3.1.3 `tracer` 模块（`tracer.lua`）

```lua
local M = {}

-- 安装埋点（替换 skynet.dispatch）
-- @param cfg   table  firegraph 配置
-- @param rep   table  reporter 模块实例
function M.install(cfg, rep) end

-- 业务在 handler 内调用，标记当前协程的 cmd
-- @param cmd string
function M.tag_cmd(cmd) end

return M
```

#### 3.1.4 `reporter` 模块（`reporter.lua`）

```lua
local M = {}

-- 初始化
-- @param h string  后端 host
-- @param p number  后端 port
function M.init(h, p) end

-- 上报一次 profile
-- @param service      string
-- @param node         string
-- @param sampled_at   number  unix 秒
-- @param duration_sec number
-- @param folded_text  string
-- @return boolean 是否成功
function M.report_profile(service, node, sampled_at, duration_sec, folded_text) end

-- 批量上报接口耗时
-- @param traces table  数组，每个元素 {ts, service, proto, cmd, session, cost_ms, ok}
-- @return boolean
function M.report_traces(traces) end

return M
```

### 3.2 后端 Go 接口

#### 3.2.1 `config.Config`（`internal/config/config.go`）

```go
type Config struct {
    Server struct {
        Addr   string `yaml:"addr"`    // 监听地址，默认 ":8080"
        WebDir string `yaml:"web_dir"` // 前端目录，默认 "./web"
    } `yaml:"server"`
    Store struct {
        DSN           string `yaml:"dsn"`            // SQLite 路径，默认 "firegraph.db"
        RetentionDays int    `yaml:"retention_days"` // 保留天数，默认 7，0=永久
    } `yaml:"store"`
}

func Default() *Config
func Load(path string) (*Config, error)  // path 为空返回 Default
```

#### 3.2.2 `store.Store`（`internal/store/store.go`）

```go
type Store struct {
    db *sql.DB
}

func Open(dsn string) (*Store, error)  // 打开 + WAL + busy_timeout + schema
func (s *Store) Close() error
func (s *Store) DB() *sql.DB           // 暴露给 repo 用
```

#### 3.2.3 `store.Profile` 与 Profile Repo（`profile_repo.go`）

```go
type Profile struct {
    ID          int64  `json:"id"`
    ServiceName string `json:"service_name"`
    Node        string `json:"node"`
    SampledAt   int64  `json:"sampled_at"`
    DurationSec int    `json:"duration_sec"`
    FoldedText  string `json:"folded_text,omitempty"`
    SampleCount int    `json:"sample_count"`
    CreatedAt   int64  `json:"created_at"`
}

type ProfileSummary struct { /* 不含 FoldedText，其余同 Profile */ }

type ProfileFilter struct {
    ServiceName string
    Node        string
    From, To    int64  // unix 秒，0 不限
    Limit, Offset int
}

func (s *Store) InsertProfile(ctx, *Profile) (int64, error)
func (s *Store) GetProfile(ctx, id int64) (*Profile, error)  // 未找到返回 (nil, nil)
func (s *Store) ListProfiles(ctx, ProfileFilter) ([]*ProfileSummary, error)
func (s *Store) DeleteOldProfiles(ctx, beforeTs int64) (int64, error)
```

#### 3.2.4 `store.Trace` 与 Trace Repo（`trace_repo.go`）

```go
type Trace struct {
    ID      int64  `json:"id"`
    Ts      int64  `json:"ts"`
    Service string `json:"service"`
    Proto   string `json:"proto"`
    Cmd     string `json:"cmd"`
    Session int64  `json:"session"`  // -1 表示无
    CostMs  int    `json:"cost_ms"`
    Ok      bool   `json:"ok"`
}

type TraceFilter struct {
    Service, Cmd string
    From, To     int64
    Limit, Offset int
}

type TraceStat struct {
    Service, Cmd string
    Count, OkCount, AvgMs, MaxMs, MinMs int
    P50Ms, P95Ms, P99Ms int
}

type TraceBucket struct {
    Ts     int64
    Count, AvgMs, P95Ms int
}

func (s *Store) InsertTraces(ctx, []Trace) (int64, error)
func (s *Store) QueryTraces(ctx, TraceFilter) ([]*Trace, error)
func (s *Store) AggregateStats(ctx, TraceFilter) ([]*TraceStat, error)
func (s *Store) QueryTimeseries(ctx, TraceFilter, bucketSec int) ([]*TraceBucket, error)
func (s *Store) DeleteOldTraces(ctx, beforeTs int64) (int64, error)

func ParseNDJSONTraces(data string) ([]Trace, error)  // 容错跳过错误行
```

#### 3.2.5 `profile` 包（`internal/profile/`）

```go
type FoldedStack struct {
    Frames []string  // [main, foo, bar]，main 在最底
    Count  int
}

func ParseFolded(r io.Reader) ([]FoldedStack, error)  // 16MB 单行缓冲
func SampleCount(stacks []FoldedStack) int

type SpeedscopeFile struct {
    Schema   string             `json:"$schema"`
    Shared   SpeedscopeShared   `json:"shared"`
    Profiles []SpeedscopeProfile `json:"profiles"`
}

func ToSpeedscope(stacks []FoldedStack, profileName string) *SpeedscopeFile
func (f *SpeedscopeFile) WriteJSON(w io.Writer) error
```

#### 3.2.6 `server.Server`（`internal/server/server.go`）

```go
type Server struct {
    cfg     *config.Config
    store   *store.Store
    router  *http.ServeMux
    httpSrv *http.Server
}

func New(cfg *config.Config, st *store.Store) *Server
func (s *Server) Start() error          // 阻塞 ListenAndServe
func (s *Server) Shutdown(ctx) error    // 优雅关闭
```

### 3.3 HTTP API 接口

#### 3.3.1 Profile 路由

| 方法 | 路径 | Handler | 说明 |
|---|---|---|---|
| POST | `/api/profiles/upload` | `handleProfileUpload` | body 32MB 上限 |
| GET | `/api/profiles` | `handleProfileList` | limit 默认 100，上限 1000 |
| GET | `/api/profiles/{id}` | `handleProfileGet` | 含 folded_text |
| GET | `/api/profiles/{id}/speedscope.json` | `handleProfileSpeedscope` | 带 CORS 头 |
| GET | `/api/profiles/{id}/folded.txt` | `handleProfileFolded` | 附件下载 |

#### 3.3.2 Trace 路由

| 方法 | 路径 | Handler | 说明 |
|---|---|---|---|
| POST | `/api/traces/batch` | `handleTraceBatch` | NDJSON，body 8MB |
| GET | `/api/traces` | `handleTraceList` | 明细分页 |
| GET | `/api/traces/stats` | `handleTraceStats` | 聚合统计 |
| GET | `/api/traces/timeseries` | `handleTraceTimeseries` | 时间序列 |

#### 3.3.3 其他路由

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/healthz` | 返回 200 "ok" |
| GET | `/` | 前端静态资源（`/api/*` 与 `/healthz` 不走静态） |

### 3.4 前端模块接口（`web/assets/app.js`）

```js
window.Firegraph = {
  ProfilesPage: {
    init: async function () {},      // 初始化页面
    load: async function () {},      // 加载列表
    viewFlame: function (id, service) {}  // 打开 speedscope
  },
  TracesPage: {
    init: function () {},            // 初始化（绑定事件）
    load: async function () {},      // 并行拉 stats + timeseries
    renderStats: function (items) {},
    renderChart: function (buckets) {},
    showDetail: async function (service, cmd) {}
  }
};
```

---

## 4. 数据结构设计

### 4.1 数据库 Schema（`internal/store/schema.sql`）

#### 4.1.1 `profiles` 表

```sql
CREATE TABLE IF NOT EXISTS profiles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  service_name TEXT NOT NULL,         -- snlua 服务名
  node TEXT NOT NULL,                 -- 节点名
  sampled_at INTEGER NOT NULL,        -- 采样结束 unix 秒
  duration_sec INTEGER NOT NULL,      -- 采样持续时长
  folded_text TEXT NOT NULL,          -- 折叠栈原文
  sample_count INTEGER NOT NULL,      -- 采样总数
  created_at INTEGER NOT NULL         -- 入库 unix 秒
);
CREATE INDEX IF NOT EXISTS idx_profiles_lookup ON profiles(service_name, sampled_at);
```

#### 4.1.2 `traces` 表

```sql
CREATE TABLE IF NOT EXISTS traces (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,                -- 消息处理 unix 秒
  service TEXT NOT NULL,              -- snlua 服务名
  proto TEXT NOT NULL,                -- 协议名（lua/text/response）
  cmd TEXT NOT NULL,                  -- 命令名
  session INTEGER,                    -- skynet session id（可空）
  cost_ms INTEGER NOT NULL,           -- 处理耗时毫秒
  ok INTEGER NOT NULL                 -- 1=成功 0=失败
);
CREATE INDEX IF NOT EXISTS idx_traces_lookup ON traces(service, cmd, ts);
CREATE INDEX IF NOT EXISTS idx_traces_ts ON traces(ts);
```

### 4.2 数据交换格式

#### 4.2.1 Folded Stacks（折叠栈）

每行一条调用栈，格式：`frame1;frame2;frame3 count`

- 栈底在前，`;` 分隔帧名
- 空格分隔计数（栈中函数名不含空格）
- 兼容 FlameGraph.pl 与 speedscope

```
main;skynet.dispatch;login_handler;check_token 50
main;skynet.dispatch;login_handler;db_query 150
```

#### 4.2.2 speedscope `sampled` JSON

```json
{
  "$schema": "https://www.speedscope.app/file-format-schema.json",
  "shared": {
    "frames": [
      {"name": "main"},
      {"name": "foo"},
      {"name": "bar"}
    ]
  },
  "profiles": [{
    "type": "sampled",
    "name": "login@node1 2026-06-28 10:00:00",
    "unit": "samples",
    "startValue": 0,
    "endValue": 230,
    "samples": [[0,1,2], [0,1,3]],
    "weights": [200, 30]
  }]
}
```

字段语义：
- `shared.frames`：去重后的帧表（`name → index`）
- `samples`：每个元素是 frame index 数组（从底到顶）
- `weights`：每个采样的权重（对应折叠栈 count）
- `endValue`：总采样数（sum of weights）

#### 4.2.3 NDJSON Trace

每行一个 JSON 对象：

```json
{"ts":1719600000,"service":"login","proto":"lua","cmd":"Login","session":12345,"cost_ms":12,"ok":true}
```

字段约束：
- `ts`：unix 秒
- `service`/`cmd`：必填，缺失则解析报错跳过
- `session`：可空，空时写 NULL
- `ok`：boolean，兼容字符串 `"true"/"false"`（v1.0 已修复 boolean 解析）

### 4.3 Go 内部数据结构

#### 4.3.1 profile 包

```go
type FoldedStack struct {
    Frames []string  // 调用栈帧名（栈底在前）
    Count  int       // 采样命中次数
}

type SpeedscopeFrame struct {
    Name string `json:"name"`
}

type SpeedscopeProfile struct {
    Type       string  `json:"type"`       // 固定 "sampled"
    Name       string  `json:"name"`
    Unit       string  `json:"unit"`       // "samples"
    StartValue int     `json:"startValue"`
    EndValue   int     `json:"endValue"`   // sum(weights)
    Samples    [][]int `json:"samples"`    // frame index 数组
    Weights    []int   `json:"weights"`
}
```

#### 4.3.2 store 包（见 §3.2）

#### 4.3.3 server 包请求/响应

```go
type profileUploadRequest struct {
    ServiceName string `json:"service_name"`
    Node        string `json:"node"`
    SampledAt   int64  `json:"sampled_at"`    // 0 用服务端时间
    DurationSec int    `json:"duration_sec"`
    FoldedText  string `json:"folded_text"`
}
```

### 4.4 Lua 内部数据结构

#### 4.4.1 采样器状态

```lua
local hook_active = false          -- 是否在采样中
local stack_counts = {}            -- {["main;foo;bar"] = 123}
local sample_total = 0             -- 总采样数
local line_threshold = 5000        -- 每 5000 行 Lua 指令采样一次
local on_complete_cb = nil         -- 完成回调
```

#### 4.4.2 tracer 状态

```lua
local traces_buffer = {}           -- 待上报 trace 数组
local FLUSH_THRESHOLD = 100        -- 累积 100 条立即上报
local FLUSH_INTERVAL = 5 * 100     -- 5s（skynet.sleep 单位 1/100 秒）
local current_cmd = {}             -- [coroutine] = "Login"，协程级 cmd 标记
```

---

## 5. 核心算法设计

### 5.1 折叠栈解析算法（`profile.ParseFolded`）

**输入**：折叠栈文本（多行）
**输出**：`[]FoldedStack`

**算法步骤**：

```
1. 创建 bufio.Scanner，缓冲区 16MB（应对极深调用栈）
2. 逐行扫描：
   a. TrimRight 去掉 \r
   b. 跳过空行
   c. 找最后一个空格 idx = LastIndexByte(line, ' ')
      - 若找不到 → 报错 "no count"
   d. stackStr = line[:idx], countStr = line[idx+1:]
   e. count = Atoi(countStr)
      - 若 count <= 0 → 跳过
   f. frames = Split(stackStr, ";")
   g. 追加到结果 {Frames: frames, Count: count}
3. 返回结果
```

**关键决策**：
- 用 `LastIndexByte` 而非 `Split` 分隔栈与计数：栈中函数名可能含空格（虽然约定不含），更稳健。
- 16MB 单行缓冲：极深调用栈可能产生超长行。

### 5.2 speedscope 转换算法（`profile.ToSpeedscope`）

**输入**：`[]FoldedStack`, profileName
**输出**：`*SpeedscopeFile`

**算法步骤**：

```
1. 初始化：
   frameIndex = map[string]int{}   // 帧名 → 索引（去重）
   frames = []                     // 帧数组
   samples = []                    // 采样数组
   weights = []                    // 权重数组
   totalWeight = 0

2. 遍历每个 folded stack s：
   a. sample = make([]int, len(s.Frames))
   b. 对每个帧名 name in s.Frames：
      - 若 name 不在 frameIndex：
        - idx = len(frames)
        - frameIndex[name] = idx
        - frames = append(frames, {Name: name})
      - 否则 idx = frameIndex[name]
      - sample[i] = idx
   c. samples = append(samples, sample)
   d. weights = append(weights, s.Count)
   e. totalWeight += s.Count

3. 构造 SpeedscopeFile：
   - Schema = "https://www.speedscope.app/file-format-schema.json"
   - Shared.Frames = frames
   - Profiles[0] = {
       Type: "sampled",
       Name: profileName,
       Unit: "samples",
       StartValue: 0,
       EndValue: totalWeight,
       Samples: samples,
       Weights: weights
     }
```

**复杂度**：O(N×L)，N = 折叠栈行数，L = 平均栈深度。帧去重用 map，O(1) 查找。

### 5.3 分位数算法（`store.percentile`）

**输入**：已升序的 `[]int`，百分位 p（50/95/99）
**输出**：分位值

**算法（线性插值法）**：

```
1. 若 len == 0 → 返回 0
2. 若 len == 1 → 返回 sorted[0]
3. idx = p / 100.0 × (len - 1)
4. lower = floor(idx), upper = lower + 1
5. 若 upper >= len → 返回 sorted[len-1]
6. frac = idx - lower
7. 返回 sorted[lower] × (1 - frac) + sorted[upper] × frac
```

**示例**：[10, 20, 30, 40, 50]，P95
- idx = 0.95 × 4 = 3.8
- lower = 3, upper = 4, frac = 0.8
- 结果 = 40 × 0.2 + 50 × 0.8 = 48

**复杂度**：O(1)（假设输入已排序）。
**排序成本**：在 `AggregateStats` 中 SQL `ORDER BY cost_ms`，O(N log N)。

### 5.4 NDJSON 解析算法（`store.ParseNDJSONTraces`）

**输入**：NDJSON 字符串
**输出**：`[]Trace`

**算法步骤**：

```
1. lines = Split(data, "\n")
2. 对每行 line（带行号 i）：
   a. TrimSpace，若空 → 跳过
   b. 调用 parseOneTrace(line)：
      - 用 jsonGetNumber 提取 ts / session / cost_ms
      - 用 jsonGetString 提取 service / proto / cmd
      - 用 jsonGetBool 提取 ok（优先 boolean，回退 string "true"/"false"）
      - 若 service 或 cmd 为空 → 返回错误
   c. 若解析错误 → 记录错误，跳过该行（不阻塞整批）
   d. 追加到结果
3. 返回结果
```

**手写 JSON 提取理由**：
- NDJSON 单批可能上千行，`encoding/json` 反射开销显著
- 字段固定，手写更高效
- 容错性强（跳过错误行）

**关键坑**：`ok` 字段是 boolean，必须用 `jsonGetBool`（匹配 `true`/`false` 字面量），不能用 `jsonGetString`（匹配 `"true"` 字符串）。v1.0 已修复。

### 5.5 dispatch 包装算法（`tracer.install`）

**输入**：cfg, reporter
**副作用**：替换 `skynet.dispatch`

**算法步骤**：

```
1. 保存 original_dispatch = skynet.dispatch
2. 覆盖 skynet.dispatch = function(proto, handler)
3. 在覆盖版内：
   a. wrapped = function(session, source, msg, sz, ...)
   b. 在 wrapped 内：
      - co = coroutine.running()
      - start = skynet.now()
      - ok, err = pcall(handler, session, source, msg, sz, ...)
      - cost = skynet.now() - start          -- 1/100 秒
      - cmd = current_cmd[co] or proto       -- 优先用业务标记
      - current_cmd[co] = nil                -- 清理协程级状态
      - _record({
          ts = floor(skynet.time()),
          service = cfg.service,
          proto = proto,
          cmd = cmd,
          session = session,
          cost_ms = cost × 10,                -- 1/100 秒 → 毫秒
          ok = ok and 1 or 0
        })
      - 若 not ok → error(err, 0)             -- 重新抛出业务错误
   c. original_dispatch(proto, wrapped)
4. 启动 _flush_loop 协程：每 FLUSH_INTERVAL 调用 _flush
```

**关键设计**：
- `coroutine.running()` 作为 `current_cmd` 的 key：协程级 threadlocal，避免多协程并发污染。
- `pcall` 包裹业务 handler：确保即使业务抛错也能记录 trace，再 `error(err, 0)` 重新抛出不影响 skynet 原行为。
- `_flush` 用 `skynet.fork` 异步：上报不阻塞 dispatch。

### 5.6 折叠栈生成算法（`swt_bridge.hook_fn`）

**输入**：Lua 行事件
**输出**：累积到 `stack_counts`

**算法步骤**：

```
1. 若 not hook_active → return
2. tb = debug.traceback("", 4)            -- 跳过 hook 自身和上层
3. frames = parse_traceback(tb)
4. 若 #frames == 0 → frames = {"?"}
5. key = concat(frames, ";")              -- 栈底在前
6. stack_counts[key] += 1
7. sample_total += 1
```

**`parse_traceback` 算法**：

```
输入：debug.traceback 字符串，多行
输出：帧名数组（栈底在前）

1. frames = {}
2. 对每行 line：
   a. 跳过 "stack traceback:" 行
   b. 匹配优先级（依次尝试）：
      - in function 'xxx'
      - in local 'xxx'
      - in function <name:line>
      - in main chunk
      - in <something> 'xxx'
   c. 提取文件名+行号补充：name = name .. "@" .. loc
   d. table.insert(frames, 1, name)       -- traceback 从顶到底，反转
3. 返回 frames
```

**复杂度**：每次 hook 调用 O(L)，L = 调用栈深度。

### 5.7 时间序列分桶算法（`store.QueryTimeseries`）

**输入**：TraceFilter, bucketSec
**输出**：`[]TraceBucket`

**算法步骤**：

```
1. SQL 一次拉所有桶的 count + avg：
   SELECT (ts / bucket_sec) * bucket_sec AS bucket,
          COUNT(*), AVG(cost_ms)
   FROM traces
   WHERE <filter>
   GROUP BY bucket
   ORDER BY bucket

2. 对每个桶 b：
   - 单独查询该桶所有 cost_ms（queryCostsInBucket）
   - sort.Ints(costs)
   - b.P95Ms = percentile(costs, 95)

3. 返回 buckets
```

**优化空间**：步骤 2 是 N+1 查询（N = 桶数），可用 SQL window function 一次性算出。MVP 暂未优化，限制见 §8。

### 5.8 SVG 折线图算法（`app.js renderLineChart`）

**输入**：buckets `[{ts, count, avg_ms, p95_ms}]`
**输出**：SVG 字符串

**算法步骤**：

```
1. 视口：W=1100, H=300, PAD_L=50, PAD_R=20, PAD_T=20, PAD_B=40
2. plotW = W - PAD_L - PAD_R, plotH = H - PAD_T - PAD_B
3. 补全 P99 字段：series[i].p99 = round(p95 × 1.1)   -- 后端 timeseries 不返回 P99
4. 求 maxV = max(avg, p95, p99)，向上取整 ×1.1 留白
5. 坐标变换：
   - xPos(i) = PAD_L + (i × plotW / (n-1))
   - yPos(v) = PAD_T + plotH - (v / maxV × plotH)
6. 生成 3 条 path：
   - Avg:  stroke="#2563eb" (蓝)
   - P95:  stroke="#dc2626" (红)
   - P99:  stroke="#9333ea" stroke-dasharray="4 2" (紫虚线)
7. 生成 X 轴 5 刻度 + Y 轴 4 刻度
8. 拼接 SVG 字符串返回
```

**复杂度**：O(N)，N = 桶数。

---

## 6. 技术选型说明

### 6.1 选型清单

| 层 | 选型 | 版本 | 备选 | 选择理由 |
|---|---|---|---|---|
| 后端语言 | Go | 1.22+（实际 1.25.5） | Rust / C++ | 单二进制部署、与 skynet 生态一致、并发能力强、CGO-free 跨平台编译 |
| SQLite 驱动 | `modernc.org/sqlite` | v1.53.0 | `mattn/go-sqlite3` | **纯 Go 实现，无 CGO**，跨平台编译零障碍；性能足够百万级数据 |
| 配置 | `gopkg.in/yaml.v3` | v3.0.1 | JSON / TOML | 人类可读、支持嵌套、注释 |
| HTTP 路由 | Go 标准库 `http.ServeMux` | Go 1.22+ | gin / echo / chi | 原生支持 `METHOD /path/{id}` 语法，无需第三方框架 |
| 前端 | 原生 JS + SVG | - | Vue / React / ECharts | 无构建链、内网加载快、零运行时依赖、维护成本低 |
| 火焰图渲染 | speedscope 离线包 | v1.25.0 | 自研 / d3-flame-graph | 纯浏览器运行、三种视图、交互体验最佳、支持 `#profileURL=` 远程加载 |
| 折叠栈格式 | Folded Stacks | - | pprof / perf | 业界标准，兼容 FlameGraph.pl 与 speedscope |
| Skynet 采样 | `debug.sethook("l", N)` + 可选 swt | - | 自研 C hook | 内置开箱即用，swt 可选升级到全服务精确采样 |
| 接口埋点层 | `skynet.dispatch` 包装 | - | `skynet.call` 包装 / 业务手写 | 无侵入、覆盖所有消息、记录「处理耗时」语义正确 |
| 上报协议 | HTTP/JSON + NDJSON | - | UDP / TCP / gRPC | MVP 简单可靠、可读性好、调试方便 |

### 6.2 关键决策记录

#### 6.2.1 为何不用 `mattn/go-sqlite3`？

`mattn/go-sqlite3` 依赖 CGO，跨平台编译需要 C 工具链。本项目要求 `CGO_ENABLED=0` 可编译（NFR-MAINT-02），故选 `modernc.org/sqlite` 纯 Go 实现。

**代价**：纯 Go 实现的 SQLite 性能略低于 C 实现，但百万级数据足够。

#### 6.2.2 为何不引入 ECharts？

原计划用 ECharts 渲染趋势图（[PRD](./01-REQUIREMENTS.md) FR-T-09），但考虑：
- 内网部署避免 CDN 依赖（NFR-MAINT-03）
- 本地化 ECharts 增加约 1MB 资源
- 趋势图需求简单（3 条折线 + 坐标轴）

最终用 ~60 行原生 SVG 实现，零外部依赖。

#### 6.2.3 为何在 `skynet.dispatch` 层埋点而非 `skynet.call`？

- **覆盖面**：dispatch 是消息入口，覆盖所有进入服务的消息（含 `skynet.send` 单向消息）。
- **语义正确**：记录的是「处理耗时」，而非「RPC 往返耗时」，符合"接口耗时"语义。
- **无侵入**：只需 preload 一次安装，业务代码无需改动（G-3）。

#### 6.2.4 为何用手写 JSON 解析（`trace_repo.go`）而非 `encoding/json`？

NDJSON 单批可能上千行，`encoding/json` 反射开销显著。手写极简解析器针对已知字段（ts/service/proto/cmd/session/cost_ms/ok），性能更高且容错（跳过格式错误行）。

**已知坑**：`ok` 字段是 boolean，需用 `jsonGetBool` 而非 `jsonGetString` 解析（v1.0 已修复）。

#### 6.2.5 为何分位数在内存计算？

SQLite 无原生 `PERCENTILE` 函数。当前方案：SQL 算 count/avg/max，分组后内存拉排序数组 + 线性插值。

- **优点**：实现简单、准确
- **缺点**：单接口百万级数据查询变慢
- **优化方向**：预聚合表 / window function / ClickHouse（见 [需求分析](./02-REQUIREMENTS_ANALYSIS.md) §7 R-03）

#### 6.2.6 为何 speedscope 用 `#profileURL=` 而非文件上传？

speedscope 官方支持通过 URL hash fragment `#profileURL=<url>` 加载远程 JSON。这种方式：
- 后端无需托管文件上传
- JSON 按需生成（折叠栈 → speedscope 转换在请求时完成）
- 浏览器直接 fetch，无需后端中转

**前提**：后端响应需设置 `Access-Control-Allow-Origin: *`（speedscope 是独立 origin）。

---

## 7. 关键流程时序图

### 7.1 火焰图端到端时序图

```
snlua服务        sampler         reporter        后端server       后端store      浏览器
   │                │                │                │              │             │
   │ start_profile  │                │                │              │             │
   │───────────────►│                │                │              │             │
   │                │ sethook        │                │              │             │
   │ (业务运行)     │                │                │              │             │
   │ (每5000行)     │                │                │              │             │
   │◄──────── hook ─┤                │                │              │             │
   │                │ stack_counts++ │                │              │             │
   │ stop_profile   │                │                │              │             │
   │───────────────►│                │                │              │             │
   │                │ stop+拼folded  │                │              │             │
   │                │ on_complete ──►│                │              │             │
   │                │                │ POST /upload   │              │             │
   │                │                │───────────────►│              │             │
   │                │                │                │ ParseFolded  │             │
   │                │                │                │─────────────►│             │
   │                │                │                │              │ INSERT      │
   │                │                │                │◄─────────────│             │
   │                │                │ 200 {id}       │              │             │
   │                │                │◄───────────────│              │             │
   │                │                │                │              │             │
   │                │                │                │              │  GET /profiles
   │                │                │                │              │◄────────────
   │                │                │                │ ListProfiles │             │
   │                │                │                │─────────────►│             │
   │                │                │                │◄─────────────│             │
   │                │                │                │ 200 items    │             │
   │                │                │                │────────────────────────────►│
   │                │                │                │              │             │
   │                │                │                │              │  点击「查看火焰图」
   │                │                │                │              │  window.open(speedscope#profileURL=)
   │                │                │                │              │             │
   │                │                │                │              │  speedscope fetch JSON
   │                │                │                │  GET /speedscope.json      │
   │                │                │                │◄────────────────────────────│
   │                │                │                │ GetProfile   │             │
   │                │                │                │─────────────►│             │
   │                │                │                │◄─────────────│             │
   │                │                │                │ ToSpeedscope │             │
   │                │                │                │ 200 + CORS   │             │
   │                │                │                │────────────────────────────►│
   │                │                │                │              │             │
   │                │                │                │              │  渲染三视图
```

### 7.2 接口耗时端到端时序图

```
消息源         snlua服务       tracer         reporter       后端server     后端store    浏览器
   │              │              │              │              │             │           │
   │ msg          │              │              │              │             │           │
   │─────────────►│              │              │              │             │           │
   │              │ wrapped(...  │              │              │             │           │
   │              │─────────────►│              │              │             │           │
   │              │              │ start=now    │              │             │           │
   │              │              │ pcall(handler)              │             │           │
   │              │              │ cost=now-start              │             │           │
   │              │              │ _record(...) │              │             │           │
   │              │              │ buffer.push  │              │             │           │
   │              │              │              │              │             │           │
   │              │              │ (累积100或5s)│              │             │           │
   │              │              │ _flush       │              │             │           │
   │              │              │ fork ───────►│              │             │           │
   │              │              │              │ POST /batch  │             │           │
   │              │              │              │─────────────►│             │           │
   │              │              │              │              │ ParseNDJSON │           │
   │              │              │              │              │────────────►│           │
   │              │              │              │              │             │ INSERT tx │
   │              │              │              │              │◄────────────│           │
   │              │              │              │ 200 {inserted}            │           │
   │              │              │              │◄─────────────│             │           │
   │              │              │              │              │             │           │
   │              │              │              │              │             │  打开 /traces.html
   │              │              │              │              │             │  选 1h 范围
   │              │              │              │              │             │           │
   │              │              │              │              │  GET /stats + /timeseries (并行)
   │              │              │              │              │◄────────────────────────│
   │              │              │              │              │ AggregateStats          │
   │              │              │              │              │────────────►│           │
   │              │              │              │              │◄────────────│           │
   │              │              │              │              │ QueryTimeseries         │
   │              │              │              │              │────────────►│           │
   │              │              │              │              │◄────────────│           │
   │              │              │              │              │ 200 items + items       │
   │              │              │              │              │────────────────────────►│
   │              │              │              │              │             │           │
   │              │              │              │              │             │  渲染卡片+SVG+表格
   │              │              │              │              │             │           │
   │              │              │              │              │             │  点击「明细」
   │              │              │              │              │  GET /traces?service=&cmd=
   │              │              │              │              │◄────────────────────────│
   │              │              │              │              │ QueryTraces │           │
   │              │              │              │              │────────────►│           │
   │              │              │              │              │◄────────────│           │
   │              │              │              │              │ 200 items              │
   │              │              │              │              │────────────────────────►│
   │              │              │              │              │             │           │
   │              │              │              │              │             │  渲染明细表
```

---

## 8. 异常处理与容错设计

### 8.1 Skynet 端容错

| 异常场景 | 处理策略 | 实现 |
|---|---|---|
| 上报 HTTP 失败 | 重试 3 次，间隔 1s，最终失败丢弃 | `reporter.lua` 循环 + `skynet.sleep(100)` |
| `require "swt"` 失败 | 回退到内置 `debug.sethook` 采样器 | `swt_bridge.lua` `pcall(require, "swt")` |
| 业务 handler 抛错 | `pcall` 捕获记录 trace，再 `error(err, 0)` 重新抛出 | `tracer.lua` `pcall(handler, ...)` |
| `tag_cmd` 在非协程调用 | 检查 `coroutine.running()` 为 nil 则忽略 | `tracer.lua` `if co and cmd then` |
| preload 初始化失败 | `pcall` 包裹，失败仅记录日志不阻塞服务启动 | `preload.lua` `pcall(function() ... end)` |

### 8.2 后端容错

| 异常场景 | 处理策略 | 实现 |
|---|---|---|
| NDJSON 单行格式错误 | 跳过该行，记录错误，继续解析其余 | `trace_repo.go` `_ = fmt.Errorf(...)` |
| profile folded_text 格式错误 | 返回 400 + 错误信息 | `profile_handler.go` `writeError(400, ...)` |
| 请求 body 超限 | `MaxBytesReader` 限制（profile 32MB / trace 8MB） | `*_handler.go` |
| SQLite 并发写冲突 | `PRAGMA busy_timeout=5000` 等待 5s | `store.go` |
| 批量插入部分失败 | 单事务，要么全成功要么全回滚 | `trace_repo.go` `BeginTx` + `Commit` |
| 查询记录不存在 | 返回 `(nil, nil)`，handler 转 404 | `profile_repo.go` `GetProfile` |
| 路径参数非数字 | 返回 400 | `*_handler.go` `strconv.ParseInt` |

### 8.3 前端容错

| 异常场景 | 处理策略 | 实现 |
|---|---|---|
| fetch 失败 | 表格显示 "加载失败: <错误>" | `app.js` `catch (e)` |
| speedscope 未下载 | 显示提示运行 `fetch_assets.sh` | `app.js` `checkSpeedscope()` HEAD 探测 |
| 数据为空 | 表格显示 "暂无数据" | `app.js` `if (!items.length)` |
| 趋势图无数据 | 显示 "暂无时序数据" | `app.js` `renderChart` |

### 8.4 数据一致性

- **事务**：`InsertTraces` 用 `BeginTx` + `Commit`，保证批量原子性。
- **WAL 模式**：SQLite WAL 提升并发写入性能，崩溃重启不丢已提交数据。
- **优雅关闭**：`srv.Shutdown(5s)` 等待在途请求完成，`defer st.Close()` 关闭 DB。

---

## 9. 部署与构建设计

### 9.1 后端构建

**`scripts/build.sh`**：
```bash
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o bin/firegraph ./cmd/firegraph
```

- `CGO_ENABLED=0`：纯 Go 编译，无 C 依赖
- `-trimpath`：去除路径信息
- `-ldflags "-s -w"`：去除调试信息，减小二进制体积

### 9.2 前端资源准备

**`scripts/fetch_assets.sh`**：
```bash
VERSION=1.25.0
curl -fL https://github.com/jlfwong/speedscope/releases/download/v${VERSION}/speedscope-v${VERSION}.zip
unzip -q speedscope.zip -d web/assets/vendor/speedscope/
```

speedscope 离线包托管在 `/assets/vendor/speedscope/`，前端通过相对路径加载。

### 9.3 Skynet 端接入

无需构建，Lua 脚本直接部署到 `skynet-agent/lua/`，通过 skynet config 配置：

```lua
lua_path  = "./skynet-agent/lua/?.lua;./skynet-agent/lua/?/init.lua"
preload   = "./skynet-agent/lua/preload.lua"
firegraph_host = "127.0.0.1"
firegraph_port = 8080
service_name   = "login"
firegraph_enable_tracer = true
```

### 9.4 启动与关闭

```bash
# 启动
./bin/firegraph -config configs/firegraph.yaml

# 优雅关闭
kill -SIGINT <pid>   # 或 kill -SIGTERM <pid>
```

`main.go` 信号处理：
```go
sigCh := make(chan os.Signal, 1)
signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
<-sigCh
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()
srv.Shutdown(ctx)
```

---

## 10. 设计权衡与决策记录

### 10.1 设计权衡记录表

| 决策点 | 选项 A | 选项 B | 选择 | 权衡理由 |
|---|---|---|---|---|
| SQLite 驱动 | mattn/go-sqlite3 (CGO) | modernc.org/sqlite (纯 Go) | **B** | NFR-MAINT-02 要求 CGO-free，性能损失可接受 |
| 趋势图渲染 | ECharts (功能强) | 纯 SVG (零依赖) | **B** | NFR-MAINT-03 要求无构建链，需求简单 |
| 采样器 | 仅内置 | 内置 + swt 可选 | **B** | 内置开箱即用兜底，swt 路径保留升级 |
| 埋点层 | skynet.call | skynet.dispatch | **B** | dispatch 覆盖全、语义正确、无侵入 |
| cmd 存储 | 全局变量 | 协程级 threadlocal | **B** | 协程级避免并发污染 |
| 上报时机 | 仅数量阈值 | 数量 + 时间双阈值 | **B** | 兼顾延迟与吞吐 |
| 上报方式 | 同步 | 异步 (skynet.fork) | **B** | 不阻塞 dispatch |
| 分位数 | SQL | 内存计算 | **B** | SQLite 无 PERCENTILE，内存算法准确 |
| JSON 解析 | encoding/json | 手写极简解析 | **B** | NDJSON 高频解析，性能更优 |
| speedscope 加载 | 文件上传 | URL hash fragment | **B** | 按需生成，无需文件管理 |
| 上报失败 | 缓存重放 | 重试后丢弃 | **B** | 简单可靠，profile 一次性数据可丢 |

### 10.2 已知技术债

| 技术债 | 影响 | 优先级 | 计划 |
|---|---|---|---|
| swt 适配代码为示意 | FR-P-10 不可用 | P2 | v1.x 调研 swt 实际 API |
| 数据自动过期未接定时器 | FR-S-03 不可用 | P1 | v1.1 在 main.go 加 ticker |
| 缺少单元测试 | 维护风险 | P1 | v1.1 补 folded/percentile/NDJSON 测试 |
| 分位数内存计算 | 百万级数据慢 | P2 | v2 预聚合表 / window function |
| timeseries N+1 查询 | 桶多时慢 | P2 | v2 window function |
| 无鉴权 | 公网部署受限 | P3 | v2 Basic Auth / 反代 |
| 无结构化日志 | 排障困难 | P2 | v1.1 切 zap/zerolog |
| 无 Prometheus 指标 | 自身难监控 | P3 | v2 /metrics |

### 10.3 演进路径

```
v1.0 (当前)
  ├ 火焰图 MVP
  ├ 接口耗时埋点
  └ 内置采样器
       │
       ▼
v1.1 (短期)
  ├ 自动过期定时器
  ├ 单元测试覆盖
  ├ swt 实际接入
  └ 结构化日志
       │
       ▼
v1.2 (中期)
  ├ 分位数预聚合
  ├ timeseries 优化
  └ 压测验证
       │
       ▼
v2.0 (长期)
  ├ 历史对比 (Differential FlameGraph)
  ├ 多节点聚合
  ├ 告警 (P95 webhook)
  ├ 鉴权
  ├ 实时观测 (WebSocket)
  └ 服务拓扑图
```

---

**文档结束。** 本文是 firegraph 项目的代码设计权威说明，与 [需求文档](./01-REQUIREMENTS.md)、[需求分析文档](./02-REQUIREMENTS_ANALYSIS.md) 共同构成项目文档体系。代码变更需同步更新本文档对应章节。
