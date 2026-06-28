# Firegraph 全面使用教程

> Skynet 游戏服务器性能 & 接口耗时监测工具完整使用指南
> 适用版本：firegraph v1.x · Prometheus 3.x · Grafana 13.x
> 最后更新：2026-06-28

---

## 目录

- [第 1 章 工具概述](#第-1-章-工具概述)
- [第 2 章 安装与配置指南](#第-2-章-安装与配置指南)
- [第 3 章 基础操作流程](#第-3-章-基础操作流程)
- [第 4 章 功能模块详解](#第-4-章-功能模块详解)
- [第 5 章 图表与数据可视化说明](#第-5-章-图表与数据可视化说明)
- [第 6 章 指标体系解析](#第-6-章-指标体系解析)
- [第 7 章 高级功能与技巧](#第-7-章-高级功能与技巧)
- [第 8 章 常见问题解答](#第-8-章-常见问题解答)

---

## 第 1 章 工具概述

### 1.1 工具是什么

Firegraph 是一套面向 **Skynet + Lua** 游戏服务器的轻量级性能监测工具。它通过两个维度定位线上性能问题：

- **CPU 热点维度**：采样式 Lua 火焰图，找出哪段代码吃掉了 CPU
- **接口耗时维度**：dispatch 层无侵入埋点，找出哪个协议慢、何时抖动

数据经 Skynet agent 上报到 firegraph 后端（Go 编写，纯静态依赖），存入 SQLite，通过浏览器查看。并可对接 Prometheus + Grafana 做长期趋势监控与告警。

### 1.2 适用场景

| 场景 | 用到的能力 |
|------|-----------|
| 线上偶发卡顿，不知道卡在哪 | 火焰图采样，定位 CPU 热点函数 |
| 某个协议偶尔超时，复现困难 | 接口耗时分位数（P95/P99）+ 趋势图 |
| 版本上线后回归性能对比 | 耗时趋势按时间范围过滤，对比前后均值 |
| 慢调用明细排查 | 接口耗时下钻到单条 trace 明细 |
| 长期容量规划与告警 | Prometheus 抓取 + Grafana 仪表盘 |
| 多服务节点统一观测 | service / node 维度过滤 |

### 1.3 核心价值

- **低侵入**：Lua agent 通过 `debug.sethook` 采样 + 包装 `skynet.dispatch`，无需改业务代码
- **零外部依赖**：后端纯 Go（CGO-free SQLite），前端纯静态 HTML/JS，无 npm/webpack
- **开箱即用**：一个二进制 + 一个配置文件即可启动
- **可扩展**：标准 `/metrics` 端点，无缝接入现有 Prometheus 体系

### 1.4 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│  Skynet 游戏服务器（Lua）                                     │
│  ┌──────────────────┐   ┌──────────────────┐                │
│  │ firegraph.sampler│   │ firegraph.tracer │  ← 无侵入埋点   │
│  │ (debug.sethook)  │   │ (wrap dispatch)  │                │
│  └────────┬─────────┘   └────────┬─────────┘                │
│           │ folded stack          │ NDJSON trace              │
└───────────┼───────────────────────┼──────────────────────────┘
            │ HTTP POST             │ HTTP POST
            ▼                       ▼
┌─────────────────────────────────────────────────────────────┐
│  firegraph 后端（Go, :8080）                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────┐  │
│  │ /api/    │  │ /api/    │  │ /metrics │  │ 静态资源   │  │
│  │ profiles │  │ traces   │  │ (Prom)   │  │ (web UI)   │  │
│  └────┬─────┘  └────┬─────┘  └─────┬────┘  └────────────┘  │
│       └──────┬──────┘              │                        │
│              ▼                     │                        │
│         ┌─────────┐                │                        │
│         │ SQLite  │                │                        │
│         └─────────┘                │                        │
└────────────────────────────────────┼────────────────────────┘
                                     │ scrape /metrics (15s)
                                     ▼
                     ┌──────────────────────────┐
                     │  Prometheus (:9090)      │
                     │  时序存储 + PromQL        │
                     └─────────────┬────────────┘
                                   │ query
                                   ▼
                     ┌──────────────────────────┐
                     │  Grafana (:3000)         │
                     │  仪表盘可视化 + 告警       │
                     └──────────────────────────┘

  浏览器用户 ──► http://localhost:8080  （firegraph 自带 UI）
              ──► http://localhost:3000  （Grafana 仪表盘）
```

---

## 第 2 章 安装与配置指南

### 2.1 系统要求

| 组件 | 要求 |
|------|------|
| firegraph 后端 | Windows / Linux / macOS，Go 1.22+（或直接用预编译二进制） |
| Skynet agent | Skynet 运行环境（WSL 或 Linux），Lua 5.x |
| 浏览器 | Chrome / Edge / Firefox（现代浏览器） |
| Prometheus（可选） | 3.x，用于长期监控 |
| Grafana（可选） | 13.x，用于仪表盘 |
| 磁盘 | SQLite 按数据量增长，默认保留 7 天 |

### 2.2 后端安装（Windows 示例）

**方式 A：源码编译**

```powershell
cd D:\MyPoj\firegraph
go mod tidy
$env:CGO_ENABLED = "0"
go build -o bin\firegraph.exe .\cmd\firegraph
```

**方式 B：直接用已有二进制**

项目已编译产物位于 `bin\firegraph.exe`，跳过编译直接使用。

### 2.3 配置文件

配置文件 [configs/firegraph.yaml](file:///d:/MyPoj/firegraph/configs/firegraph.yaml)：

```yaml
# firegraph 后端配置
server:
  addr: ":8080"        # HTTP 监听地址
  web_dir: "./web"     # 前端静态资源目录

store:
  dsn: "firegraph.db"      # SQLite 数据库文件路径
  retention_days: 7        # 数据保留天数（0 = 永久保留）
```

| 字段 | 说明 | 示例 |
|------|------|------|
| `server.addr` | HTTP 监听地址端口 | `:8080`、`127.0.0.1:8080` |
| `server.web_dir` | 前端静态资源目录（相对启动目录） | `./web` |
| `store.dsn` | SQLite 数据库文件路径 | `firegraph.db`、`/data/fg.db` |
| `store.retention_days` | 数据保留天数，超过自动清理；0 表示永久 | `7`、`30`、`0` |

> **注意**：修改 `dsn` 前请先停止服务，避免 SQLite 文件锁冲突。

### 2.4 启动后端

```powershell
cd D:\MyPoj\firegraph
.\bin\firegraph.exe -config configs\firegraph.yaml
```

启动成功标志（日志输出）：

```
firegraph server listening on :8080
```

验证：浏览器访问 http://localhost:8080/healthz，返回 `ok` 即正常。

### 2.5 Skynet Agent 配置

在 Skynet 配置中加载 firegraph agent（参考 [examples/config.firegraph](file:///d:/MyPoj/myskynet/examples/config.firegraph)）：

```lua
-- Skynet config
firegraph_host = "127.0.0.1"      -- firegraph 后端地址
firegraph_port = 8080
firegraph_service_name = "gamesrv" -- 当前服务名（用于维度过滤）
firegraph_service_node = "node1"   -- 节点标识（可选）

-- 预加载 agent
preload = "./skynet-agent/lua/firegraph/init.lua"
```

在业务入口调用安装（一次性）：

```lua
local firegraph = require "firegraph"
-- 安装接口耗时埋点（包装 skynet.dispatch）
firegraph.install_tracer()
-- 安装 CPU 采样器（按需触发）
firegraph.install_sampler()
```

### 2.6 Prometheus 配置（可选）

配置文件 [configs/prometheus.yml](file:///d:/MyPoj/firegraph/configs/prometheus.yml)：

```yaml
global:
  scrape_interval: 15s       # 每 15 秒抓取一次
  evaluation_interval: 15s

scrape_configs:
  - job_name: firegraph
    static_configs:
      - targets: ["localhost:8080"]  # firegraph 后端地址
```

启动：

```powershell
D:\MyPoj\prometheus-3.13.0-rc.1.windows-amd64\prometheus.exe `
  --config.file=d:\MyPoj\firegraph\configs\prometheus.yml `
  --storage.tsdb.path=D:\MyPoj\prometheus-3.13.0-rc.1.windows-amd64\data `
  --web.listen-address=:9090
```

### 2.7 Grafana 配置（可选）

Grafana 通过 **provisioning** 自动加载数据源和仪表盘，无需手动操作。配置文件位于：

- 数据源：`grafana/conf/provisioning/datasources/prometheus.yml`
- 仪表盘：`grafana/conf/provisioning/dashboards/firegraph.yml` + `dashboards/json/firegraph-overview.json`

启动：

```powershell
cd D:\MyPoj\grafana\grafana-13.1.0
.\bin\grafana.exe server --homepath=.
```

默认账号 `admin` / `admin`，默认端口 3000。

---

## 第 3 章 基础操作流程

### 3.1 启动顺序

完整启动一条链（从数据源到展示）：

```
1. 启动 firegraph 后端      → :8080
2. 启动 Skynet（带 agent）   → 上报数据
3. （可选）启动 Prometheus   → :9090
4. （可选）启动 Grafana      → :3000
```

**一键启动**（已配置守护脚本）：

```powershell
powershell -ExecutionPolicy Bypass -File d:\MyPoj\firegraph\scripts\start_all.ps1
```

该脚本会后台启动 firegraph 守护进程、skynet 守护进程、monitor 监控，全部带自动重启。

### 3.2 访问入口

| 地址 | 用途 |
|------|------|
| http://localhost:8080/ | firegraph 首页 |
| http://localhost:8080/profiles.html | 火焰图列表 |
| http://localhost:8080/traces.html | 接口耗时面板 |
| http://localhost:8080/healthz | 后端健康检查 |
| http://localhost:8080/metrics | Prometheus 指标端点 |
| http://localhost:9090 | Prometheus 查询界面 |
| http://localhost:9090/targets | 抓取目标状态 |
| http://localhost:3000 | Grafana 首页 |
| http://localhost:3000/d/firegraph-overview/firegraph-overview | firegraph 仪表盘 |

### 3.3 首页界面说明

访问 http://localhost:8080/ 看到首页：

```
┌──────────────────────────────────────────────────────┐
│  Firegraph        [首页] [火焰图] [接口耗时]          │  ← 顶部导航
├──────────────────────────────────────────────────────┤
│                                                       │
│   Skynet 游戏服务器性能 & 接口耗时监测                 │  ← 标题区
│   采样式 Lua 火焰图 + dispatch 层无侵入接口埋点        │
│                                                       │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐           │
│   │   🔥     │  │   ⏱️     │  │   ❤️     │           │
│   │ CPU 火焰图│  │ 接口耗时 │  │ 健康检查 │           │  ← 功能卡片
│   │          │  │          │  │          │           │
│   └──────────┘  └──────────┘  └──────────┘           │
└──────────────────────────────────────────────────────┘
```

- **顶部导航栏**：三个页面入口 + 品牌名
- **功能卡片**：点击任意卡片进入对应功能
- **页脚**：开源组件链接（speedscope / swt）

### 3.4 完成第一次任务：查看接口耗时

1. 确保 Skynet 已运行并上报数据（或运行测试数据生成器 `scripts\gen_metrics.ps1`）
2. 浏览器打开 http://localhost:8080/traces.html
3. 顶部工具栏选择时间范围（默认 1h），点 **查询**
4. 查看下方 5 个统计卡片（总调用 / 平均耗时 / P95 / P99 / 慢调用）
5. 查看耗时趋势图（Avg / P95 / P99 三条曲线）
6. 查看统计表格，定位 P95 最高的 cmd
7. 点击该行，展开明细列表查看单条慢调用

### 3.5 完成第二次任务：查看火焰图

1. 浏览器打开 http://localhost:8080/profiles.html
2. （可选）在 service / node 输入框过滤
3. 点 **查询** 刷新列表
4. 找到目标 profile 行，点 **查看** 按钮
5. 浏览器新标签页打开 speedscope 交互式火焰图
6. 在 speedscope 中：
   - 顶部切换 **Time Order** / **Left Heavy** / **Sandwich** 视图
   - 点击任意函数块，查看其耗时占比
   - 用键盘 ← → 翻页采样帧

---

## 第 4 章 功能模块详解

### 4.1 模块一：CPU 火焰图

**功能用途**：找出 CPU 时间被哪些函数消耗，定位热点代码。

**操作方法**：

1. 进入 http://localhost:8080/profiles.html
2. 工具栏说明：

   | 元素 | 作用 |
   |------|------|
   | `service` 输入框 | 按服务名过滤，如 `gamesrv` |
   | `node` 输入框 | 按节点过滤，如 `node1` |
   | 查询按钮 | 按条件刷新列表 |
   | 刷新按钮 | 不带条件重新拉取 |

3. 列表表格列说明：

   | 列名 | 含义 |
   |------|------|
   | ID | profile 自增主键 |
   | service | 上报的服务名 |
   | node | 上报的节点标识 |
   | 采样时间 | 采样发生的时间戳 |
   | 时长 | 本次采样持续秒数 |
   | 采样数 | 抓取到的栈样本总数 |
   | 操作 | 「查看」打开火焰图，「下载」获取原始 folded 栈 |

4. 点 **查看** 在新标签打开 speedscope

**界面布局**：

```
┌─────────────────────────────────────────────────────────┐
│  [首页] [火焰图] [接口耗时]                              │
├─────────────────────────────────────────────────────────┤
│ service[___] node[___]  [查询] [刷新]                   │
├─────────────────────────────────────────────────────────┤
│ ID │ service │ node │ 采样时间    │ 时长 │ 采样数 │ 操作│
│ 1  │ gamesrv │node1│ 05:00:00    │ 8s   │ 968    │ 查看│
│ 2  │ battlesrv│node1│ 05:05:00   │ 8s   │ 1024   │ 查看│
└─────────────────────────────────────────────────────────┘
```

**注意事项**：
- 采样会带来约 1-3% 的额外 CPU 开销，建议按需触发而非常开
- 单次采样时长建议 5-30 秒，过短样本不足，过长影响性能
- 若提示「未检测到 speedscope 离线包」，会自动回退到在线版 speedscope.app

### 4.2 模块二：接口耗时

**功能用途**：监控各协议接口的延迟分布与趋势，定位慢接口和抖动。

**操作方法**：

1. 进入 http://localhost:8080/traces.html
2. 工具栏：

   | 元素 | 作用 |
   |------|------|
   | `service` 输入框 | 按服务名过滤 |
   | `cmd` 输入框 | 按协议命令过滤，如 `Login` |
   | 时间范围按钮 | 1h / 6h / 24h / 7d 四档快捷切换 |
   | 查询按钮 | 按条件刷新所有数据 |

3. 统计卡片区（5 个指标）：

   | 卡片 | 含义 |
   |------|------|
   | 总调用 | 选定范围内 trace 总数 |
   | 平均耗时 | 所有 trace 的算术平均（ms） |
   | P95 | 95 分位延迟（ms） |
   | P99 | 99 分位延迟（ms） |
   | 慢调用(>200ms) | 超过 200ms 的调用次数 |

4. 耗时趋势图：三条曲线分别为 Avg（蓝）/ P95（红）/ P99（紫）
5. 统计表格：按 service × cmd 聚合，列含 调用数 / P50 / P95 / P99 / avg / max
6. 点击表格任意行，下方展开该 service+cmd 的明细列表（单条 trace）

**界面布局**：

```
┌────────────────────────────────────────────────────────────┐
│ service[__] cmd[__]  [1h][6h][24h][7d]  [查询]            │
├────────────────────────────────────────────────────────────┤
│ ┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐                  │
│ │总调用││平均  ││ P95 ││ P99 ││慢调用│  ← 统计卡片         │
│ │ 1240 ││ 85ms ││210ms││450ms││ 38  │                     │
│ └──────┘└──────┘└──────┘└──────┘└──────┘                  │
├────────────────────────────────────────────────────────────┤
│ 耗时趋势（Avg / P95 / P99，单位 ms）                       │
│ ╭──────────────────────────────────────────╮               │
│ │      ╱╲     ╱╲       P99 ── P95 ── Avg  │               │
│ │  ╱╲╱  ╲___╱   ╲___                        │              │
│ ╰──────────────────────────────────────────╯               │
├────────────────────────────────────────────────────────────┤
│ service│ cmd    │调用数│ P50│ P95│ P99│avg│max│操作        │
│ gamesrv│ Login  │ 320 │ 45 │120 │350 │ 68│450│▼            │
│ battlesrv│Attack│ 280 │ 60 │180 │520 │ 95│680│▼            │
└────────────────────────────────────────────────────────────┘
```

**注意事项**：
- 分位数（P50/P95/P99）基于选定范围内的全部 trace 计算，范围越大越平滑
- 慢调用阈值固定为 200ms，如需自定义可在前端代码修改
- 明细列表默认显示最近 100 条，可在 URL 加 `?limit=500` 扩大

### 4.3 模块三：Prometheus 指标端点

**功能用途**：暴露标准 `/metrics` 端点供 Prometheus 抓取，实现长期存储与告警。

**访问方式**：直接 GET http://localhost:8080/metrics

**返回内容**（Prometheus 文本格式，节选）：

```
# HELP firegraph_trace_count_total Total traces received, partitioned by cmd/service/ok
# TYPE firegraph_trace_count_total counter
firegraph_trace_count_total{cmd="Login",ok="true",service="gamesrv"} 320
firegraph_trace_count_total{cmd="Login",ok="false",service="gamesrv"} 12

# HELP firegraph_trace_latency_ms Trace latency in milliseconds
# TYPE firegraph_trace_latency_ms histogram
firegraph_trace_latency_ms_bucket{cmd="Login",le="10"} 45
firegraph_trace_latency_ms_bucket{cmd="Login",le="50"} 180
firegraph_trace_latency_ms_bucket{cmd="Login",le="100"} 250
firegraph_trace_latency_ms_bucket{cmd="Login",le="+Inf"} 332
firegraph_trace_latency_ms_sum{cmd="Login"} 22480
firegraph_trace_latency_ms_count{cmd="Login"} 332
```

**注意**：该端点无需认证，建议仅在内网开放。

### 4.4 模块四：Grafana 仪表盘

**功能用途**：在 Grafana 中查看长期趋势、设置告警、共享给团队。

**预置仪表盘**：`firegraph overview`（UID: `firegraph-overview`），含 7 个面板（详见第 5 章）。

**操作方法**：
1. 访问 http://localhost:3000/d/firegraph-overview/firegraph-overview
2. 顶部时间选择器调整时间范围（如 last 1h / 6h / 24h）
3. 右上角刷新按钮可手动刷新，或设置自动刷新间隔（推荐 15s）
4. 点击面板标题可展开 → 编辑，修改 PromQL 查询

### 4.5 模块五：守护进程与监控

**功能用途**：保证服务后台持续运行，异常退出自动重启，并实时监控数据变化。

**脚本清单**（位于 `scripts/`）：

| 脚本 | 作用 |
|------|------|
| `daemon_firegraph.ps1` | firegraph 后台守护 + 自动重启 |
| `daemon_skynet.sh` | skynet 后台守护 + 自动重启（WSL） |
| `monitor.ps1` | 实时监控：健康检查 + trace/profile 增量 + 慢接口告警 |
| `start_all.ps1` | 一键启动全部守护进程 + 监控 |
| `stop_all.ps1` | 一键停止全部 |
| `gen_metrics.ps1` | 持续生成测试数据（演示用） |

**监控日志**（`logs/monitor.log`）示例：

```
[2026-06-28 05:10:00] [OK] ===== monitor started (interval 8s) =====
[2026-06-28 05:10:08] [OK] trace +24 (1240 -> 1264)
[2026-06-28 05:10:16] [WARN] slow cmd: Attack P95=520ms (>=500ms)
[2026-06-28 05:10:24] [ERROR] backend DOWN
```

---

## 第 5 章 图表与数据可视化说明

### 5.1 火焰图（speedscope）

**类型**：交互式火焰图，由 [speedscope](https://www.speedscope.app/) 渲染。

**数据来源**：firegraph agent 通过 `debug.sethook` 在 Skynet Lua 协程执行时按间隔采样调用栈，聚合为 folded stack 格式上报，后端转换为 speedscope JSON 格式。

**三种视图**：

| 视图 | 展示方式 | 适用场景 |
|------|---------|---------|
| **Time Order**（时间顺序） | 横轴为时间，每列是一帧采样，从下往上叠函数栈 | 看热点何时出现，定位突发性能抖动 |
| **Left Heavy**（左重） | 按总耗时排序，最宽的块在最左 | 快速找最耗时的函数（最常用） |
| **Sandwich**（三明治） | 列出每个函数的总/自身耗时，点选查看其调用栈上下文 | 分析某函数被谁调用、又调用了谁 |

**解读方法**：
- **宽度** = 函数占用 CPU 时间比例（越宽越热）
- **颜色** = 按函数模块随机着色，仅作区分
- **自身耗时（Self Time）** = 该函数耗时减去子函数耗时，反映函数本身开销
- **总耗时（Total Time）** = 含所有子函数调用的耗时

**操作技巧**：
- 鼠标悬停函数块 → 显示函数名 + 耗时 + 占比
- 单击函数块 → 放大到该函数
- 顶部搜索框输入函数名 → 高亮所有匹配
- 键盘 `←` `→` → 在采样帧间导航

### 5.2 耗时趋势图

**类型**：多线折线图（firegraph 自带 UI）。

**数据来源**：后端 `/api/traces/timeseries` 接口，按时间桶（默认 60 秒）聚合 trace 的 Avg/P95/P99。

**三条曲线**：

| 曲线 | 颜色 | 含义 |
|------|------|------|
| Avg | 蓝色 (#2563eb) | 每个时间桶内的平均耗时 |
| P95 | 红色 (#dc2626) | 每个时间桶内的 95 分位耗时 |
| P99 | 紫色 (#9333ea) | 每个时间桶内的 99 分位耗时 |

**解读方法**：
- 三条曲线接近 = 延迟稳定
- P99 远高于 Avg = 存在长尾延迟（少量请求很慢）
- 曲线突然尖峰 = 某时刻发生抖动（GC / 资源争抢 / 流量突增）
- P95 持续上升 = 性能在逐渐劣化（内存泄漏 / 数据量增长）

### 5.3 Grafana 仪表盘面板

预置 `firegraph overview` 仪表盘包含 7 个面板：

| 面板 | 类型 | PromQL | 解读 |
|------|------|--------|------|
| QPS by cmd | 时序折线 | `sum(rate(firegraph_trace_count_total[1m])) by (cmd)` | 各接口实时吞吐，看流量分布 |
| P95 latency by cmd | 时序折线 | `histogram_quantile(0.95, sum(rate(..._bucket[5m])) by (cmd, le))` | 95% 请求的延迟上限 |
| P99 latency by cmd | 时序折线 | `histogram_quantile(0.99, ...)` | 99% 请求的延迟上限，更敏感于长尾 |
| Error ratio by cmd | 时序折线 | `sum(rate(...{ok="false"}[5m])) / sum(rate(...))` | 失败率，超 5% 告警 |
| Profile upload rate | 单值 | `sum(rate(firegraph_profile_count_total[1m])) * 60` | 每分钟 profile 上报数 |
| Total traces received | 单值 | `sum(firegraph_trace_count_total)` | 累计 trace 总数 |
| Avg profile samples | 时序折线 | `rate(_sum[5m]) / rate(_count[5m])` | 单 profile 平均采样点数 |

**阈值配色**（P95 面板）：

| 颜色 | 区间 | 含义 |
|------|------|------|
| 绿色 | < 200ms | 健康 |
| 黄色 | 200-500ms | 关注 |
| 橙色 | 500-1000ms | 偏慢 |
| 红色 | > 1000ms | 告警 |

### 5.4 统计表格

**类型**：聚合数据表（firegraph UI）。

**数据来源**：后端 `/api/traces/stats` 接口，按 service × cmd 分组聚合。

**列含义**：

| 列 | 计算 |
|----|------|
| 调用数 | 该分组 trace 总数 |
| P50 | 50 分位（中位数），典型耗时 |
| P95 | 95 分位，多数用户体验上限 |
| P99 | 99 分位，长尾用户耗时 |
| avg | 算术平均 |
| max | 最大单次耗时 |

**解读**：按 P95 降序排列，优先优化排在前面的接口。

---

## 第 6 章 指标体系解析

### 6.1 业务指标（firegraph UI）

| 指标 | 定义 | 计算方式 | 正常范围 | 业务含义 |
|------|------|---------|---------|---------|
| 总调用数 | 选定范围内 trace 总量 | `COUNT(*)` | 视业务而定 | 流量基线，突变表示异常 |
| 平均耗时 Avg | 所有 trace 耗时算术平均 | `SUM(cost_ms)/COUNT` | < 100ms | 整体性能水平（易被长尾拉高） |
| P50（中位数） | 50% 请求低于此值 | 排序后第 50 百分位 | < 50ms | 典型用户体验 |
| P95 | 95% 请求低于此值 | 排序后第 95 百分位 | < 200ms | 多数用户可接受的延迟上限 |
| P99 | 99% 请求低于此值 | 排序后第 99 百分位 | < 500ms | 长尾用户，敏感于抖动 |
| max | 最大单次耗时 | `MAX(cost_ms)` | < 2000ms | 极端情况，用于排查偶发卡顿 |
| 慢调用数 | 超过 200ms 的调用次数 | `COUNT(cost_ms > 200)` | < 5% 总量 | 慢请求规模 |
| 成功率 | 成功 trace 占比 | `ok=true / total` | > 95% | 业务健康度 |
| 采样数（profile） | 单次 profile 抓取的栈样本数 | 采样器统计 | 视时长 | 样本越多，火焰图越精确 |

### 6.2 Prometheus 指标

| 指标名 | 类型 | 标签 | 含义 |
|--------|------|------|------|
| `firegraph_trace_count_total` | Counter | cmd, service, ok | 累计接收 trace 数（单调递增） |
| `firegraph_trace_latency_ms` | Histogram | cmd | trace 延迟分布（毫秒桶） |
| `firegraph_profile_count_total` | Counter | service | 累计接收 profile 数 |
| `firegraph_profile_samples` | Histogram | service | 单 profile 采样点数分布 |

**Histogram 桶说明**（`firegraph_trace_latency_ms`）：

延迟桶边界（毫秒）：`10, 25, 50, 100, 200, 300, 500, 1000, 2000, 5000, 10000, +Inf`

每个桶是一个 Counter，值为「延迟 ≤ 该边界的 trace 累计数」。配合 `_sum`（耗时总和）和 `_count`（总样本数）可计算任意分位数。

### 6.3 关键 PromQL 查询速查

| 需求 | PromQL |
|------|--------|
| 实时 QPS | `sum(rate(firegraph_trace_count_total[1m])) by (cmd)` |
| P95 延迟 | `histogram_quantile(0.95, sum(rate(firegraph_trace_latency_ms_bucket[5m])) by (cmd, le))` |
| P99 延迟 | `histogram_quantile(0.99, sum(rate(firegraph_trace_latency_ms_bucket[5m])) by (cmd, le))` |
| 平均延迟 | `rate(firegraph_trace_latency_ms_sum[5m]) / rate(firegraph_trace_latency_ms_count[5m])` |
| 失败率 | `sum(rate(firegraph_trace_count_total{ok="false"}[5m])) by (cmd) / sum(rate(firegraph_trace_count_total[5m])) by (cmd)` |
| 错误 QPS | `sum(rate(firegraph_trace_count_total{ok="false"}[1m])) by (cmd)` |
| profile 上报速率/分钟 | `sum(rate(firegraph_profile_count_total[1m])) * 60` |

### 6.4 告警阈值建议

| 指标 | 告警阈值 | 级别 |
|------|---------|------|
| P95 延迟 | > 500ms 持续 5 分钟 | Warning |
| P95 延迟 | > 1000ms 持续 2 分钟 | Critical |
| P99 延迟 | > 2000ms 持续 5 分钟 | Warning |
| 失败率 | > 5% 持续 3 分钟 | Warning |
| 失败率 | > 10% 持续 1 分钟 | Critical |
| QPS 突降 | 较 1 小时前下降 50% | Warning |
| firegraph target down | 持续 1 分钟 | Critical |

---

## 第 7 章 高级功能与技巧

### 7.1 自定义时间桶粒度

接口耗时趋势图默认 60 秒一桶。查询时加 `bucket_sec` 参数调整：

```
GET /api/traces/timeseries?bucket_sec=10    # 10 秒粒度（看突发）
GET /api/traces/timeseries?bucket_sec=300   # 5 分钟粒度（看长趋势）
```

### 7.2 下载原始 folded 栈

在火焰图列表点「下载」或直接请求：

```
GET /api/profiles/{id}/folded.txt
```

得到 Breanda Gregg 格式的折叠栈文本，可喂给 FlameGraph.pl 离线生成 SVG：

```bash
perl flamegraph.pl profile.folded > profile.svg
```

### 7.3 批量上报 NDJSON 格式

trace 批量上报接口接受 NDJSON（每行一个 JSON）：

```
POST /api/traces/batch
Content-Type: text/plain

{"cmd":"Login","service":"gamesrv","cost_ms":45,"ok":true,"ts":1782594370}
{"cmd":"Attack","service":"battlesrv","cost_ms":120,"ok":true,"ts":1782594370}
{"cmd":"Query","service":"dbsrv","cost_ms":85,"ok":false,"ts":1782594370}
```

字段说明：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| cmd | string | 是 | 协议命令名 |
| service | string | 是 | 服务名 |
| cost_ms | int | 是 | 耗时毫秒 |
| ok | bool | 是 | 是否成功 |
| ts | int | 否 | unix 秒，缺省用服务端时间 |
| session | string | 否 | 会话标识（明细展示用） |

### 7.4 Grafana 仪表盘编辑

预置仪表盘支持在线编辑：

1. 打开仪表盘 → 顶部点 **Edit**（铅笔图标）
2. 修改面板的 PromQL 查询
3. 调整阈值、单位、颜色
4. 点 **Save**（已配置 `allowUiUpdates: true`，更改会写回 JSON 文件）

### 7.5 多服务节点统一观测

Skynet agent 配置不同 `firegraph_service_name` 和 `firegraph_service_node`，所有节点上报到同一个 firegraph 后端。在 UI 或 PromQL 中按 `service` / `node` 维度过滤：

```
# 只看 battlesrv 的 P95
histogram_quantile(0.95, sum(rate(firegraph_trace_latency_ms_bucket{cmd="Attack"}[5m])) by (le))
```

### 7.6 数据保留与清理

配置 `store.retention_days` 自动清理过期数据。手动清理：

```powershell
# 停止服务后删除数据库文件
Stop-Process -Name firegraph -Force
Remove-Item d:\MyPoj\firegraph\firegraph.db -Force
# 重启会自动创建空库
```

### 7.7 实用快捷键

**speedscope 火焰图**：
- `←` / `→`：前后切换采样帧
- `ESC`：退出放大视图
- `Ctrl+F`：聚焦搜索框

**Grafana**：
- `Ctrl+S`：保存仪表盘
- `Ctrl+Z`：撤销
- `D`：切换深色/浅色主题
- `T`：进入时间选择器
- `R`：刷新

### 7.8 后台守护与开机自启

守护脚本已实现「异常退出 3 秒内自动重启」。如需开机自启，创建 Windows 任务计划：

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-ExecutionPolicy Bypass -File d:\MyPoj\firegraph\scripts\start_all.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "firegraph-autostart" -Action $action -Trigger $trigger -RunLevel Highest
```

---

## 第 8 章 常见问题解答

### 8.1 启动问题

**Q1：启动后端报 `bind: address already in use`？**

8080 端口被占用。查找并结束占用进程：

```powershell
Get-NetTCPConnection -LocalPort 8080 | Select-Object OwningProcess
Stop-Process -Id <PID> -Force
```

或修改 `firegraph.yaml` 的 `server.addr` 换端口。

**Q2：访问 http://localhost:8080 显示 404？**

确认 `server.web_dir` 指向正确的 web 目录（相对启动时的 cwd）。从项目根目录启动时用 `./web`。

**Q3：`go build` 报 `undefined: metrics`？**

通常是某处调用了 `metrics.RecordXxx` 但没 import `metrics` 包。检查 `internal/server/trace_handler.go` 和 `profile_handler.go` 的 import 块是否含 `github.com/firegraph/firegraph/internal/metrics`。

### 8.2 数据问题

**Q4：traces.html 一直显示「加载中...」？**

1. 检查后端日志是否有报错
2. 确认有数据：`Invoke-WebRequest http://localhost:8080/api/traces/stats`
3. 检查时间范围：默认查最近 1h，若无数据可改 24h 或 7d

**Q5：火焰图列表为空？**

确认 Skynet agent 已触发采样上报。手动测试上报：

```powershell
$body = '{"service_name":"test","node":"n1","duration_sec":5,"folded_text":"main;work 100"}'
Invoke-WebRequest -Uri http://127.0.0.1:8080/api/profiles/upload -Method POST -Body $body -ContentType "application/json"
```

**Q6：Prometheus targets 显示 firegraph 为 DOWN？**

1. 确认 firegraph 后端在运行：`Invoke-WebRequest http://localhost:8080/-/healthy`
2. 确认 `/metrics` 可访问：`Invoke-WebRequest http://localhost:8080/metrics`
3. 检查 `prometheus.yml` 中 `targets` 地址是否正确
4. Prometheus 修改配置后需 reload：`POST http://localhost:9090/-/reload`（需 `--web.enable-lifecycle`）

**Q7：Grafana 仪表盘面板显示「No data」？**

1. 确认数据源已配置：http://localhost:3000/connections/datasources
2. 点数据源 → **Save & Test**，确认「Data source is working」
3. 确认时间范围有数据：在 Prometheus 执行 `firegraph_trace_count_total`
4. 检查 PromQL 拼写，注意 `ok="false"` 是字符串

### 8.3 性能问题

**Q8：采样后游戏卡顿？**

采样开销约 1-3% CPU。建议：
- 单次采样不超过 30 秒
- 避开高峰期采样
- 用 `firegraph.install_sampler()` 按需触发，而非常开

**Q9：SQLite 数据库文件越来越大？**

配置 `retention_days` 自动清理。或定期归档：

```powershell
# 停服后用 VACUUM 压缩
sqlite3 firegraph.db "VACUUM;"
```

**Q10：Prometheus 占用磁盘过大？**

TSDB 默认保留 15 天。启动时加参数缩短：

```
--storage.tsdb.retention.time=7d
```

### 8.4 部署问题

**Q11：WSL 里的 Skynet 上报到 Windows 的 firegraph 报连接失败？**

WSL2 默认可与 Windows 互访 localhost。若不通：
- 确认 WSL2 版本（`wsl --version`）
- 用 Windows 实际 IP 替代 `127.0.0.1`：`ipconfig` 查 vEthernet (WSL) 适配器 IP
- 或在 firegraph 配置 `addr: ":8080"` 监听全部接口

**Q12：守护进程日志在哪？**

| 日志 | 路径 | 内容 |
|------|------|------|
| 后端日志 | `logs/firegraph.log` | firegraph stdout |
| 后端错误 | `logs/firegraph.err` | firegraph stderr |
| skynet 日志 | `logs/skynet.log` | skynet 运行输出 |
| 守护日志 | `logs/daemon.log` | daemon 重启记录 |
| 监控日志 | `logs/monitor.log` | 实时监控数据 |
| Prometheus | `logs/prometheus.out` | prometheus 输出 |
| Grafana | `logs/grafana.out` / `grafana.err` | grafana 输出 |

**Q13：如何彻底停止所有服务？**

```powershell
powershell -ExecutionPolicy Bypass -File d:\MyPoj\firegraph\scripts\stop_all.ps1
# 再手动停 Prometheus 和 Grafana
Stop-Process -Id (Get-Content d:\MyPoj\firegraph\logs\prometheus.pid) -Force
Stop-Process -Id (Get-Content d:\MyPoj\firegraph\logs\grafana.pid) -Force
Stop-Process -Id (Get-Content d:\MyPoj\firegraph\logs\gen_metrics.pid) -Force
```

**Q14：speedscope 提示「未检测到离线包」？**

会自动回退到在线版 https://www.speedscope.app/。如需离线使用，下载 speedscope release 解压到 `web/assets/vendor/speedscope/`。

**Q15：仪表盘 PromQL 里 `service` 标签查不到业务服务名？**

因 Prometheus 抓取配置加了静态标签 `service="firegraph"`，原始的 service 标签被重命名为 `exported_service`。按业务服务过滤用：

```
firegraph_trace_count_total{exported_service="gamesrv"}
```

或修改 `prometheus.yml` 去掉 `labels` 配置即可保留原始 service 标签。

---

## 附录：快速参考卡

### 服务地址速查

| 服务 | 地址 | 凭证 |
|------|------|------|
| firegraph UI | http://localhost:8080 | 无 |
| firegraph API | http://localhost:8080/api/* | 无 |
| firegraph 指标 | http://localhost:8080/metrics | 无 |
| Prometheus | http://localhost:9090 | 无 |
| Grafana | http://localhost:3000 | admin / admin |

### 关键文件速查

| 文件 | 用途 |
|------|------|
| [cmd/firegraph/main.go](file:///d:/MyPoj/firegraph/cmd/firegraph/main.go) | 后端入口 |
| [configs/firegraph.yaml](file:///d:/MyPoj/firegraph/configs/firegraph.yaml) | 后端配置 |
| [configs/prometheus.yml](file:///d:/MyPoj/firegraph/configs/prometheus.yml) | Prometheus 抓取配置 |
| [internal/metrics/metrics.go](file:///d:/MyPoj/firegraph/internal/metrics/metrics.go) | Prometheus 指标定义 |
| [internal/server/server.go](file:///d:/MyPoj/firegraph/internal/server/server.go) | HTTP 路由注册 |
| [skynet-agent/lua/firegraph/init.lua](file:///d:/MyPoj/firegraph/skynet-agent/lua/firegraph/init.lua) | Lua agent 入口 |
| [scripts/start_all.ps1](file:///d:/MyPoj/firegraph/scripts/start_all.ps1) | 一键启动 |
| [scripts/stop_all.ps1](file:///d:/MyPoj/firegraph/scripts/stop_all.ps1) | 一键停止 |

### 常用命令速查

```powershell
# 启动全部
powershell -ExecutionPolicy Bypass -File d:\MyPoj\firegraph\scripts\start_all.ps1

# 停止全部
powershell -ExecutionPolicy Bypass -File d:\MyPoj\firegraph\scripts\stop_all.ps1

# 查看后端健康
Invoke-WebRequest http://localhost:8080/healthz

# 查看抓取状态
Invoke-WebRequest http://localhost:9090/api/v1/targets | ConvertFrom-Json

# 查看实时监控日志
Get-Content d:\MyPoj\firegraph\logs\monitor.log -Tail 20 -Wait

# 重新编译后端
cd d:\MyPoj\firegraph; go build -o bin\firegraph.exe .\cmd\firegraph

# 生成测试数据
powershell -ExecutionPolicy Bypass -File d:\MyPoj\firegraph\scripts\gen_metrics.ps1
```

---

*本教程覆盖 firegraph 工具从安装、配置、使用到进阶的完整内容。如需了解更多实现细节，请参阅 [docs/03-CODE_DESIGN.md](file:///d:/MyPoj/firegraph/docs/03-CODE_DESIGN.md) 代码设计文档。*
