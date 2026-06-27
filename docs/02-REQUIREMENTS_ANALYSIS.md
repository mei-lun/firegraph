# firegraph 需求分析文档

| 项 | 内容 |
|---|---|
| 文档版本 | v1.0 |
| 上游输入 | [需求文档（PRD）](./01-REQUIREMENTS.md) |
| 下游产物 | [代码设计文档](./03-CODE_DESIGN.md) |
| 创建日期 | 2026-06-28 |
| 文档状态 | 已评审 |
| 分析方法 | MoSCoW 优先级 + 模块化分解 + 流程梳理 + 可行性评估 |
| 目标读者 | 研发负责人 / 架构师 / AI 辅助开发工具 |

---

## 目录

1. [需求分析概述](#1-需求分析概述)
2. [需求优先级排序](#2-需求优先级排序)
3. [功能模块划分](#3-功能模块划分)
4. [业务流程梳理](#4-业务流程梳理)
5. [需求依赖关系](#5-需求依赖关系)
6. [需求可实现性评估](#6-需求可实现性评估)
7. [风险分析与应对](#7-风险分析与应对)
8. [里程碑与实施建议](#8-里程碑与实施建议)
9. [附录：需求追溯矩阵](#9-附录需求追溯矩阵)

---

## 1. 需求分析概述

### 1.1 分析目标

基于 [PRD](./01-REQUIREMENTS.md) 中明确的 27 项功能需求（FR）与 19 项非功能需求（NFR），完成：

1. **优先级排序**：用 MoSCoW + P0/P1/P2 分级，明确 MVP 边界。
2. **模块划分**：将需求按职责聚合为可独立交付的模块。
3. **业务流程梳理**：用流程图描述关键链路，识别跨模块协作点。
4. **可实现性评估**：技术可行性、资源估算、风险识别。
5. **里程碑建议**：分阶段交付计划。

### 1.2 分析原则

- **MVP 优先**：优先保障端到端可用，非核心功能后置。
- **解耦设计**：模块间通过 HTTP/JSON 契约通信，便于独立开发。
- **风险前置**：技术风险高的需求（swt 适配）放在后期或可选。
- **可验证性**：每条需求都需对应可执行的验收用例。

---

## 2. 需求优先级排序

### 2.1 优先级定义

| 级别 | 含义 | Must / Should / Could / Won't |
|---|---|---|
| **P0** | 必须实现，MVP 不可上线缺漏 | Must have |
| **P1** | 应该实现，显著提升体验但不阻塞 MVP | Should have |
| **P2** | 可以实现，增强项，可延后到 v1.x | Could have |
| **P3** | 暂不实现，明确推后到 v2+ | Won't have (this time) |

### 2.2 功能需求优先级矩阵

| 需求 ID | 需求名称 | 优先级 | 价值 | 复杂度 | 模块 | MoSCoW |
|---|---|---|---|---|---|---|
| FR-P-01 | 运行时采样启停 | **P0** | 高 | 中 | Skynet 采样器 | Must |
| FR-P-02 | 自动周期采样 | P1 | 中 | 低 | Skynet 采样器 | Should |
| FR-P-03 | 折叠栈生成 | **P0** | 高 | 低 | Skynet 采样器 | Must |
| FR-P-04 | HTTP 上报 | **P0** | 高 | 中 | Skynet reporter | Must |
| FR-P-05 | 后端存储 | **P0** | 高 | 低 | 后端 store | Must |
| FR-P-06 | Profile 列表查询 | **P0** | 高 | 低 | 后端 server | Must |
| FR-P-07 | speedscope JSON 转换 | **P0** | 高 | 中 | 后端 profile | Must |
| FR-P-08 | speedscope 嵌入查看 | **P0** | 高 | 低 | 前端 | Must |
| FR-P-09 | 折叠栈原文下载 | P1 | 中 | 低 | 后端 server | Should |
| FR-P-10 | swt 适配器 | P2 | 中 | 高 | Skynet 采样器 | Could |
| FR-T-01 | 无侵入埋点 | **P0** | 高 | 中 | Skynet tracer | Must |
| FR-T-02 | 命令名标记 | **P0** | 高 | 低 | Skynet tracer | Must |
| FR-T-03 | 批量上报 | **P0** | 高 | 中 | Skynet reporter | Must |
| FR-T-04 | 后端批量入库 | **P0** | 高 | 中 | 后端 store | Must |
| FR-T-05 | 明细查询 | **P0** | 高 | 低 | 后端 server | Must |
| FR-T-06 | 聚合统计 | **P0** | 高 | 高 | 后端 store | Must |
| FR-T-07 | 时间序列 | **P0** | 高 | 中 | 后端 store | Must |
| FR-T-08 | 统计卡片 | **P0** | 中 | 低 | 前端 | Must |
| FR-T-09 | 趋势折线图 | **P0** | 高 | 中 | 前端 | Must |
| FR-T-10 | 慢调用高亮 | P1 | 低 | 低 | 前端 | Should |
| FR-T-11 | 时间范围切换 | **P0** | 高 | 低 | 前端 | Must |
| FR-T-12 | 明细下钻 | P1 | 中 | 低 | 前端 | Should |
| FR-S-01 | 健康检查 | **P0** | 中 | 低 | 后端 server | Must |
| FR-S-02 | 配置文件 | **P0** | 高 | 低 | 后端 config | Must |
| FR-S-03 | 数据自动过期 | P1 | 中 | 低 | 后端 store | Should |
| FR-S-04 | 优雅关闭 | P1 | 中 | 低 | 后端 main | Should |
| FR-S-05 | 首页导航 | P1 | 低 | 低 | 前端 | Should |

### 2.3 优先级汇总

| 优先级 | 数量 | 占比 | 说明 |
|---|---|---|---|
| **P0（Must）** | 17 项 | 63% | MVP 必须全部完成 |
| **P1（Should）** | 8 项 | 30% | v1.0 尽量完成，可延后到 v1.1 |
| **P2（Could）** | 1 项 | 4% | v1.x 视情况补做 |
| **P3（Won't）** | 0 项 | 0% | v2+ 范围在 PRD §8.3 单独列出 |

### 2.4 价值/复杂度四象限分析

```
高价值
   │
   │  ★快速获胜（高价值低复杂度）        ★战略投资（高价值高复杂度）
   │  FR-P-03 折叠栈生成                FR-P-01 采样启停
   │  FR-P-05 后端存储                  FR-P-04 HTTP 上报
   │  FR-P-06 列表查询                  FR-P-07 speedscope 转换
   │  FR-P-08 speedscope 嵌入           FR-T-01 无侵入埋点
   │  FR-T-02 cmd 标记                  FR-T-03 批量上报
   │  FR-T-05 明细查询                  FR-T-04 批量入库
   │  FR-T-07 时间序列                  FR-T-06 聚合统计（分位数）
   │  FR-T-08 统计卡片                  FR-T-09 趋势折线图
   │  FR-T-11 时间范围切换
   │  FR-S-01 健康检查
   │  FR-S-02 配置文件
   │
───┼──────────────────────────────────────────────────────────
   │
   │  ★填充项（低价值低复杂度）          ★黑洞（低价值高复杂度）
   │  FR-P-02 自动采样                  FR-P-10 swt 适配（高复杂度+不确定）
   │  FR-P-09 折叠栈下载
   │  FR-T-10 慢调用高亮
   │  FR-T-12 明细下钻
   │  FR-S-03 自动过期
   │  FR-S-04 优雅关闭
   │  FR-S-05 首页导航
   │
低价值                          低复杂度                          高复杂度
```

**结论**：MVP 聚焦「快速获胜」+「战略投资」共 17 项 P0；「填充项」8 项 P1 作为完善；「黑洞」FR-P-10 推后到 v1.x。

---

## 3. 功能模块划分

### 3.1 模块划分原则

- **单一职责**：每个模块只做一件事。
- **独立可测**：模块可独立单元测试。
- **契约通信**：模块间通过明确接口（HTTP/函数签名）通信。
- **部署单元**：模块归属同一部署单元（后端/Skynet 端/前端）。

### 3.2 模块分解图

```
firegraph 系统
│
├─【部署单元 1: Skynet 端】(Lua)
│  │
│  ├─ M1: preload 模块
│  │  └─ 职责: snlua 启动时自动初始化 firegraph
│  │  └─ 需求: FR-S-02 (Skynet 侧)
│  │
│  ├─ M2: firegraph 入口模块
│  │  └─ 职责: 暴露 API、调度采样、装配子模块
│  │  └─ 需求: FR-P-01, FR-P-02
│  │
│  ├─ M3: 采样器模块（swt_bridge）
│  │  └─ 职责: Lua 调用栈采样，输出折叠栈
│  │  └─ 需求: FR-P-01, FR-P-03, FR-P-10
│  │
│  ├─ M4: tracer 模块
│  │  └─ 职责: 包装 skynet.dispatch，记录消息耗时
│  │  └─ 需求: FR-T-01, FR-T-02, FR-T-03
│  │
│  └─ M5: reporter 模块
│     └─ 职责: HTTP 上报 profile 与 trace，重试容错
│     └─ 需求: FR-P-04, FR-T-03
│
├─【部署单元 2: 后端】(Go)
│  │
│  ├─ M6: main / config 模块
│  │  └─ 职责: 入口、配置加载、信号处理
│  │  └─ 需求: FR-S-02, FR-S-04
│  │
│  ├─ M7: store 模块
│  │  └─ 职责: SQLite 连接、schema、CRUD、聚合统计
│  │  └─ 需求: FR-P-05, FR-T-04, FR-T-06, FR-T-07, FR-S-03
│  │
│  ├─ M8: profile 处理模块
│  │  └─ 职责: 折叠栈解析、speedscope JSON 转换
│  │  └─ 需求: FR-P-07
│  │
│  ├─ M9: server 模块
│  │  └─ 职责: HTTP 路由、handler、静态资源
│  │  └─ 需求: FR-P-06, FR-P-09, FR-T-05, FR-S-01, FR-S-05
│  └─ M10: util 模块
│     └─ 职责: writeJSON / writeError 通用工具
│     └─ 需求: (内部支撑)
│
└─【部署单元 3: 前端】(静态资源)
   │
   ├─ M11: 首页 (index.html)
   │  └─ 职责: 导航
   │  └─ 需求: FR-S-05
   │
   ├─ M12: profiles 页 (profiles.html + app.js ProfilesPage)
   │  └─ 职责: profile 列表 + speedscope 嵌入
   │  └─ 需求: FR-P-06, FR-P-08
   │
   ├─ M13: traces 页 (traces.html + app.js TracesPage)
   │  └─ 职责: 统计卡片 + SVG 趋势图 + 表格 + 明细
   │  └─ 需求: FR-T-05, FR-T-08, FR-T-09, FR-T-10, FR-T-11, FR-T-12
   │
   └─ M14: speedscope 离线包
      └─ 职责: 火焰图交互渲染
      └─ 需求: FR-P-08
```

### 3.3 模块职责矩阵（RACI 简化版）

| 模块 | 采集 | 上报 | 存储 | 转换 | 查询 | 渲染 |
|---|---|---|---|---|---|---|
| M3 采样器 | **R** | - | - | - | - | - |
| M4 tracer | **R** | - | - | - | - | - |
| M5 reporter | - | **R** | - | - | - | - |
| M7 store | - | - | **R** | - | **R** | - |
| M8 profile | - | - | - | **R** | - | - |
| M9 server | - | - | - | - | **R** | - |
| M12/M13 前端 | - | - | - | - | - | **R** |

R = Responsible（负责执行）

### 3.4 模块接口契约概要

| 契约 | 提供方 | 消费方 | 类型 |
|---|---|---|---|
| `firegraph.init/start_profile/stop_profile/install_tracer/tag_cmd` | M2 | M1/M4/业务 | Lua API |
| `sampler.on_complete/start/stop` | M3 | M2 | Lua API |
| `reporter.report_profile/report_traces` | M5 | M2/M4 | Lua API |
| `POST /api/profiles/upload` | M9 | M5 | HTTP |
| `POST /api/traces/batch` | M9 | M5 | HTTP |
| `GET /api/profiles[/{id}/...]` | M9 | M12 | HTTP |
| `GET /api/traces[/stats/timeseries]` | M9 | M13 | HTTP |
| `store.InsertProfile/InsertTraces/...` | M7 | M9 | Go 方法 |
| `profile.ParseFolded/ToSpeedscope` | M8 | M9 | Go 函数 |

详细接口定义见 [代码设计文档 §3](./03-CODE_DESIGN.md#3-模块接口定义)。

---

## 4. 业务流程梳理

### 4.1 火焰图端到端流程

#### 4.1.1 采样 → 上报 → 查看 主流程

```
┌─────────────┐
│ 用户/定时器 │
└──────┬──────┘
       │ firegraph.start_profile(30)
       ▼
┌──────────────────┐
│ M2 init.lua      │
│ - 记录开始时间   │
│ - 调用 sampler   │
└──────┬───────────┘
       │ sampler.start(30)
       ▼
┌──────────────────┐    每 5000 行 Lua 指令
│ M3 swt_bridge    │ ◄──── hook_fn 触发
│ - debug.sethook  │
│ - 累积 stack_counts
└──────┬───────────┘
       │ 30s 后 stop_profile
       ▼
┌──────────────────┐
│ M3 stop          │
│ - 拼接 folded_text
│ - on_complete 回调
└──────┬───────────┘
       │ folded_text, duration
       ▼
┌──────────────────┐
│ M2 _report_profile│
│ - 调用 reporter   │
└──────┬───────────┘
       │ reporter.report_profile()
       ▼
┌──────────────────┐     失败     ┌─────────────┐
│ M5 reporter      │ ──────────► │ 重试 3 次   │
│ - HTTP POST      │             │ 间隔 1s     │
└──────┬───────────┘             └─────┬───────┘
       │ 200 OK                        │ 仍失败
       ▼                               ▼
┌──────────────────┐             ┌─────────────┐
│ M9 profile_upload│             │ 丢弃不阻塞  │
│ - 解析 folded    │             │ 业务        │
│ - InsertProfile  │             └─────────────┘
└──────┬───────────┘
       │ 写入 SQLite
       ▼
┌──────────────────┐
│ M7 store         │
│ - profiles 表    │
└──────────────────┘

           【查询阶段】
           
┌─────────────┐
│ 浏览器用户  │
└──────┬──────┘
       │ 访问 /profiles.html
       ▼
┌──────────────────┐
│ M12 ProfilesPage │
│ - GET /api/profiles
│ - 渲染列表       │
└──────┬───────────┘
       │ 点击「查看火焰图」
       ▼
┌──────────────────┐
│ M14 speedscope   │
│ - #profileURL=   │
│ - fetch JSON     │
└──────┬───────────┘
       │ GET /api/profiles/{id}/speedscope.json
       ▼
┌──────────────────┐
│ M9 speedscope    │
│ - GetProfile(id) │
│ - ToSpeedscope() │
│ - CORS 头        │
└──────┬───────────┘
       │ JSON
       ▼
┌──────────────────┐
│ M14 渲染三视图   │
└──────────────────┘
```

#### 4.1.2 关键决策点

| 节点 | 决策 | 备选 | 选择理由 |
|---|---|---|---|
| 采样触发 | 手动 vs 自动 | 二者皆支持 | 开发期手动、生产期自动 |
| 采样器 | 内置 vs swt | 优先 swt，回退内置 | 内置开箱即用，swt 需 patch |
| 上报失败 | 重试 vs 缓存 | 重试 3 次后丢弃 | 缓存增加复杂度，profile 一次性数据可丢 |
| 渲染方式 | 后端 SVG vs 前端 speedscope | 前端 speedscope | 交互体验最佳，后端零渲染开销 |

### 4.2 接口耗时端到端流程

#### 4.2.1 埋点 → 上报 → 查询 主流程

```
┌─────────────┐
│ snlua 启动  │
└──────┬──────┘
       │ preload.lua
       ▼
┌──────────────────┐
│ M1 preload       │
│ - firegraph.init │
│ - install_tracer │
└──────┬───────────┘
       │ tracer.install(cfg, reporter)
       ▼
┌──────────────────────────────────────────┐
│ M4 tracer.install                        │
│ - 保存 original_dispatch                 │
│ - 替换 skynet.dispatch 为 wrapped 版本   │
│ - 启动 _flush_loop 协程（5s 周期）       │
└──────────────────────────────────────────┘
           │
           │ 每条消息到达
           ▼
┌──────────────────────────────────────────┐
│ M4 wrapped handler                       │
│ ┌────────────────────────────────────┐   │
│ │ start = skynet.now()               │   │
│ │ pcall(handler, ...)                │   │
│ │ cost = skynet.now() - start        │   │
│ │ cmd = current_cmd[co] or proto     │   │
│ │ _record({ts, service, proto, cmd,  │   │
│ │         session, cost_ms, ok})     │   │
│ └────────────────────────────────────┘   │
└──────────┬───────────────────────────────┘
           │
           │ 累积 ≥ 100 条 或 5s 到期
           ▼
┌──────────────────┐
│ M4 _flush        │
│ - 切换 buffer    │
│ - skynet.fork    │  ← 异步不阻塞 dispatch
└──────┬───────────┘
       │ reporter.report_traces(traces)
       ▼
┌──────────────────┐
│ M5 reporter      │
│ - 构建 NDJSON    │
│ - HTTP POST      │
│ - 重试 3 次      │
└──────┬───────────┘
       │ 200 OK
       ▼
┌──────────────────────────────────────────┐
│ M9 trace_batch handler                   │
│ - MaxBytesReader(8MB)                    │
│ - ParseNDJSONTraces（容错跳过错误行）    │
│ - InsertTraces（单事务）                 │
└──────┬───────────────────────────────────┘
       │
       ▼
┌──────────────────┐
│ M7 store         │
│ - traces 表      │
└──────────────────┘

           【查询阶段】
           
┌─────────────┐
│ 浏览器用户  │
└──────┬──────┘
       │ 打开 /traces.html，选时间范围
       ▼
┌──────────────────────────────────────────┐
│ M13 TracesPage.load                      │
│ - 并行 fetch：                           │
│   ├ /api/traces/stats                    │
│   └ /api/traces/timeseries?bucket_sec=   │
└──────┬───────────────────────────────────┘
       │
       ▼
┌──────────────────┐    ┌──────────────────┐
│ M9 stats handler │    │ M9 timeseries    │
│ - AggregateStats │    │ - QueryTimeseries│
└──────┬───────────┘    └──────┬───────────┘
       │                       │
       ▼                       ▼
┌──────────────────────────────────────────┐
│ M7 store                                 │
│ - stats: SQL count/avg/max + 内存分位数  │
│ - timeseries: SQL 分桶 + 每桶内存 P95    │
└──────┬───────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│ M13 前端渲染                             │
│ - 5 张统计卡片（汇总）                   │
│ - SVG 折线图（Avg/P95/P99）              │
│ - 表格（按 avg 倒序，高亮慢调用）        │
└──────────────────────────────────────────┘
       │
       │ 点击表格「明细」
       ▼
┌──────────────────────────────────────────┐
│ M13 showDetail                           │
│ - GET /api/traces?service=&cmd=&limit=100│
│ - 渲染明细表                             │
└──────────────────────────────────────────┘
```

#### 4.2.2 关键决策点

| 节点 | 决策 | 备选 | 选择理由 |
|---|---|---|---|
| 埋点层 | dispatch vs skynet.call | dispatch | 覆盖所有消息、记录处理耗时语义正确 |
| cmd 来源 | tag_cmd vs proto | 二者皆支持 | 业务可显式标记，未标记用 proto 兜底 |
| cmd 存储 | 协程级 threadlocal vs 全局 | 协程级 `current_cmd[co]` | 避免多协程并发污染 |
| 上报时机 | 数量阈值 vs 时间阈值 | 二者取先到 | 平衡延迟与吞吐 |
| 上报方式 | 同步 vs 异步 | `skynet.fork` 异步 | 不阻塞 dispatch |
| 分位数 | SQL vs 内存 | SQL 算基础 + 内存算分位 | SQLite 无 PERCENTILE 函数 |
| 图表 | ECharts vs 纯 SVG | 纯 SVG | 零依赖、内网可用 |

### 4.3 数据自动过期流程

```
后端启动
   │
   ▼
┌──────────────────┐
│ M6 main          │
│ - 启动定时器     │  ← 当前未接入，需求 FR-S-03 标 P1
└──────┬───────────┘
       │ 每日触发
       ▼
┌──────────────────────────────────────────┐
│ M7 store                                 │
│ - DeleteOldProfiles(beforeTs)            │
│ - DeleteOldTraces(beforeTs)              │
│ - beforeTs = now - retention_days*86400  │
└──────────────────────────────────────────┘
```

> **当前状态**：store 层方法已实现（`DeleteOldProfiles` / `DeleteOldTraces`），但 main.go 未接入定时调用，属 P1 待补。

### 4.4 优雅关闭流程

```
收到 SIGINT/SIGTERM
   │
   ▼
┌──────────────────────────────────────────┐
│ M6 main 信号处理 goroutine               │
│ - context.WithTimeout(5s)                │
│ - srv.Shutdown(ctx)                      │
└──────┬───────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│ M9 server.Shutdown                       │
│ - httpSrv.Shutdown(ctx)                  │
│   - 拒绝新请求                           │
│   - 等待在途请求完成                     │
│   - 5s 超时强制退出                      │
└──────┬───────────────────────────────────┘
       │
       ▼
┌──────────────────┐
│ M6 main          │
│ - st.Close()     │  ← defer
│ - log "bye"      │
└──────────────────┘
```

---

## 5. 需求依赖关系

### 5.1 依赖关系矩阵

| 需求 ID | 依赖前置 | 被依赖 | 说明 |
|---|---|---|---|
| FR-P-01 | - | FR-P-02, FR-P-03, FR-P-04 | 采样启停是其他采样需求的基础 |
| FR-P-03 | FR-P-01 | FR-P-04, FR-P-07 | 折叠栈格式是上报与转换的契约 |
| FR-P-04 | FR-P-03 | - | 上报依赖折叠栈生成 |
| FR-P-05 | - | FR-P-06, FR-P-07, FR-P-09 | 存储是查询/转换/下载的基础 |
| FR-P-06 | FR-P-05 | FR-P-08 | 列表查询供前端使用 |
| FR-P-07 | FR-P-05 | FR-P-08 | speedscope 转换供前端使用 |
| FR-P-08 | FR-P-06, FR-P-07 | - | 嵌入查看依赖列表与转换 |
| FR-T-01 | - | FR-T-02, FR-T-03 | 埋点是其他 trace 需求的基础 |
| FR-T-02 | FR-T-01 | - | cmd 标记依赖埋点已安装 |
| FR-T-03 | FR-T-01 | FR-T-04 | 批量上报依赖埋点记录 |
| FR-T-04 | - | FR-T-05, FR-T-06, FR-T-07 | 入库是查询/统计/序列的基础 |
| FR-T-05 | FR-T-04 | FR-T-12 | 明细查询供下钻使用 |
| FR-T-06 | FR-T-04 | FR-T-08 | 聚合供卡片展示 |
| FR-T-07 | FR-T-04 | FR-T-09 | 序列供图表展示 |
| FR-T-08 | FR-T-06 | - | 卡片依赖聚合 |
| FR-T-09 | FR-T-07 | - | 图表依赖序列 |
| FR-T-11 | FR-T-07, FR-T-09 | - | 范围切换影响序列与图表 |
| FR-T-12 | FR-T-05 | - | 下钻依赖明细查询 |

### 5.2 依赖关系图（简化）

```
【火焰图链路】
FR-P-01 ─► FR-P-03 ─► FR-P-04 ─► FR-P-05 ─► FR-P-06 ─┐
                                  FR-P-07 ─► FR-P-08 ◄─┘
                                  FR-P-09
FR-P-02 (依赖 FR-P-01，独立可并行)
FR-P-10 (独立，可选)

【接口耗时链路】
FR-T-01 ─► FR-T-02
        ├─► FR-T-03 ─► FR-T-04 ─► FR-T-05 ─► FR-T-12
        │                          FR-T-06 ─► FR-T-08
        │                          FR-T-07 ─► FR-T-09 ─► FR-T-11
        └─► FR-T-10 (前端独立)

【系统管理】
FR-S-01 (独立)
FR-S-02 (独立，被所有需求依赖)
FR-S-03 (依赖 FR-P-05, FR-T-04)
FR-S-04 (独立)
FR-S-05 (独立)
```

### 5.3 关键路径（Critical Path）

MVP 关键路径（决定项目最早完成时间）：

```
FR-S-02 (配置) → FR-P-05 (存储) → FR-P-03 (折叠栈) → FR-P-01 (采样) 
→ FR-P-04 (上报) → FR-P-07 (转换) → FR-P-08 (查看)
```

接口耗时关键路径：

```
FR-T-01 (埋点) → FR-T-03 (批量上报) → FR-T-04 (入库) 
→ FR-T-06 (聚合) → FR-T-09 (图表)
```

---

## 6. 需求可实现性评估

### 6.1 技术可行性评估

| 需求 | 技术方案 | 可行性 | 评估说明 |
|---|---|---|---|
| FR-P-01 采样启停 | `debug.sethook("l", N)` | ✅ 完全可行 | Lua 标准库，skynet 原生支持 |
| FR-P-02 自动采样 | `skynet.fork` + `skynet.sleep` 循环 | ✅ 完全可行 | skynet 标准用法 |
| FR-P-03 折叠栈 | `debug.traceback` + 字符串拼接 | ✅ 完全可行 | 业界标准做法 |
| FR-P-04 HTTP 上报 | `skynet.httpc.request` | ✅ 完全可行 | skynet 自带 httpc |
| FR-P-05 SQLite 存储 | `modernc.org/sqlite` 纯 Go | ✅ 完全可行 | 已验证 |
| FR-P-07 speedscope 转换 | folded → frame dedup → JSON | ✅ 完全可行 | speedscope 格式明确 |
| FR-P-08 speedscope 嵌入 | `#profileURL=` hash fragment | ✅ 完全可行 | speedscope 官方支持 |
| FR-P-10 swt 适配 | 调用 swt C API | ⚠️ 中等风险 | swt API 不确定，需调研 |
| FR-T-01 dispatch 包装 | 替换 `skynet.dispatch` 函数 | ✅ 完全可行 | Lua 动态特性支持 |
| FR-T-02 cmd 标记 | `coroutine.running()` 做 key | ✅ 完全可行 | 协程级 threadlocal 模式 |
| FR-T-03 批量上报 | buffer + 阈值/定时 flush | ✅ 完全可行 | 标准做法 |
| FR-T-06 聚合分位数 | SQL count/avg + 内存排序插值 | ✅ 可行（有性能限制） | 百万级数据变慢，需优化 |
| FR-T-07 时间序列 | SQL `(ts/?)*?` 分桶 | ✅ 完全可行 | SQLite 表达式分桶 |
| FR-T-09 SVG 折线图 | 原生 JS 拼 SVG path | ✅ 完全可行 | 需求简单，~60 行可完成 |
| FR-S-03 自动过期 | 定时任务调 `DeleteOld*` | ✅ 完全可行 | store 层方法已实现 |

### 6.2 资源估算

| 模块 | 代码行数估算 | 实现复杂度 | 测试复杂度 |
|---|---|---|---|
| M1 preload | ~50 行 Lua | 低 | 低 |
| M2 firegraph 入口 | ~120 行 Lua | 中 | 中 |
| M3 swt_bridge | ~120 行 Lua | 中 | 中（需真实 skynet 环境） |
| M4 tracer | ~100 行 Lua | 中 | 中 |
| M5 reporter | ~120 行 Lua | 中 | 低 |
| M6 main/config | ~100 行 Go | 低 | 低 |
| M7 store | ~350 行 Go | 中 | 中（需测分位数） |
| M8 profile | ~130 行 Go | 低 | 低 |
| M9 server | ~280 行 Go | 低 | 低 |
| M11-M13 前端 | ~340 行 JS + 3 HTML | 中 | 中（需手测交互） |
| **合计** | ~1700 行 | 中 | 中 |

### 6.3 复杂度热点

1. **FR-T-06 聚合统计（高）**：分位数内存计算，需兼顾正确性与性能。
2. **FR-P-10 swt 适配（高）**：swt API 不确定，需调研与试错。
3. **FR-P-01 采样器（中）**：`debug.traceback` 字符串解析较繁琐，需覆盖多种格式。
4. **FR-T-09 SVG 图表（中）**：坐标变换、刻度自适应、多线渲染。
5. **FR-T-01 dispatch 包装（中）**：协程级状态管理、错误传播。

### 6.4 可实现性结论

- **P0 17 项**：100% 可实现，技术方案均已验证，无阻塞风险。
- **P1 8 项**：100% 可实现，作为 v1.0 完善或 v1.1 补做。
- **P2 1 项（FR-P-10 swt）**：可实现性中等，需先调研 swt 实际 API，建议作为 v1.x 可选项。
- **整体评估**：MVP 范围可在阶段计划内完成，无关键技术阻塞。

---

## 7. 风险分析与应对

### 7.1 技术风险

| 风险 ID | 风险描述 | 概率 | 影响 | 应对措施 | 责任人 |
|---|---|---|---|---|---|
| **R-01** | 内置采样器只能采样当前协程，跨协程业务漏采 | 高 | 中 | 文档明确限制；提供 swt 升级路径；CPU 密集型业务通常集中在少数协程，影响可控 | 研发 |
| **R-02** | swt API 不确定，适配代码可能失效 | 中 | 中 | 内置采样器作为兜底；swt 适配代码标注「示意」，需根据实际版本调整 | 研发 |
| **R-03** | SQLite 分位数内存计算，百万级数据查询慢 | 中 | 中 | 文档标注限制；v1.x 优化为预聚合表或 window function；v2 可迁移 ClickHouse | 研发 |
| **R-04** | trace 上报对业务性能影响未压测 | 中 | 高 | 批量上报 + 异步发送降低开销；生产前必须压测；提供开关 `firegraph_enable_tracer` | 研发+测试 |
| **R-05** | speedscope CORS 配置错误导致加载失败 | 低 | 高 | 后端响应明确设置 `Access-Control-Allow-Origin: *`；联调验证 | 研发 |
| **R-06** | `ok` 字段 boolean vs string 解析 bug | 低 | 中 | 已修复（v1.0）；用 `jsonGetBool` 优先解析；增加测试用例 | 研发 |

### 7.2 项目风险

| 风险 ID | 风险描述 | 概率 | 影响 | 应对措施 |
|---|---|---|---|---|
| **R-P-01** | 范围蔓延（用户提出阶段 3 需求） | 中 | 中 | 严格按 MVP 范围执行，阶段 3 需求单独排期 |
| **R-P-02** | skynet 环境不具备（开发机无 skynet） | 中 | 中 | 后端可独立开发与测试；skynet 端用 mock 验证 |
| **R-P-03** | 缺少单元测试覆盖 | 高 | 中 | v1.1 补充核心模块测试（folded/percentile/NDJSON） |

### 7.3 风险监控

- 每周回顾风险列表，更新概率与影响。
- 高风险项（R-04）在 v1.0 上线前必须完成压测验证。
- 中风险项（R-01, R-02, R-03）在文档中明确标注，向用户透明。

---

## 8. 里程碑与实施建议

### 8.1 里程碑划分

| 里程碑 | 内容 | 关联需求 | 验收 |
|---|---|---|---|
| **M0: 骨架** | go.mod / main / store / 路由占位 | FR-S-01, FR-S-02 | `go build` 通过，`/healthz` 返回 ok |
| **M1: 火焰图后端** | profile 上传/查询/转换 | FR-P-05, FR-P-06, FR-P-07, FR-P-09 | 用本地折叠栈文件模拟上报，speedscope JSON 校验通过 |
| **M2: 火焰图前端** | profiles.html + speedscope 嵌入 | FR-P-08, FR-S-05 | 浏览器内可交互查看火焰图 |
| **M3: Skynet 采样** | preload + sampler + reporter | FR-P-01, FR-P-03, FR-P-04, FR-P-02 | 真实 skynet 采样 → 上报 → 查看 全链路打通 |
| **M4: 接口埋点** | tracer + 批量上报 + 入库 | FR-T-01, FR-T-02, FR-T-03, FR-T-04 | `SELECT count(*) FROM traces` > 0 |
| **M5: 接口耗时前端** | traces.html + stats/timeseries | FR-T-05, FR-T-06, FR-T-07, FR-T-08, FR-T-09, FR-T-11 | 前端展示分位+图表 |
| **M6: 联调 + 文档** | 端到端验证 + README + 文档 | FR-T-10, FR-T-12, FR-S-03, FR-S-04, NFR-MAINT-05 | 全部 AC 用例通过 |

### 8.2 实施顺序建议

```
M0 骨架 (1d)
  │
  ▼
M1 火焰图后端 (2d)  ──┐
                      │ 可并行
M2 火焰图前端 (1d)  ──┘
  │
  ▼
M3 Skynet 采样 (2d)
  │
  ▼
M4 接口埋点 (2d)
  │
  ▼
M5 接口耗时前端 (2d)
  │
  ▼
M6 联调 + 文档 (1d)
```

### 8.3 验收里程碑

- **α 版本**（M3 完成）：火焰图端到端可用，可邀请开发试用。
- **β 版本**（M5 完成）：接口耗时端到端可用，可邀请运维试用。
- **GA 版本**（M6 完成）：文档齐全，全部 AC 用例通过，可交付。

---

## 9. 附录：需求追溯矩阵

> 追溯 PRD 需求 → 模块 → 验收用例 → 实现文件，确保无遗漏。

### 9.1 功能需求追溯

| 需求 ID | 模块 | 验收用例 | 实现文件 | 状态 |
|---|---|---|---|---|
| FR-P-01 | M2/M3 | AC-P-01 | `init.lua` / `swt_bridge.lua` | ✅ |
| FR-P-02 | M2 | AC-P-02 | `init.lua` | ✅ |
| FR-P-03 | M3 | AC-P-03 | `swt_bridge.lua` | ✅ |
| FR-P-04 | M5 | AC-P-06 | `reporter.lua` | ✅ |
| FR-P-05 | M7 | AC-P-07 | `profile_repo.go` / `schema.sql` | ✅ |
| FR-P-06 | M9 | AC-P-04 | `profile_handler.go` | ✅ |
| FR-P-07 | M8 | AC-P-05, AC-P-07 | `folded.go` / `speedscope.go` | ✅ |
| FR-P-08 | M12/M14 | AC-P-05 | `profiles.html` / `app.js` | ✅ |
| FR-P-09 | M9 | AC-P-03 | `profile_handler.go` | ✅ |
| FR-P-10 | M3 | - | `swt_bridge.lua`（示意） | 🔲 v1.x |
| FR-T-01 | M4 | AC-T-01, AC-T-02 | `tracer.lua` | ✅ |
| FR-T-02 | M4 | AC-T-03 | `tracer.lua` | ✅ |
| FR-T-03 | M4/M5 | AC-T-04 | `tracer.lua` / `reporter.lua` | ✅ |
| FR-T-04 | M7 | AC-T-01, AC-T-11 | `trace_repo.go` | ✅ |
| FR-T-05 | M9 | AC-T-10 | `trace_handler.go` | ✅ |
| FR-T-06 | M7 | AC-T-05, AC-T-12 | `trace_repo.go` | ✅ |
| FR-T-07 | M7 | AC-T-06 | `trace_repo.go` | ✅ |
| FR-T-08 | M13 | AC-T-07 | `traces.html` / `app.js` | ✅ |
| FR-T-09 | M13 | AC-T-08 | `app.js` | ✅ |
| FR-T-10 | M13 | AC-T-09 | `app.js` / `app.css` | ✅ |
| FR-T-11 | M13 | AC-T-08 | `app.js` | ✅ |
| FR-T-12 | M13 | AC-T-10 | `app.js` / `traces.html` | ✅ |
| FR-S-01 | M9 | AC-S-01 | `server.go` | ✅ |
| FR-S-02 | M6 | AC-S-03 | `config.go` / `preload.lua` | ✅ |
| FR-S-03 | M7/M6 | - | `*_repo.go`（方法已实现，未接定时器） | 🔲 v1.1 |
| FR-S-04 | M6 | AC-S-02 | `main.go` | ✅ |
| FR-S-05 | M11 | AC-S-04 | `index.html` | ✅ |

### 9.2 非功能需求追溯

| 需求 ID | 验证方式 | 状态 |
|---|---|---|
| NFR-PERF-01 | 压测对比（待补） | 🔲 待压测 |
| NFR-PERF-02 | 压测对比（待补） | 🔲 待压测 |
| NFR-PERF-03 | 代码审查：`skynet.fork` 异步 | ✅ |
| NFR-PERF-04 | AC-NFR-04 | ✅ |
| NFR-PERF-05 | 查询响应计时 | ✅（小数据量） |
| NFR-PERF-06 | 代码审查：WAL + busy_timeout | ✅ |
| NFR-REL-01 | AC-P-06 | ✅ |
| NFR-REL-02 | AC-T-11 | ✅ |
| NFR-REL-03 | 代码审查：`BeginTx` + `Commit` | ✅ |
| NFR-REL-04 | SQLite WAL 特性 | ✅ |
| NFR-MAINT-01 | AC-NFR-01 | ✅ |
| NFR-MAINT-02 | AC-NFR-05 | ✅ |
| NFR-MAINT-03 | 代码审查：无 npm/webpack | ✅ |
| NFR-MAINT-04 | 代码审查：yaml + getenv | ✅ |
| NFR-MAINT-05 | 文档清单 | ✅ |
| NFR-SEC-01 | 设计说明 | ✅ |
| NFR-SEC-02 | AC-NFR-03 | ✅ |
| NFR-SEC-03 | 代码审查：prepared stmt | ✅ |
| NFR-COMPAT-01~04 | 矩阵说明 | ✅ |
| NFR-OBS-01~03 | 代码审查 | ✅ |

---

**文档结束。** 本文是 firegraph 项目的需求分析基线，为 [代码设计文档](./03-CODE_DESIGN.md) 提供输入。需求变更需更新本文档并升级版本号。
