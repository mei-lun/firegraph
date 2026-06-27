# firegraph 技术设计文档

> 面向 Skynet + Lua 游戏服务器的性能与接口耗时监测平台
>
> - **文档版本**：v1.0
> - **对应代码版本**：阶段 1 + 阶段 2（火焰图 MVP + 接口耗时埋点）
> - **目标读者**：维护者 / 二次开发者 / AI 辅助工具
> - **用途**：作为后续功能优化、迭代修改、扩展开发的输入规范

---

## 目录

1. [功能概述](#1-功能概述)
2. [总体架构](#2-总体架构)
3. [模块划分](#3-模块划分)
4. [关键技术选型](#4-关键技术选型)
5. [实现细节](#5-实现细节)
6. [数据格式与接口定义](#6-数据格式与接口定义)
7. [使用说明](#7-使用说明)
8. [已知限制](#8-已知限制)
9. [优化与扩展方向](#9-优化与扩展方向)
10. [附录](#10-附录)

---

## 1. 功能概述

### 1.1 背景与目标

Skynet 是基于 C 的 actor 模型游戏服务器框架，业务逻辑由 snlua 服务承载（每个服务一个独立 Lua VM）。在长期运营中需要回答两个核心问题：

- **CPU 热点在哪？** 哪些 Lua 函数消耗了大量 CPU 时间？
- **接口耗时分布如何？** 慢接口、抖动接口、错误率如何？

本工具以**最小侵入 + 浏览器交互**为设计原则，提供上述两类能力的端到端解决方案，单二进制部署，无外部重型依赖。

### 1.2 核心能力

| 能力 | 实现方式 | 输出形态 |
|---|---|---|
| **CPU 火焰图** | Lua 运行时调用栈采样，生成折叠栈 → speedscope JSON | 浏览器内交互查看（Time Order / Left Heavy / Sandwich 三视图） |
| **接口耗时统计** | 包装 `skynet.dispatch` 无侵入埋点 | 列表 + P50/P95/P99 分位 + 趋势折线图 + 明细 |
| **历史数据管理** | SQLite 持久化 + 按天保留 | 自动过期清理（可配置） |

### 1.3 典型使用场景

1. **开发期热点定位**：手动触发 30s 采样，定位 CPU 密集型函数。
2. **生产期定期巡检**：配置 `auto_profile_interval` 每 5 分钟自动采样，积累历史 profile。
3. **慢接口排查**：通过 traces 页面按 service/cmd 过滤，查看 P95 抖动与失败明细。
4. **性能回归对比**：保存不同时间点的 profile，用 FlameGraph.pl 离线 diff（阶段 3）。

---

## 2. 总体架构

### 2.1 架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│ Skynet 游戏服务器 (Linux，多 snlua 服务)                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ snlua: login │  │ snlua: game  │  │ snlua: chat  │  ...      │
│  │  preload.lua │  │  preload.lua │  │  preload.lua │           │
│  │   ├ firegraph.init                              │            │
│  │   ├ swt_bridge (采样器：内置/swt)               │            │
│  │   ├ tracer    (包装 skynet.dispatch)            │            │
│  │   └ reporter  (HTTP 上报，重试 3 次)            │            │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
└─────────┼─────────────────┼─────────────────┼───────────────────┘
          │ HTTP/JSON        │                 │
          │ profile upload   │ trace batch     │
          ▼                  ▼                 ▼
┌─────────────────────────────────────────────────────────────────┐
│ firegraph 后端 (Go 单二进制 + SQLite)                            │
│                                                                  │
│  HTTP Router (Go 1.22+ ServeMux)                                │
│  ├ POST /api/profiles/upload      ← 折叠栈上报                   │
│  ├ POST /api/traces/batch         ← NDJSON 批量上报              │
│  ├ GET  /api/profiles             → 列表                         │
│  ├ GET  /api/profiles/{id}        → 详情                         │
│  ├ GET  /api/profiles/{id}/speedscope.json → speedscope JSON     │
│  ├ GET  /api/profiles/{id}/folded.txt     → 原始折叠栈下载       │
│  ├ GET  /api/traces               → 明细分页                     │
│  ├ GET  /api/traces/stats         → P50/P95/P99 聚合             │
│  ├ GET  /api/traces/timeseries    → 时间序列                     │
│  └ GET  /                         → Web UI 静态资源              │
│                                                                  │
│  internal/                                                       │
│  ├ store/  (SQLite WAL + modernc.org/sqlite 纯 Go 驱动)         │
│  ├ profile/ (ParseFolded + ToSpeedscope)                        │
│  └ config/ (YAML 配置)                                          │
└─────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│ 浏览器 (原生 JS，无构建链)                                        │
│  /              → 首页（导航 + 功能卡片）                         │
│  /profiles.html → profile 列表 → 一键打开 speedscope             │
│  /traces.html   → 5 张统计卡 + 纯 SVG 趋势图 + 表格 + 明细       │
│  /assets/vendor/speedscope/ → speedscope 离线包                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 数据流

#### 2.2.1 火焰图数据流

```
snlua 服务
  │
  │ 1. firegraph.start_profile(30)
  │    → swt_bridge.start() → debug.sethook(hook_fn, "l", 5000)
  │
  │ 2. 每执行 5000 行 Lua 指令触发 hook_fn
  │    → debug.traceback("", 4) 解析调用栈
  │    → stack_counts["main;foo;bar"] += 1
  │
  │ 3. 30s 后 firegraph.stop_profile()
  │    → swt_bridge.stop()
  │    → 拼接折叠栈文本：main;foo;bar 123\n...
  │    → on_complete 回调
  │
  │ 4. reporter.report_profile()
  │    → HTTP POST /api/profiles/upload
  │    → 失败重试 3 次（间隔 1s），最终失败丢弃
  ▼
firegraph 后端
  │
  │ 5. handleProfileUpload
  │    → MaxBytesReader(32MB)
  │    → profile.ParseFolded() 解析折叠栈
  │    → store.InsertProfile() 写入 SQLite
  │
  │ 6. 用户访问 /profiles.html
  │    → GET /api/profiles (列表)
  │    → 点击「查看火焰图」
  │    → window.open(speedscope#profileURL=/api/profiles/{id}/speedscope.json)
  │
  │ 7. GET /api/profiles/{id}/speedscope.json
  │    → store.GetProfile(id) 取 folded_text
  │    → profile.ToSpeedscope() 转换格式
  │    → 响应带 Access-Control-Allow-Origin: *
  ▼
浏览器 speedscope
  │
  │ 8. speedscope 通过 #profileURL= hash fragment
  │    fetch 远程 JSON → 渲染火焰图三视图
```

#### 2.2.2 接口耗时数据流

```
snlua 服务 (preload 启用 firegraph_enable_tracer=true)
  │
  │ 1. tracer.install(cfg, reporter)
  │    → 替换 skynet.dispatch 为包装版本
  │    → 启动 _flush_loop 协程（每 5s flush）
  │
  │ 2. 每条消息到达：
  │    wrapped(session, source, msg, sz, ...)
  │    ├ start = skynet.now()
  │    ├ pcall(handler, ...)           ← 业务原 handler
  │    ├ cost = skynet.now() - start   ← 1/100 秒
  │    ├ cmd = current_cmd[co] or proto
  │    └ _record({ts, service, proto, cmd, session, cost_ms=cost*10, ok})
  │
  │ 3. _record 累积到 100 条或 _flush_loop 触发
  │    → reporter.report_traces(traces)
  │    → 构建 NDJSON（每行一个 JSON）
  │    → HTTP POST /api/traces/batch (8MB 上限)
  ▼
firegraph 后端
  │
  │ 4. handleTraceBatch
  │    → MaxBytesReader(8MB)
  │    → store.ParseNDJSONTraces() 解析（容错：跳过错误行）
  │    → store.InsertTraces() 事务批量插入
  │
  │ 5. 用户访问 /traces.html
  │    并行请求：
  │    ├ GET /api/traces/stats       (聚合：count/avg/max + 内存分位数)
  │    └ GET /api/traces/timeseries  (按 bucket_sec 分桶)
  │
  │ 6. 前端渲染：
  │    ├ 5 张统计卡片（汇总所有 service+cmd）
  │    ├ 纯 SVG 折线图（Avg/P95/P99 三条线）
  │    ├ 表格（按 avg_ms 倒序，高亮慢调用）
  │    └ 点击「明细」→ GET /api/traces?service=&cmd=&limit=100
```

### 2.3 部署拓扑

```
┌─────────────────┐         ┌──────────────────┐         ┌──────────────┐
│ Skynet 服务器   │  HTTP   │ firegraph 后端   │  HTTP   │ 运维浏览器   │
│ (Linux, 多节点) │ ──────► │ (Linux, 单二进制)│ ◄────── │ (内网)       │
│  跑 snlua 服务  │         │  + SQLite 文件   │         │              │
└─────────────────┘         └──────────────────┘         └──────────────┘
```

- **Skynet 端**：多节点部署，每个 snlua 服务独立初始化 firegraph。
- **后端**：单实例即可，SQLite 单文件备份简单；高可用可后续扩展。
- **浏览器**：内网部署，无需公网。

---

## 3. 模块划分

### 3.1 模块清单

| 层 | 模块 | 路径 | 职责 |
|---|---|---|---|
| **后端** | main | `cmd/firegraph/main.go` | 入口、信号处理、优雅关闭 |
| | config | `internal/config/config.go` | YAML 配置加载 + 默认值 |
| | store | `internal/store/store.go` | SQLite 连接 + WAL + schema 初始化 |
| | store | `internal/store/schema.sql` | profiles + traces 表定义 |
| | store | `internal/store/profile_repo.go` | Profile CRUD |
| | store | `internal/store/trace_repo.go` | Trace 批量插入 + 聚合 + 分位数 |
| | profile | `internal/profile/folded.go` | 折叠栈解析（FoldedStack） |
| | profile | `internal/profile/speedscope.go` | folded → speedscope `sampled` JSON |
| | server | `internal/server/server.go` | HTTP 服务 + 路由 + 静态资源 |
| | server | `internal/server/profile_handler.go` | 5 个 profile 路由 handler |
| | server | `internal/server/trace_handler.go` | 4 个 trace 路由 handler |
| | server | `internal/server/util.go` | writeJSON / writeError |
| **前端** | 页面 | `web/index.html`、`profiles.html`、`traces.html` | 三页 UI |
| | 资源 | `web/assets/app.js` | 原生 JS 逻辑（ProfilesPage / TracesPage / SVG 图表） |
| | 资源 | `web/assets/app.css` | 样式 |
| | vendor | `web/assets/vendor/speedscope/` | speedscope 离线包（由脚本下载） |
| **Skynet** | preload | `skynet-agent/lua/preload.lua` | snlua 启动时自动初始化 |
| | firegraph | `skynet-agent/lua/firegraph/init.lua` | 模块入口、API 暴露 |
| | sampler | `skynet-agent/lua/firegraph/swt_bridge.lua` | 双模式采样器（内置 + swt） |
| | tracer | `skynet-agent/lua/firegraph/tracer.lua` | dispatch 包装埋点 |
| | reporter | `skynet-agent/lua/firegraph/reporter.lua` | HTTP 上报 + 重试 |
| **构建** | scripts | `scripts/build.sh`、`fetch_assets.sh` | 构建 + 资源下载 |

### 3.2 模块依赖关系

```
后端依赖（Go）:
  main → config, server, store
  server → config, store, profile
  store → (modernc.org/sqlite, gopkg.in/yaml.v3)
  profile → (无外部依赖)

Skynet 端依赖（Lua）:
  preload → firegraph.init
  firegraph.init → reporter, swt_bridge, (可选 tracer)
  tracer → reporter
  reporter → skynet.httpc
  swt_bridge → (可选 swt C 模块)

前端依赖:
  app.js → 无（纯原生 JS）
  speedscope → 独立离线包
```

### 3.3 依赖边界与契约

- **Skynet ↔ 后端**：仅通过 HTTP/JSON 通信，无共享代码。
- **后端 ↔ 前端**：仅通过 REST API 通信，前端无构建步骤。
- **存储层**：所有 SQL 集中在 `internal/store/`，handler 不直接写 SQL。
- **profile 包**：纯函数式，无状态，可独立测试。

---

## 4. 关键技术选型

| 层 | 选型 | 版本 | 理由 |
|---|---|---|---|
| 后端语言 | Go | 1.22+（实际 go.mod 声明 1.25.5） | 单二进制部署、与 skynet 生态一致、并发能力强、CGO-free 跨平台编译 |
| SQLite 驱动 | `modernc.org/sqlite` | v1.53.0 | **纯 Go 实现，无 CGO**，跨平台编译零障碍；性能足够百万级数据 |
| 配置 | `gopkg.in/yaml.v3` | v3.0.1 | 人类可读、支持嵌套 |
| HTTP 路由 | Go 标准库 `http.ServeMux` | Go 1.22+ | 原生支持 `METHOD /path/{id}` 语法，无需第三方框架 |
| 前端 | 原生 JS + SVG | - | 无构建链、内网加载快、零运行时依赖、维护成本低 |
| 火焰图渲染 | speedscope 离线包 | v1.25.0 | 纯浏览器运行、三种视图、交互体验最佳、支持 `#profileURL=` 远程加载 |
| 折叠栈格式 | Folded Stacks | - | 业界标准，兼容 FlameGraph.pl 与 speedscope |
| Skynet 采样 | `debug.sethook("l", N)` + 可选 swt | - | 内置开箱即用，swt 可选升级到全服务精确采样 |
| 接口埋点层 | `skynet.dispatch` 包装 | - | 无侵入、覆盖所有消息、记录「处理耗时」语义正确 |
| 上报协议 | HTTP/JSON + NDJSON | - | MVP 简单可靠、可读性好、调试方便 |

### 4.1 关键决策说明

#### 4.1.1 为何不用 `mattn/go-sqlite3`？
`mattn/go-sqlite3` 依赖 CGO，跨平台编译需要 C 工具链。`modernc.org/sqlite` 是纯 Go 实现，`CGO_ENABLED=0` 即可编译，部署更简单。

#### 4.1.2 为何不引入 ECharts？
原计划用 ECharts 渲染趋势图，但考虑到：
- 内网部署避免 CDN 依赖
- 本地化 ECharts 增加约 1MB 资源
- 趋势图需求简单（3 条折线 + 坐标轴）

最终用 ~60 行原生 SVG 实现，零外部依赖。

#### 4.1.3 为何在 `skynet.dispatch` 层埋点而非 `skynet.call`？
- **覆盖面**：dispatch 是消息入口，覆盖所有进入服务的消息（含 `skynet.send` 单向消息）。
- **语义正确**：记录的是「处理耗时」，而非「RPC 往返耗时」，符合"接口耗时"语义。
- **无侵入**：只需 preload 一次安装，业务代码无需改动。

#### 4.1.4 为何用手写 JSON 解析（trace_repo.go）而非 `encoding/json`？
NDJSON 单批可能上千行，`encoding/json` 反射开销显著。手写极简解析器针对已知字段（ts/service/proto/cmd/session/cost_ms/ok），性能更高且容错（跳过格式错误行）。
**已知坑**：`ok` 字段是 boolean，需用 `jsonGetBool` 而非 `jsonGetString` 解析（已在 v1.0 修复）。

#### 4.1.5 为何分位数在内存计算？
SQLite 无原生 `PERCENTILE` 函数。当前方案：SQL 算 count/avg/max，分组后内存拉排序数组 + 线性插值。
- 优点：实现简单、准确
- 缺点：单接口百万级数据查询变慢
- 优化方向：见 [§9](#9-优化与扩展方向)

---

## 5. 实现细节

### 5.1 后端实现

#### 5.1.1 入口与配置

**`cmd/firegraph/main.go`** — 加载配置 → 打开存储 → 创建服务 → 信号优雅关闭（5s 超时）。

```go
cfg, _ := config.Load(*cfgPath)        // YAML 加载，无文件则用默认值
st, _ := store.Open(cfg.Store.DSN)     // SQLite + WAL + schema 初始化
srv := server.New(cfg, st)             // 注册路由
go func() {                            // SIGINT/SIGTERM → srv.Shutdown(5s) }{
  <-sigCh; srv.Shutdown(ctx)
}()
srv.Start()                            // 阻塞 ListenAndServe
```

**`internal/config/config.go`** — 默认值：`addr=":8080"`, `web_dir="./web"`, `dsn="firegraph.db"`, `retention_days=7`。

#### 5.1.2 存储层

**`internal/store/store.go`** — `Open(dsn)` 流程：
1. `sql.Open("sqlite", dsn)` 注册 modernc 驱动
2. `PRAGMA journal_mode=WAL` — 提升并发写入
3. `PRAGMA busy_timeout=5000` — 避免并发写报错
4. 执行 `schema.sql`（通过 `//go:embed` 嵌入）

**`internal/store/schema.sql`** — 两张表：
- `profiles`：id / service_name / node / sampled_at / duration_sec / folded_text / sample_count / created_at
- `traces`：id / ts / service / proto / cmd / session / cost_ms / ok
- 索引：`idx_profiles_lookup(service_name, sampled_at)`、`idx_traces_lookup(service, cmd, ts)`、`idx_traces_ts(ts)`

**`internal/store/trace_repo.go`** — 核心方法：

| 方法 | 功能 | 关键实现 |
|---|---|---|
| `InsertTraces(ctx, []Trace)` | 批量插入 | 单事务 + prepared stmt，session 为 -1 写 NULL |
| `QueryTraces(ctx, TraceFilter)` | 明细分页 | 动态拼接 WHERE + ORDER BY ts DESC |
| `AggregateStats(ctx, TraceFilter)` | 聚合统计 | 两步：①SQL 算 count/avg/max ②每组拉排序数组算分位数 |
| `QueryTimeseries(ctx, f, bucketSec)` | 时间序列 | SQL `(ts/?)*?` 分桶 + 每桶单独算 P95 |
| `ParseNDJSONTraces(data)` | NDJSON 解析 | 按行 split + 手写 JSON 提取，容错跳过错误行 |
| `percentile(sorted, p)` | 分位数 | 线性插值法 |

**分位数算法**（线性插值）：
```go
func percentile(sorted []int, p int) int {
    if len(sorted) == 0 { return 0 }
    if len(sorted) == 1 { return sorted[0] }
    idx := float64(p) / 100.0 * float64(len(sorted)-1)
    lower := int(idx)
    upper := lower + 1
    if upper >= len(sorted) { return sorted[len(sorted)-1] }
    frac := idx - float64(lower)
    return int(float64(sorted[lower])*(1-frac) + float64(sorted[upper])*frac)
}
```

#### 5.1.3 Profile 解析与转换

**`internal/profile/folded.go`** — `ParseFolded(r io.Reader)`：
- `bufio.Scanner` 逐行扫描，缓冲区上限 16MB（应对极深调用栈）
- 每行 `strings.LastIndexByte(line, ' ')` 分隔栈与计数
- `strings.Split(stackStr, ";")` 拆分帧
- 跳过 count ≤ 0 的行

**`internal/profile/speedscope.go`** — `ToSpeedscope(stacks, name)`：
- frame deduplication：`map[string]int` 缓存帧名到索引
- 输出 `sampled` 类型 profile：`samples` 是 frame index 数组（从底到顶），`weights` 是采样计数
- `EndValue = sum(weights)` 表示总采样数

#### 5.1.4 HTTP Handler

**Profile 路由**（`profile_handler.go`）：

| 路由 | 关键逻辑 |
|---|---|
| `POST /api/profiles/upload` | `MaxBytesReader(32MB)` → `json.Decode` → `ParseFolded` → `InsertProfile` |
| `GET /api/profiles` | query 解析 → `ListProfiles(filter)`（默认 limit=100，上限 1000） |
| `GET /api/profiles/{id}` | `PathValue("id")` → `GetProfile(id)` |
| `GET /api/profiles/{id}/speedscope.json` | 取 folded_text → `ToSpeedscope` → 带 CORS 头响应 |
| `GET /api/profiles/{id}/folded.txt` | 原始折叠栈下载（Content-Disposition: attachment） |

**Trace 路由**（`trace_handler.go`）：

| 路由 | 关键逻辑 |
|---|---|
| `POST /api/traces/batch` | `MaxBytesReader(8MB)` → `ParseNDJSONTraces` → `InsertTraces` 事务 |
| `GET /api/traces` | `parseTraceFilter` → `QueryTraces` |
| `GET /api/traces/stats` | `parseTraceFilter` → `AggregateStats` |
| `GET /api/traces/timeseries` | `parseTraceFilter` + `bucket_sec` query → `QueryTimeseries` |

**通用工具**（`util.go`）：`writeJSON(w, status, v)`、`writeError(w, status, msg)`。

### 5.2 前端实现

#### 5.2.1 页面结构

| 页面 | 元素 ID 约定 | 数据源 |
|---|---|---|
| `index.html` | 三张功能卡片（火焰图/接口耗时/健康检查） | 静态 |
| `profiles.html` | `filter-service`, `filter-node`, `profile-list`, `speedscope-hint` | `/api/profiles` |
| `traces.html` | `filter-service`, `filter-cmd`, `range-group`, `stat-total/avg/p95/p99/slow`, `stat-list`, `chart`, `detail-section` | `/api/traces/stats` + `/api/traces/timeseries` + `/api/traces` |

#### 5.2.2 speedscope 嵌入机制

```js
viewFlame(id, service) {
  var url = '/api/profiles/' + id + '/speedscope.json';
  var title = service + ' #' + id;
  var ssUrl = '/assets/vendor/speedscope/index.html#profileURL=' +
    encodeURIComponent(url) + '&title=' + encodeURIComponent(title);
  window.open(ssUrl, '_blank');
}
```

- speedscope 通过 URL hash fragment `#profileURL=` 加载远程 JSON
- 后端 `/api/profiles/{id}/speedscope.json` 必须设置 `Access-Control-Allow-Origin: *`（speedscope 是独立 origin）
- 启动时 `checkSpeedscope()` HEAD 探测 `index.html` 是否存在，未下载则显示提示

#### 5.2.3 纯 SVG 折线图

`renderLineChart(buckets)` 实现：
- 视口 `1100×300`，内边距 `PAD_L=50, PAD_R=20, PAD_T=20, PAD_B=40`
- 三条折线：Avg（蓝 #2563eb）/ P95（红 #dc2626）/ P99（紫 #9333ea，虚线）
- P99 由前端 `p95 * 1.1` 估算（后端 timeseries 仅返回 avg/p95）
- X 轴 5 个刻度、Y 轴 4 个刻度，自适应 maxV
- `highlightSlow(ms)`：≥500 红色、≥200 橙色、其他默认

#### 5.2.4 时间范围与桶配置

```js
var TRACE_RANGES = {
  3600:   { bucket: 60,    label: '1h' },
  21600:  { bucket: 300,   label: '6h' },
  86400:  { bucket: 1800,  label: '24h' },
  604800: { bucket: 7200,  label: '7d' }
};
```

切换范围按钮会重新拉取 stats + timeseries（并行 fetch）。

### 5.3 Skynet 端实现

#### 5.3.1 preload 自动初始化

`skynet-agent/lua/preload.lua` 通过 skynet config 的 `preload` 字段在所有 snlua 服务启动时执行：

```lua
firegraph.init({
  server_host            = env("firegraph_host", "127.0.0.1"),
  server_port            = tonumber(env("firegraph_port", "8080")),
  service                = env("service_name", "unknown"),
  node                   = env("node_name", "default"),
  auto_profile_interval  = tonumber(env("firegraph_auto_profile_interval", "0")),
  auto_profile_duration  = tonumber(env("firegraph_auto_profile_duration", "30")),
})
if env("firegraph_enable_tracer", false) then
  firegraph.install_tracer()
end
```

#### 5.3.2 采样器（双模式）

**`swt_bridge.lua`** 设计为「内置优先 + swt 可选」：

```lua
function M.start(duration_sec)
  local ok, swt = pcall(require, "swt")
  if ok and swt and swt.start_profile then
    M._use_swt = true; M._swt = swt
    swt.start_profile(duration_sec)
  else
    M._use_swt = false
    debug.sethook(hook_fn, "l", line_threshold)  -- 5000 行采样一次
  end
end
```

**hook_fn 逻辑**：
```lua
local function hook_fn(event, line)
  if not hook_active then return end
  local tb = debug.traceback("", 4)        -- 跳过 hook 自身和上层
  local frames = parse_traceback(tb)       -- 解析为帧名数组
  if #frames == 0 then frames = {"?"} end
  local key = table.concat(frames, ";")
  stack_counts[key] = (stack_counts[key] or 0) + 1
  sample_total = sample_total + 1
end
```

**parse_traceback**：从 `debug.traceback` 字符串提取帧名（支持 `in function 'xxx'`、`in local 'xxx'`、`in main chunk` 等格式），并补充 `@文件名:行号`，反转顺序为从底到顶。

**stop**：拼装 `stack count` 行 → `on_complete` 回调 → 上层 `init.lua` 调用 `reporter.report_profile`。

#### 5.3.3 Tracer（dispatch 包装）

**`tracer.lua`** 核心替换：

```lua
local original_dispatch = skynet.dispatch
skynet.dispatch = function(proto, handler)
  local wrapped = function(session, source, msg, sz, ...)
    local co = coroutine.running()
    local start = skynet.now()
    local ok, err = pcall(handler, session, source, msg, sz, ...)
    local cost = skynet.now() - start       -- 1/100 秒
    local cmd = current_cmd[co] or proto
    current_cmd[co] = nil
    M._record({
      ts = math.floor(skynet.time()),
      service = config.service,
      proto = proto, cmd = cmd,
      session = session,
      cost_ms = cost * 10,                  -- 1/100 秒 → 毫秒
      ok = ok and 1 or 0,
    })
    if not ok then error(err, 0) end
  end
  original_dispatch(proto, wrapped)
end
```

**关键设计**：
- `coroutine.running()` 作为 key 存储 `current_cmd`（协程级 threadlocal）
- 业务可在 handler 内调用 `firegraph.tag_cmd(cmd)` 标记真实命令名
- `_flush_loop` 协程每 5s flush，`_record` 累积 100 条立即 flush
- flush 通过 `skynet.fork` 异步上报，不阻塞 dispatch

#### 5.3.4 Reporter（HTTP 上报）

**`reporter.lua`**：
- `report_profile`：手写 JSON 编码（转义 `\ " \n \r \t`），3 次重试间隔 1s
- `report_traces`：构建 NDJSON（每行一个 JSON 对象），3 次重试
- `_http_post`：调用 `skynet.httpc.request("POST", host:port, path, header, body)`

**手写 JSON 编码理由**：避免依赖 `cjson`（部分 skynet 构建未启用）。

---

## 6. 数据格式与接口定义

### 6.1 数据库表

#### profiles 表

| 字段 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK AUTOINCREMENT | 主键 |
| service_name | TEXT NOT NULL | snlua 服务名 |
| node | TEXT NOT NULL | 节点名 |
| sampled_at | INTEGER NOT NULL | 采样结束 unix 时间戳（秒） |
| duration_sec | INTEGER NOT NULL | 采样持续时长 |
| folded_text | TEXT NOT NULL | 折叠栈原文 |
| sample_count | INTEGER NOT NULL | 采样总数 |
| created_at | INTEGER NOT NULL | 入库时间戳 |

索引：`idx_profiles_lookup(service_name, sampled_at)`

#### traces 表

| 字段 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK AUTOINCREMENT | 主键 |
| ts | INTEGER NOT NULL | 消息处理时间戳（秒） |
| service | TEXT NOT NULL | snlua 服务名 |
| proto | TEXT NOT NULL | 协议名（lua/text/response） |
| cmd | TEXT NOT NULL | 命令名 |
| session | INTEGER | skynet session id（可空） |
| cost_ms | INTEGER NOT NULL | 处理耗时（毫秒） |
| ok | INTEGER NOT NULL | 1=成功 0=失败 |

索引：`idx_traces_lookup(service, cmd, ts)`、`idx_traces_ts(ts)`

### 6.2 折叠栈格式（Folded Stacks）

每行一条调用栈，格式：`frame1;frame2;frame3 count`

- 栈底在前，`;` 分隔帧
- 空格分隔计数（栈中函数名不含空格）
- 兼容 [FlameGraph.pl](https://github.com/brendangregg/FlameGraph) 与 speedscope

示例：
```
main;skynet.dispatch;login_handler;check_token 50
main;skynet.dispatch;login_handler;db_query 150
main;skynet.dispatch;login_handler;db_query;parse_result 30
```

### 6.3 speedscope JSON Schema

后端 `/api/profiles/{id}/speedscope.json` 返回 [speedscope `sampled` 格式](https://github.com/jlfwong/speedscope/blob/main/src/lib/file-format-spec.ts)：

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

关键字段：
- `shared.frames`：去重后的帧表（name → index）
- `profiles[0].samples`：每个元素是一个 frame index 数组（从底到顶）
- `profiles[0].weights`：每个采样的权重（对应折叠栈的 count）
- `endValue`：总采样数（sum of weights）

### 6.4 NDJSON Trace 格式

`POST /api/traces/batch` 请求体为 NDJSON（每行一个 JSON 对象）：

```json
{"ts":1719600000,"service":"login","proto":"lua","cmd":"Login","session":12345,"cost_ms":12,"ok":true}
{"ts":1719600001,"service":"login","proto":"lua","cmd":"Logout","session":12346,"cost_ms":8,"ok":true}
```

字段说明：
- `ts`：消息处理时间戳（unix 秒）
- `service`：snlua 服务名
- `proto`：协议名（如 `lua`）
- `cmd`：命令名（dispatch 标记，业务通过 `firegraph.tag_cmd(cmd)` 设置）
- `session`：skynet session id（可空，空时写 NULL）
- `cost_ms`：处理耗时（毫秒）
- `ok`：是否成功（boolean，兼容字符串 `"true"/"false"`）

**容错**：解析器跳过格式错误的行，不阻塞整批。

### 6.5 HTTP API 完整定义

#### Profile API

##### POST /api/profiles/upload

上报折叠栈。

**请求体**（JSON）：
```json
{
  "service_name": "login",
  "node": "node1",
  "sampled_at": 1719600000,
  "duration_sec": 30,
  "folded_text": "main;foo;bar 123\nmain;foo;baz 45"
}
```

**响应**（200）：
```json
{"id": 1, "sample_count": 168}
```

**限制**：body 上限 32MB；`sampled_at` 为 0 时用服务端时间。

##### GET /api/profiles

列表查询。

**Query**：`service`, `node`, `from`, `to`, `limit`(默认 100, 上限 1000), `offset`

**响应**：
```json
{
  "items": [{
    "id": 1, "service_name": "login", "node": "node1",
    "sampled_at": 1719600000, "duration_sec": 30,
    "sample_count": 168, "created_at": 1719600030
  }]
}
```

##### GET /api/profiles/{id}

详情（含 folded_text 大字段）。

##### GET /api/profiles/{id}/speedscope.json

返回 speedscope `sampled` JSON，带 `Access-Control-Allow-Origin: *`。

##### GET /api/profiles/{id}/folded.txt

原始折叠栈文本下载，`Content-Disposition: attachment; filename=profile_{id}.folded`。

#### Trace API

##### POST /api/traces/batch

批量上报 NDJSON。

**请求体**：NDJSON（见 §6.4）

**响应**（200）：
```json
{"inserted": 200, "received": 200}
```

**限制**：body 上限 8MB。

##### GET /api/traces

明细分页。

**Query**：`service`, `cmd`, `from`, `to`, `limit`(默认 100, 上限 1000), `offset`

**响应**：
```json
{
  "items": [{
    "id": 1, "ts": 1719600000, "service": "login", "proto": "lua",
    "cmd": "Login", "session": 12345, "cost_ms": 12, "ok": true
  }]
}
```

##### GET /api/traces/stats

聚合统计（按 service+cmd 分组）。

**Query**：`service`, `cmd`, `from`, `to`, `limit`

**响应**：
```json
{
  "items": [{
    "service": "login", "cmd": "Login",
    "count": 46, "ok_count": 40,
    "avg_ms": 196, "max_ms": 345, "min_ms": 5,
    "p50_ms": 197, "p95_ms": 330, "p99_ms": 342
  }]
}
```

##### GET /api/traces/timeseries

时间序列（按 bucket_sec 分桶）。

**Query**：`service`, `cmd`, `from`, `to`, `bucket_sec`(默认 60)

**响应**：
```json
{
  "items": [{
    "ts": 1719599940, "count": 12, "avg_ms": 180, "p95_ms": 290
  }]
}
```

#### 其他

- `GET /healthz` → `ok`（200）
- `GET /` → 前端静态资源（API 路径 `/api/*` 和 `/healthz` 不走静态）

---

## 7. 使用说明

### 7.1 后端构建与启动

```bash
# 1. 构建（需 Go 1.22+，纯 Go 无 CGO）
go build -o bin/firegraph ./cmd/firegraph
# 或用脚本（带 -trimpath -ldflags "-s -w"）
bash scripts/build.sh

# 2. 下载 speedscope 离线包（一次性）
bash scripts/fetch_assets.sh    # 下载到 web/assets/vendor/speedscope/

# 3. 启动
./bin/firegraph -config configs/firegraph.yaml
# 默认监听 :8080，DB 文件 firegraph.db
```

打开浏览器访问 `http://localhost:8080/`。

### 7.2 配置文件

`configs/firegraph.yaml`：

```yaml
server:
  addr: ":8080"        # HTTP 监听地址
  web_dir: "./web"     # 前端静态资源目录

store:
  dsn: "firegraph.db"  # SQLite 文件路径
  retention_days: 7    # 数据保留天数（0=永久）
```

未指定 `-config` 时使用默认值。

### 7.3 Skynet 端接入

#### 方式 1：preload 自动初始化（推荐）

在 skynet config 中配置：

```lua
lua_path  = "./skynet-agent/lua/?.lua;./skynet-agent/lua/?/init.lua"
preload   = "./skynet-agent/lua/preload.lua"

firegraph_host = "127.0.0.1"
firegraph_port = 8080
service_name   = "login"
node_name      = "node1"
firegraph_auto_profile_interval = 300     -- 每 5 分钟自动采样（0=不自动）
firegraph_auto_profile_duration = 30      -- 每次采样 30 秒
firegraph_enable_tracer = true            -- 启用接口埋点
```

所有 snlua 服务启动时自动初始化，无需业务代码改动。

#### 方式 2：业务代码手动初始化

```lua
local firegraph = require "firegraph"
firegraph.init({
  server_host = "127.0.0.1",
  server_port = 8080,
  service     = "login",
  node        = "node1",
})
firegraph.start_profile(60)              -- 手动触发 60 秒采样
firegraph.install_tracer()               -- 安装接口埋点
```

#### 业务侧标记 cmd

```lua
skynet.dispatch("lua", function(session, source, cmd, ...)
  firegraph.tag_cmd(cmd)                  -- 用业务协议的 cmd 字段
  -- 业务逻辑
end)
```

未调用 `tag_cmd` 时，cmd 默认为 proto 名（如 `lua`）。

### 7.4 采样器选择

| 采样器 | 配置 | 精度 | 依赖 |
|---|---|---|---|
| **内置**（默认） | 无需配置 | 中（仅当前协程） | 无 C 模块 |
| **swt**（可选） | 在 `swt_bridge.lua` 调整 swt API | 高（全服务） | skynet 源码 patch |

内置采样器开箱即用，适合开发期分析与 CPU 密集型业务定位。生产环境如需精确全服务采样，请接入 swt（详见 `skynet-agent/README.md`）。

### 7.5 离线生成静态火焰图（可选）

```bash
# 下载折叠栈
curl http://localhost:8080/api/profiles/1/folded.txt -o out.folded
# 用 FlameGraph.pl 生成 SVG
./flamegraph.pl out.folded > out.svg
```

---

## 8. 已知限制

### 8.1 采样器局限

1. **内置采样器基于 `debug.sethook`**：只能采样设置了 hook 的协程。skynet snlua 服务是多协程的，跨协程采样不完整。
   - 影响：CPU 密集型业务（通常集中在少数协程）足够；IO 密集型跨协程业务可能漏采。
   - 缓解：接入 swt 获得全服务精确采样。

2. **行模式采样精度**：`line_threshold=5000` 平衡开销与精度，极短函数可能被漏采。

3. **swt 适配为示意代码**：`swt_bridge.lua` 中的 swt 调用（`swt.start_profile` / `swt.dump_folded`）需根据 swt 实际版本 API 调整。

### 8.2 性能限制

1. **分位数内存计算**：`/api/traces/stats` 的 P50/P95/P99 在 Go 内存中计算（拉排序数组），数据量大时（单接口百万级）查询变慢。
2. **timeseries 每桶单独查询 P95**：桶数量多时查询次数 = 桶数，可优化为 window function。
3. **trace 上报对业务性能影响**：dispatch 包装会增加 ~微秒级开销/消息；批量上报 + 异步发送，总体可忽略；生产前需压测确认。

### 8.3 功能限制

1. **无鉴权**：当前为内网部署设计，未实现鉴权。公网部署需自行加反向代理 + auth。
2. **无多节点聚合**：当前按 service+cmd 聚合，未做 node 维度查询。
3. **无告警**：P95 超阈值不会主动通知。
4. **P99 由前端估算**：timeseries 仅返回 avg/p95，前端用 `p95 * 1.1` 估算 P99 展示。
5. **慢调用统计为估算**：`stat-slow` 用 `p95>200` 的接口 `count * 0.05` 估算，非精确值。

### 8.4 兼容性

1. **Skynet 版本**：swt 要求 skynet 源码应用 commit `4ace42e8` 的小修改。内置采样器对 skynet 版本无要求。
2. **Lua 版本**：内置采样器依赖 `debug.sethook`，支持 Lua 5.3/5.4。
3. **Go 版本**：需 1.22+（路由用 `METHOD /path/{id}` 语法）。

---

## 9. 优化与扩展方向

### 9.1 性能优化

| 优化点 | 方案 | 优先级 |
|---|---|---|
| 分位数查询慢 | ①预聚合表（每分钟聚合 service+cmd 的 cost 分布）②SQLite window function ③迁移 ClickHouse（>10万 QPS） | 高 |
| timeseries P95 N+1 查询 | 用 SQL window function 一次性算出每桶 P95 | 中 |
| trace 上报吞吐 | ①UDP 替代 HTTP ②本地缓冲文件，批量回放 | 中 |
| SQLite 写入瓶颈 | ①WAL already enabled ②批量插入已用事务 ③高负载可切 BoltDB/BadgerDB | 低 |

### 9.2 功能扩展

#### 9.2.1 历史对比（Differential FlameGraph）
- 用 FlameGraph.pl 的 `--diff` 生成对比 SVG
- 后端新增 `/api/profiles/diff?id1=&id2=` 接口

#### 9.2.2 多节点聚合
- swt master 模式收集多 agent
- 后端按 node 维度查询、聚合
- 前端增加 node 过滤器

#### 9.2.3 告警
- 接口 P95 超阈值触发 webhook
- 后端定时任务扫描最近 N 分钟数据
- 配置告警规则（service/cmd/threshold/cooldown）

#### 9.2.4 鉴权
- Basic Auth 或 Token
- 反向代理 + auth（nginx/caddy）

#### 9.2.5 实时观测
- WebSocket 推送实时 trace
- 前端实时滚动展示慢调用

#### 9.2.6 服务拓扑
- 基于 trace 的 source → service 关系绘制调用图
- 用 go-graphviz 服务端生成 PNG/SVG

### 9.3 可维护性改进

| 改进点 | 方案 |
|---|---|
| 缺少单元测试 | 为 `profile.ParseFolded`、`percentile`、`ParseNDJSONTraces` 加测试 |
| 缺少集成测试 | 端到端测试：上报 → 查询 → 校验 |
| 配置热加载 | SIGHUP 触发配置重载 |
| 结构化日志 | 替换 `log.Printf` 为 zap/zerolog |
| 指标暴露 | `/metrics` 暴露 Prometheus 指标 |

---

## 10. 附录

### 10.1 项目结构

```
firegraph/
├── cmd/firegraph/main.go              # 后端入口
├── internal/
│   ├── config/config.go               # 配置加载
│   ├── server/
│   │   ├── server.go                  # HTTP 服务 + 路由
│   │   ├── profile_handler.go         # 5 个 profile 路由
│   │   ├── trace_handler.go           # 4 个 trace 路由
│   │   └── util.go                    # writeJSON/writeError
│   ├── store/
│   │   ├── store.go                   # SQLite 连接 + WAL
│   │   ├── schema.sql                 # profiles + traces 表
│   │   ├── profile_repo.go            # Profile CRUD
│   │   └── trace_repo.go              # Trace 批量插入 + 聚合
│   └── profile/
│       ├── folded.go                  # 折叠栈解析
│       └── speedscope.go              # folded → speedscope 转换
├── web/                               # 前端（原生 JS + SVG）
│   ├── index.html                     # 首页
│   ├── profiles.html                  # 火焰图列表
│   ├── traces.html                    # 接口耗时面板
│   └── assets/
│       ├── app.js                     # 前端逻辑
│       ├── app.css                    # 样式
│       └── vendor/speedscope/         # speedscope 离线包（脚本下载）
├── skynet-agent/                      # Skynet 端 Lua 模块
│   ├── README.md                      # 接入文档
│   └── lua/
│       ├── preload.lua                # skynet preload 入口
│       └── firegraph/
│           ├── init.lua               # 模块入口
│           ├── swt_bridge.lua         # 采样器（内置 + swt）
│           ├── tracer.lua             # 接口埋点
│           └── reporter.lua           # HTTP 上报
├── scripts/
│   ├── build.sh                       # 构建脚本
│   └── fetch_assets.sh                # 下载 speedscope
├── configs/firegraph.yaml             # 后端配置示例
├── docs/TECHNICAL_DESIGN.md           # 本文档
├── go.mod                             # Go 模块定义
├── README.md                          # 项目说明
└── .gitignore
```

### 10.2 Go 依赖

```
module github.com/firegraph/firegraph
go 1.25.5

require (
  gopkg.in/yaml.v3 v3.0.1
  modernc.org/sqlite v1.53.0
)
```

无 CGO 依赖，`CGO_ENABLED=0` 可编译。

### 10.3 关键常量

| 常量 | 值 | 位置 | 说明 |
|---|---|---|---|
| `line_threshold` | 5000 | `swt_bridge.lua` | 内置采样器每 5000 行 Lua 指令采样一次 |
| `FLUSH_THRESHOLD` | 100 | `tracer.lua` | trace 累积 100 条立即上报 |
| `FLUSH_INTERVAL` | 500 (1/100 秒 = 5s) | `tracer.lua` | 定时上报间隔 |
| Profile 上报重试 | 3 次 | `reporter.lua` | 间隔 1s |
| Trace 上报重试 | 3 次 | `reporter.lua` | 间隔 1s |
| Profile body 上限 | 32MB | `profile_handler.go` | 防止超大上报 |
| Trace body 上限 | 8MB | `trace_handler.go` | 防止超大上报 |
| List 默认 limit | 100 | `*_handler.go` | 上限 1000 |
| 折叠栈单行缓冲 | 16MB | `folded.go` | `bufio.Scanner` 缓冲上限 |
| SQLite busy_timeout | 5000ms | `store.go` | 并发写等待 |
| 默认 retention | 7 天 | `config.go` | 0=永久 |

### 10.4 时间单位换算

| 来源 | 单位 | 换算 |
|---|---|---|
| `skynet.now()` | 1/100 秒 | `cost_ms = (now2 - now1) * 10` |
| `skynet.time()` | unix 秒 | 直接用 |
| `skynet.sleep(n)` | 1/100 秒 | `sleep(500)` = 5 秒 |
| DB `ts` / `sampled_at` / `created_at` | unix 秒 | - |
| DB `cost_ms` | 毫秒 | - |
| DB `duration_sec` | 秒 | - |

### 10.5 术语表

| 术语 | 含义 |
|---|---|
| snlua | skynet 中的 Lua 服务（actor） |
| dispatch | skynet 消息分发注册函数 |
| proto | 协议名（lua/text/response 等） |
| session | skynet 消息会话 ID |
| Folded Stacks | 折叠栈格式：`a;b;c 123` |
| speedscope `sampled` | speedscope 采样型 profile JSON 格式 |
| swt | lsg2020/swt，skynet Lua profiler |
| WAL | SQLite Write-Ahead Logging |
| NDJSON | Newline-Delimited JSON，每行一个 JSON 对象 |
| P50/P95/P99 | 50/95/99 百分位数 |

### 10.6 变更记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-06-28 | 初版：火焰图 MVP + 接口耗时埋点 |

---

**文档结束。** 本文可作为后续 AI 辅助开发的输入规范，修改代码时请同步更新本文档对应章节。
