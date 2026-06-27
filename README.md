# firegraph

面向 **Skynet + Lua** 游戏服务器的性能监测平台，集成现有开源工具（[speedscope](https://github.com/jlfwong/speedscope)、[swt](https://github.com/lsg2020/swt)、[FlameGraph](https://github.com/brendangregg/FlameGraph)）做组装和定制，提供：

- **CPU 火焰图**：运行时启停 Lua 调用栈采样，浏览器内交互查看（speedscope 三视图）
- **接口耗时统计**：通过 dispatch 层无侵入埋点，记录每个消息处理耗时，P50/P95/P99 分位 + 趋势图

整体架构：`Skynet 端采集 (Lua) → HTTP 上报 → Go 服务端 (聚合 + SQLite) → Web UI`

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│ Skynet 游戏服务器 (Linux)                                    │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    │
│  │ snlua service│    │ snlua service│    │ snlua service│    │
│  │  firegraph   │    │  firegraph   │    │  firegraph   │    │
│  │  preload     │    │  preload     │    │  preload     │    │
│  │  ├─sampler   │    │  ├─sampler   │    │  ├─sampler   │    │
│  │  ├─tracer    │    │  ├─tracer    │    │  ├─tracer    │    │
│  │  └─reporter  │    │  └─reporter  │    │  └─reporter  │    │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘    │
│         │ HTTP/JSON         │                   │            │
└─────────┼───────────────────┼───────────────────┼────────────┘
          │                   │                   │
          ▼                   ▼                   ▼
┌─────────────────────────────────────────────────────────────┐
│ firegraph 后端 (Go 单二进制 + SQLite)                        │
│  POST /api/profiles/upload    ← 折叠栈上报                    │
│  POST /api/traces/batch       ← NDJSON 接口耗时批量上报        │
│  GET  /api/profiles           → 列表                          │
│  GET  /api/profiles/{id}/speedscope.json → speedscope JSON    │
│  GET  /api/traces/stats       → P50/P95/P99 聚合              │
│  GET  /api/traces/timeseries  → 时间序列                      │
│  GET  /                       → Web UI                        │
└─────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────┐
│ 浏览器                                                       │
│  /profiles.html → speedscope 嵌入式火焰图查看                 │
│  /traces.html   → 原生 SVG 趋势图 + 分位表格                  │
└─────────────────────────────────────────────────────────────┘
```

## 快速开始

### 1. 构建后端

```bash
# 需 Go 1.22+（纯 Go，无 CGO 依赖）
go build -o bin/firegraph ./cmd/firegraph
```

### 2. 下载 speedscope 离线包

```bash
bash scripts/fetch_assets.sh    # 下载到 web/assets/vendor/speedscope/
```

### 3. 启动服务

```bash
./bin/firegraph -config configs/firegraph.yaml
# 默认监听 :8080，DB 文件 firegraph.db
```

打开浏览器访问 `http://localhost:8080/`。

### 4. 接入 Skynet

把 `skynet-agent/lua/` 加入 `LUA_PATH`，在 skynet config 中配置：

```lua
lua_path  = "./skynet-agent/lua/?.lua;./skynet-agent/lua/?/init.lua"
preload   = "./skynet-agent/lua/preload.lua"

firegraph_host = "127.0.0.1"              -- 后端地址
firegraph_port = 8080
service_name   = "login"                  -- 当前服务名
node_name      = "node1"
firegraph_auto_profile_interval = 300     -- 每 5 分钟自动采样（0=不自动）
firegraph_auto_profile_duration = 30      -- 每次采样 30 秒
firegraph_enable_tracer = true            -- 启用接口埋点
```

所有 snlua 服务启动时自动初始化 firegraph，无需业务代码改动。

## 采样器说明

`skynet-agent/lua/firegraph/swt_bridge.lua` 提供两种采样器：

| 采样器 | 实现 | 精度 | 依赖 |
|---|---|---|---|
| **内置**（默认） | `debug.sethook("l", 5000)` 行模式 | 中（仅当前协程） | 无 C 模块 |
| **swt**（可选） | 接入 [lsg2020/swt](https://github.com/lsg2020/swt) | 高（全服务） | skynet 源码 patch |

内置采样器开箱即用，适合开发期分析与 CPU 密集型业务定位。
生产环境如需精确的全服务采样，请接入 swt（详见 `skynet-agent/README.md`）。

## API 速览

### Profile（火焰图）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/profiles/upload` | 上报折叠栈（JSON body: `service_name`, `node`, `sampled_at`, `duration_sec`, `folded_text`） |
| GET | `/api/profiles` | 列表（query: `service`, `node`, `from`, `to`, `limit`, `offset`） |
| GET | `/api/profiles/{id}` | 详情（含 folded_text） |
| GET | `/api/profiles/{id}/speedscope.json` | speedscope `sampled` 格式 JSON（带 CORS 头） |
| GET | `/api/profiles/{id}/folded.txt` | 原始折叠栈文本下载 |

### Trace（接口耗时）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/traces/batch` | 批量上报（NDJSON，每行一个 JSON 对象） |
| GET | `/api/traces` | 明细分页（query: `service`, `cmd`, `from`, `to`, `limit`） |
| GET | `/api/traces/stats` | 聚合统计（按 service+cmd 分组，返回 count/p50/p95/p99/avg/max） |
| GET | `/api/traces/timeseries` | 时间序列（query: `bucket_sec`，返回每桶 count/avg/p95） |

### NDJSON 上报格式

每行一个 JSON 对象：

```json
{"ts":1719600000,"service":"login","proto":"lua","cmd":"Login","session":12345,"cost_ms":12,"ok":true}
```

字段说明：
- `ts`：消息处理时间戳（unix 秒）
- `service`：snlua 服务名
- `proto`：协议名（如 `lua`）
- `cmd`：命令名（dispatch 标记，业务可通过 `firegraph.tag_cmd(cmd)` 设置）
- `session`：skynet session id（可空）
- `cost_ms`：处理耗时（毫秒）
- `ok`：是否成功（boolean）

## 折叠栈格式

`folded_text` 字段为标准 [Folded Stacks](https://github.com/brendangregg/FlameGraph#2-fold-stacks) 格式，每行一条调用栈：

```
main;skynet.dispatch;login_handler;check_token 50
main;skynet.dispatch;login_handler;db_query 150
main;skynet.dispatch;login_handler;db_query;parse_result 30
```

格式：`frame1;frame2;frame3 count`（栈底在前，空格分隔计数）。
兼容 FlameGraph.pl（`./flamegraph.pl out.folded > out.svg`）与 speedscope（后端自动转换）。

## 配置

`configs/firegraph.yaml`：

```yaml
server:
  addr: ":8080"        # HTTP 监听地址
  web_dir: "./web"     # 前端静态资源目录

store:
  dsn: "firegraph.db"  # SQLite 文件路径
  retention_days: 7    # 数据保留天数（0=永久）
```

Skynet 端配置通过 `skynet.getenv` 读取，详见 `skynet-agent/README.md`。

## 项目结构

```
firegraph/
├── cmd/firegraph/main.go          # 后端入口
├── internal/
│   ├── config/                    # 配置加载
│   ├── server/                    # HTTP 路由 + handler
│   ├── store/                     # SQLite 存储层
│   └── profile/                   # 折叠栈解析 + speedscope 转换
├── web/                           # 前端（原生 JS + SVG）
│   ├── index.html / profiles.html / traces.html
│   └── assets/app.js + app.css
├── skynet-agent/                  # Skynet 端 Lua 模块
│   └── lua/firegraph/             # init / sampler / tracer / reporter
├── scripts/                       # build.sh + fetch_assets.sh
└── configs/firegraph.yaml
```

## 技术选型

| 层 | 选型 | 理由 |
|---|---|---|
| 后端 | Go 1.22+ | 单二进制部署、与 skynet 生态一致 |
| 存储 | SQLite (`modernc.org/sqlite`，纯 Go) | 无 CGO 依赖、单文件、百万级数据足够 |
| 前端 | 原生 JS + SVG | 无构建链、内网加载快、零运行时依赖 |
| 火焰图 | speedscope 离线包 | 纯浏览器运行、三种视图、交互最佳 |
| 采样 | 内置 debug.sethook + 可选 swt | 开箱即用 + 可升级 |
| 埋点 | skynet.dispatch 包装 | 无侵入、覆盖所有消息 |

## 限制与已知问题

1. **内置采样器局限**：基于 `debug.sethook`，只能采样设置了 hook 的协程。对 CPU 密集型业务足够，跨协程采样需接入 swt。
2. **分位数内存计算**：`/api/traces/stats` 的 P50/P95/P99 在 Go 内存中计算（拉排序数组），数据量大时（单接口百万级）查询变慢，可后续优化为预聚合或 window function。
3. **无鉴权**：当前为内网部署设计，未实现鉴权。公网部署需自行加反向代理 + auth。
4. **swt 集成**：`swt_bridge.lua` 中的 swt 适配代码为示意，需根据 swt 实际 API 调整（见 `skynet-agent/README.md`）。

## 开发

```bash
# 构建
go build ./...

# 运行（热加载可配合 air）
go run ./cmd/firegraph -config configs/firegraph.yaml

# 测试 API（PowerShell）
Invoke-RestMethod http://localhost:8080/healthz
```

## License

MIT
