# Skynet 游戏服务器性能 & 接口耗时监测工具 — 实施计划

## Summary

构建一个面向 Skynet + Lua 游戏服务器的性能监测平台，集成现有开源工具（swt、speedscope、FlameGraph）做组装和定制，提供两类核心能力：

1. **CPU 火焰图**：运行时启停 Lua 调用栈采样，浏览器内交互查看（Time Order / Left Heavy / Sandwich 三视图）
2. **接口耗时统计**：通过 dispatch 层无侵入埋点，记录每个消息的处理耗时，提供列表、P50/P95/P99 分位、趋势图

整体架构：`Skynet 端采集 (Lua) → 上报 → Go 服务端 (聚合 + SQLite 存储) → Web UI (speedscope + 自研接口页)`，单二进制部署，无外部重型依赖。

---

## Current State Analysis

- **工作目录** `d:\MyPoj\firegraph` 为空，全新项目。
- **运行环境**：开发机 Windows，目标部署 Linux（Skynet 游戏服务器标准环境）。
- **被监测对象**：Skynet + Lua 游戏服务器（多 snlua 服务/actor 模型）。
- **技术选型（用户确认）**：
  - 采集方式：采样 + 埋点结合
  - 可视化：Web UI
  - 方案：集成现有开源工具（不自研全部）

### 关键依赖工具调研结论

| 工具 | 用途 | 集成方式 |
|---|---|---|
| **swt** (lsg2020/swt) | Skynet 端 Lua profiler，运行时启停，master/agent 架构 | 作为子模块引入到 Skynet 项目，作为采样数据源 |
| **speedscope** (jlfwong/speedscope) | 纯浏览器火焰图查看器 | 下载离线 release 包，由后端 static 服务托管 |
| **FlameGraph.pl** (brendangregg) | 折叠栈 → SVG 静态图（备份/导出用） | 后端进程内调用或预生成 |
| **SQLite** (mattn/go-sqlite3) | 存储 profile 元数据 + 接口耗时记录 | Go 后端嵌入，单文件 DB |
| **go-graphviz** (goccy/go-graphviz) | 服务端生成调用关系图（可选） | 仅在需要导出 PNG/SVG 时启用 |

### 数据格式标准

- **采样数据**：折叠栈格式（Folded Stacks）`main;foo;bar 123`，兼容 FlameGraph.pl 与 speedscope
- **接口埋点**：JSON 行格式，每行一条记录：
  ```json
  {"ts":1719600000,"service":"login","proto":"lua","cmd":"Login","session":12345,"cost_ms":12,"ok":true}
  ```
- **speedscope JSON**：后端按需将折叠栈转换为 speedscope `sampled` 格式 JSON 供前端加载

---

## Proposed Changes

### 项目结构

```
firegraph/
├── README.md                          # 项目说明（最后补）
├── go.mod                             # Go 后端模块
├── cmd/
│   └── firegraph/
│       └── main.go                    # 后端入口
├── internal/
│   ├── server/                        # HTTP 服务 + 路由
│   │   ├── server.go
│   │   ├── profile_handler.go         # profile 上传/查询/下载
│   │   └── trace_handler.go           # 接口耗时查询
│   ├── store/                         # SQLite 存储层
│   │   ├── store.go
│   │   ├── schema.sql
│   │   ├── profile_repo.go
│   │   └── trace_repo.go
│   ├── profile/                       # profile 数据处理
│   │   ├── folded.go                  # 折叠栈解析/聚合
│   │   └── speedscope.go              # folded → speedscope JSON 转换
│   └── config/
│       └── config.go
├── web/                               # 前端静态资源
│   ├── index.html                     # 首页（导航）
│   ├── profiles.html                  # profile 列表页
│   ├── traces.html                    # 接口耗时页
│   ├── assets/
│   │   ├── app.js                     # 自研轻量 JS（无框架）
│   │   ├── app.css
│   │   └── vendor/
│   │       ├── speedscope/            # speedscope 离线包（解压 release）
│   │       └── echarts/               # ECharts CDN 或本地（耗时图表）
│   └── api.md                         # API 文档（自用）
├── skynet-agent/                      # Skynet 端采集模块（Lua）
│   ├── README.md
│   ├── lua/
│   │   ├── firegraph/
│   │   │   ├── init.lua               # 模块入口
│   │   │   ├── tracer.lua             # 接口埋点（dispatch hook）
│   │   │   ├── reporter.lua           # HTTP 上报客户端
│   │   │   └── swt_bridge.lua         # 对接 swt profiler 的桥接
│   │   └── preload.lua                # 配置为 skynet preload
│   └── c/
│       └── lhook.c                    # 可选 C hook（如需更高精度采样）
├── third_party/
│   ├── swt/                           # git submodule: lsg2020/swt
│   └── FlameGraph/                    # git submodule: brendangregg/FlameGraph
├── configs/
│   └── firegraph.yaml                 # 后端配置示例
├── scripts/
│   ├── build.sh                       # 构建后端
│   ├── fetch_assets.sh                # 下载 speedscope 离线包
│   └── demo_skynet/                   # 最小 Skynet demo 用于联调
└── .trae/
    └── documents/
        └── skynet-flamegraph-monitor-plan.md  # 本文件
```

### 阶段划分

为避免一次性交付过大，分 3 阶段递进，每阶段可独立验证。

---

### 阶段 1：火焰图核心链路（MVP）

**目标**：从 Skynet 采样 → 上报 → Go 后端存储 → speedscope 浏览器查看，全链路打通。

#### 1.1 Skynet 端集成 swt（采样源）

- **新增** `third_party/swt/` 作为 git submodule（URL: https://github.com/lsg2020/swt）
- **新增** `skynet-agent/lua/firegraph/swt_bridge.lua`：
  - 封装 swt 的 `start` / `stop` / `dump` 接口
  - 采样启动后定时（默认 30s）或按需 dump 一次折叠栈
  - 输出格式：`skynet_service_name;func_a;func_b;func_c <count>`
- **修改** Skynet 项目配置（在 demo 中演示）：
  - `preload = "./skynet-agent/lua/preload.lua"`
  - preload 中 `require "firegraph"` 完成初始化
- **注意**：swt 需要 skynet 源码含 commit `4ace42e8` 的小修改，在 demo 中提供 patch

#### 1.2 上报客户端

- **新增** `skynet-agent/lua/firegraph/reporter.lua`：
  - HTTP POST 折叠栈数据到 Go 后端 `/api/profiles/upload`
  - 字段：`service_name`、`node`、`sampled_at`、`duration_sec`、`folded_text`
  - 使用 skynet 内置 socket / curl（避免引入额外依赖）
  - 失败重试 3 次，超过则丢弃本次（不阻塞业务）

#### 1.3 Go 后端 — HTTP 服务 + 存储

- **新增** `cmd/firegraph/main.go`：加载配置、初始化 store、启动 HTTP server
- **新增** `internal/store/schema.sql`：
  ```sql
  CREATE TABLE IF NOT EXISTS profiles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_name TEXT NOT NULL,
    node TEXT NOT NULL,
    sampled_at INTEGER NOT NULL,    -- unix ts
    duration_sec INTEGER NOT NULL,
    folded_text TEXT NOT NULL,
    sample_count INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_profiles_lookup ON profiles(service_name, sampled_at);

  CREATE TABLE IF NOT EXISTS traces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    service TEXT NOT NULL,
    proto TEXT NOT NULL,
    cmd TEXT NOT NULL,
    session INTEGER,
    cost_ms INTEGER NOT NULL,
    ok INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_traces_lookup ON traces(service, cmd, ts);
  ```
- **新增** `internal/store/profile_repo.go`：`InsertProfile`、`ListProfiles(filter)`、`GetProfile(id)`、`DeleteOldProfiles(beforeTs)`
- **新增** `internal/server/profile_handler.go`：
  - `POST /api/profiles/upload` — 接收折叠栈，写入 DB
  - `GET /api/profiles` — 列表（支持 service/time 过滤）
  - `GET /api/profiles/{id}` — 返回原始折叠栈文本（供 FlameGraph.pl 或前端转换）
  - `GET /api/profiles/{id}/speedscope.json` — 返回 speedscope JSON

#### 1.4 折叠栈 → speedscope 转换

- **新增** `internal/profile/folded.go`：
  - 解析 `a;b;c 123` 格式为 `map[stack]count`
  - 聚合多个折叠栈文件
- **新增** `internal/profile/speedscope.go`：
  - 实现 folded → speedscope `sampled` 格式转换
  - speedscope `sampled` schema 关键字段：
    ```json
    {
      "$schema": "https://www.speedscope.app/file-format-schema.json",
      "shared": {"frames": [{"name": "main"}, {"name": "foo"}, ...]},
      "profiles": [{
        "type": "sampled",
        "name": "service@login 2026-06-28 10:00",
        "unit": "samples",
        "startValue": 0,
        "endValue": 12345,
        "samples": [[0,1,2], [0,1,3], ...],   // frame indices
        "weights": [100, 23, ...]
      }]
    }
    ```

#### 1.5 前端 — speedscope 嵌入

- **新增** `web/index.html`：首页，列出最近 profile，点击「在 speedscope 中查看」
- **新增** `web/profiles.html`：profile 列表页（service/时间过滤），每条「查看火焰图」按钮
  - 按钮逻辑：`window.open('/assets/vendor/speedscope/index.html#profileURL=' + encodeURIComponent('/api/profiles/123/speedscope.json') + '&title=' + encodeURIComponent(title))`
- **新增** `scripts/fetch_assets.sh`：从 speedscope releases 下载离线 zip 解压到 `web/assets/vendor/speedscope/`
- **注意**：speedscope 通过 hash fragment 加载远程 profile，需后端在 `/api/profiles/{id}/speedscope.json` 设置 `Access-Control-Allow-Origin: *`（speedscope 是 file:// 或独立 origin 时需要）

---

### 阶段 2：接口耗时埋点 & 统计

**目标**：无侵入采集 Skynet 消息处理耗时，前端查看 P50/P95/P99 + 趋势图。

#### 2.1 Lua 端 dispatch 埋点

- **新增** `skynet-agent/lua/firegraph/tracer.lua`：
  - 在用户调用 `firegraph.install()` 时，包装 `skynet.dispatch` 注册的 handler
  - 实现思路：保存原 `skynet.dispatch`，替换为包装版本，在 handler 入口记录 `start = skynet.now()`，出口记录 `cost = skynet.now() - start`（skynet 时间单位为 1/100 秒，需换算为 ms）
  - 生成 trace 记录：`{ts, service, proto, cmd, session, cost_ms, ok}`
  - 通过 reporter 批量上报（每 100 条或每 5s 一次）
- **关键决策**：在 `skynet.dispatch` 层埋点（而非 `skynet.call`），原因：
  - 覆盖所有进入服务的消息（包括 `skynet.send` 单向消息）
  - 无需业务代码改动（只需 preload 一次安装）
  - 记录的是「处理耗时」而非「RPC 往返耗时」，符合"接口耗时"语义

#### 2.2 上报扩展

- **扩展** `skynet-agent/lua/firegraph/reporter.lua`：新增 `POST /api/traces/batch` 上报接口
  - 批量上报，每条 trace 一行 JSON（NDJSON 格式）
  - 失败时本地缓存最多 1000 条，下次成功时回放

#### 2.3 Go 后端 — trace 接口

- **新增** `internal/store/trace_repo.go`：`InsertTraces([]Trace)`、`QueryTraces(filter)`、`AggregateStats(groupBy, percentiles)`
- **新增** `internal/server/trace_handler.go`：
  - `POST /api/traces/batch` — 批量接收
  - `GET /api/traces` — 分页查询明细
  - `GET /api/traces/stats` — 聚合统计
    - Query: `service`、`cmd`、`from`、`to`、`percentiles=50,95,99`
    - Response: `[{service, cmd, count, p50, p95, p99, avg, max}]`
  - `GET /api/traces/timeseries` — 时间序列
    - Query: `service`、`cmd`、`from`、`to`、`bucket_sec=60`
    - Response: `[{ts, count, p95, avg}]`
  - 新增定时清理任务：保留最近 7 天 trace 数据（可配置）

#### 2.4 前端 — 接口耗时页

- **新增** `web/traces.html`：
  - 顶部筛选器：service 下拉、cmd 下拉、时间范围
  - 上方：ECharts 折线图（P95 趋势 + QPS）
  - 下方：表格（service/cmd/调用次数/P50/P95/P99/avg/max）
  - 点击表格行：展开明细，显示最近 N 条该接口的 trace
- **新增** `web/assets/app.js`：原生 JS（fetch + ECharts），无框架依赖
- **新增** `web/assets/vendor/echarts/`：ECharts 本地化（避免内网无 CDN）

---

### 阶段 3：历史管理 & 增强（可选，按需推进）

- profile 历史对比（differential flame graph）：用 FlameGraph.pl 的 `--diff` 生成对比 SVG
- 多节点聚合：swt master 模式收集多 agent，后端按 node 维度查询
- 告警：接口 P95 超阈值触发 webhook
- 鉴权：basic auth 或 token（内网部署可后置）

---

## Assumptions & Decisions

### 假设

1. **Skynet 版本**：使用 lua5.4 版本的 skynet（swt 主支持），git commit 在 `eaa60ca8` 之后（snlua 含 activeL 字段）。若版本不符，需 apply `snlua53_set_activeL.diff`（lua5.3）或 swt 的对应 patch。
2. **swt 修改**：swt 要求 skynet 源码应用 commit `4ace42e8` 的小幅修改（debug 接口扩展）。demo 中提供 patch 文件，正式接入需用户在自家 skynet 仓库应用。
3. **部署环境**：Go 后端 + Skynet 服务器均在 Linux 运行；开发可在 Windows（Go 跨平台编译无障碍，Lua 模块在 Linux 测试）。
4. **网络**：Skynet 服务器与 Go 后端网络可达，HTTP 上报（无防火墙阻拦）。生产环境若需更高吞吐可后续切到 UDP/批量 TCP，但 MVP 用 HTTP 简单可靠。
5. **数据量**：单服务日均 trace 量在百万级以内，SQLite + 索引可承载；若超 10 万 QPS 持续上报，需迁移到 ClickHouse（阶段 3 决策）。

### 决策

| 决策点 | 选择 | 理由 |
|---|---|---|
| 后端语言 | **Go** | 单二进制部署、与 swt 生态一致、并发能力强、对游戏服务器团队友好 |
| 存储 | **SQLite** (mattn/go-sqlite3) | 无外部依赖、单文件、百万级数据查询性能足够、备份简单 |
| 前端框架 | **无框架，原生 JS + ECharts** | 减少构建链、内网页面加载快、维护成本低 |
| 火焰图渲染 | **speedscope 离线包** | 纯浏览器运行、交互体验最佳、支持三种视图 |
| Skynet 采样 | **swt** | 现成、支持运行时启停、master/agent 架构契合多节点 |
| 接口埋点层 | **skynet.dispatch 包装** | 无侵入、覆盖所有消息、记录「处理耗时」语义正确 |
| 上报协议 | **HTTP/JSON** | MVP 简单可靠、可读性好、调试方便 |
| swt 集成方式 | **git submodule** | 保留独立版本、便于跟进 upstream、不污染主仓库代码 |

### 已知风险

1. **swt 维护活跃度**：需评估其 issue/commit 频率；若停维护，备选方案是用 skynet-perf + 自研折叠栈输出。
2. **skynet 版本兼容**：swt 对 skynet 源码有小修改要求，接入前需确认用户 skynet 版本是否兼容。
3. **speedscope CORS**：speedscope 通过 `#profileURL=` 加载远程 JSON，需后端响应 CORS 头；已计入实现。
4. **trace 上报对业务性能影响**：dispatch 包装会增加 ~微秒级开销/消息；批量上报 + 异步发送，总体可忽略；生产前需压测确认。

---

## Verification Steps

### 阶段 1 验收

1. **本地构建**：`cd firegraph && go build ./cmd/firegraph` 成功产出二进制
2. **Demo 启动**：`scripts/demo_skynet/run.sh` 启动一个最小 skynet 实例（含 firegraph preload）
3. **采样触发**：通过 swt admin 接口或 firegraph API 启动 30s 采样
4. **数据落库**：`sqlite3 firegraph.db "SELECT count(*) FROM profiles"` ≥ 1
5. **火焰图查看**：浏览器打开 `http://localhost:8080/profiles.html`，点击查看，speedscope 正常渲染折叠栈
6. **格式校验**：`/api/profiles/{id}/speedscope.json` 返回的 JSON 能直接拖入 https://www.speedscope.app 正常加载

### 阶段 2 验收

1. **埋点生效**：发送测试消息到 demo 服务，`SELECT count(*) FROM traces` > 0
2. **耗时准确**：手动制造一个 `sleep 100ms` 的 handler，查询 trace 显示 cost_ms 在 95~105 区间
3. **统计正确**：`/api/traces/stats?service=login&percentiles=50,95,99` 返回结构正确、分位值合理
4. **趋势图渲染**：`traces.html` 时间范围内 ECharts 折线正常显示，无控制台报错
5. **批量上报**：模拟 1000 条 trace 批量上报，DB 准确写入 1000 条，耗时 < 1s

### 阶段 3 验收（如执行）

- 对比火焰图正常生成 SVG
- 多节点查询能区分 node 维度
- 告警 webhook 触发验证

---

## 实施顺序建议

1. 先搭骨架：`go.mod`、`cmd/firegraph/main.go`、`internal/store`、最小 HTTP 路由
2. 阶段 1.3 + 1.4（后端 profile 链路）— 可先用本地折叠栈文件模拟上报，不依赖 Skynet
3. 阶段 1.5（前端 speedscope 嵌入）— 验证转换 + 查看链路
4. 阶段 1.1 + 1.2（Skynet 端 swt 集成 + 上报）— 打通真实链路
5. 阶段 2 全部（接口埋点）
6. 联调 + 文档

每步完成后即可独立验证，避免大爆炸式集成。
