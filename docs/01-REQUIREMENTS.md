# firegraph 需求文档（PRD）

| 项 | 内容 |
|---|---|
| 文档版本 | v1.0 |
| 产品名称 | firegraph — Skynet 游戏服务器性能与接口耗时监测平台 |
| 文档状态 | 已评审 / 已实现 |
| 创建日期 | 2026-06-28 |
| 目标读者 | 产品 / 研发 / 测试 / 运维 / AI 辅助开发工具 |
| 上游输入 | 用户口头需求 + [技术设计文档](./TECHNICAL_DESIGN.md) |
| 下游产物 | [需求分析文档](./02-REQUIREMENTS_ANALYSIS.md)、[代码设计文档](./03-CODE_DESIGN.md) |

---

## 目录

1. [项目背景](#1-项目背景)
2. [项目目标](#2-项目目标)
3. [用户角色与画像](#3-用户角色与画像)
4. [用户场景](#4-用户场景)
5. [功能需求](#5-功能需求)
6. [非功能需求](#6-非功能需求)
7. [验收标准](#7-验收标准)
8. [项目范围](#8-项目范围)
9. [假设与约束](#9-假设与约束)
10. [附录：术语表](#10-附录术语表)

---

## 1. 项目背景

### 1.1 业务现状

我司游戏服务器基于 **Skynet + Lua** 技术栈（Skynet 是 C 实现的 actor 模型框架，业务逻辑由 snlua 服务承载，每个服务独立 Lua VM）。在长期运营中暴露两类性能痛点：

1. **CPU 热点难定位**：线上偶发 CPU 飙高，缺乏可视化手段定位是哪个 Lua 函数消耗了大量时间。
2. **接口耗时黑盒**：玩家反馈"操作卡顿"，但无法快速回答"哪个接口慢、慢到什么程度、何时开始变慢、错误率多少"。

### 1.2 现有方案不足

| 现有手段 | 问题 |
|---|---|
| skynet 自带 debug console | 仅文本输出，无可视化，无历史 |
| 业务日志打印耗时 | 侵入业务代码、覆盖不全、无聚合统计 |
| 通用 APM（SkyWalking/Pinpoint） | 不支持 Lua 调用栈采样、部署重 |
| brendangregg/FlameGraph | 只有静态 SVG，无交互、无接口维度 |

### 1.3 机会点

- 开源生态已有成熟组件可复用：[speedscope](https://github.com/jlfwong/speedscope)（交互式火焰图）、[swt](https://github.com/lsg2020/swt)（Skynet Lua profiler）、[FlameGraph.pl](https://github.com/brendangregg/FlameGraph)（折叠栈工具）。
- 缺的是一个**面向 Skynet 场景的端到端组装与定制**：从采集 → 上报 → 聚合 → 可视化的完整闭环。

---

## 2. 项目目标

### 2.1 总目标

构建一个**最小侵入、单二进制部署、浏览器交互**的性能监测平台，端到端覆盖 Skynet 服务的 CPU 热点分析与接口耗时统计。

### 2.2 可量化目标

| 编号 | 目标 | 衡量指标 |
|---|---|---|
| G-1 | CPU 火焰图可视化 | 用户可在浏览器内交互查看 Lua 调用栈热点，三种视图（Time Order / Left Heavy / Sandwich） |
| G-2 | 接口耗时分位统计 | 提供 P50/P95/P99 分位 + 趋势图，按 service/cmd 维度聚合 |
| G-3 | 无侵入接入 | 业务代码零改动，仅通过 skynet preload 配置接入 |
| G-4 | 单二进制部署 | 后端单一可执行文件，无外部 DB/中间件依赖 |
| G-5 | 内网零依赖 | 前端无 CDN 依赖，离线环境可用 |
| G-6 | 性能开销可控 | 采样对业务 CPU 开销 < 5%；埋点对单消息延迟增加 < 100μs |

### 2.3 非目标（明确不做）

- 不做通用 APM（不覆盖 Java/Go/Python 等其他语言）。
- 不做分布式链路追踪（trace 不是 OpenTelemetry 链路，是单服务消息耗时）。
- 不做实时流式观测（MVP 是批量上报 + 历史查询）。
- 不做公网部署（内网工具，无鉴权）。

---

## 3. 用户角色与画像

| 角色 | 主要诉求 | 使用频次 | 技术背景 |
|---|---|---|---|
| **服务端开发** | 定位 CPU 热点函数、排查慢接口根因 | 高（每日） | 熟悉 Skynet/Lua，能读火焰图 |
| **运维工程师** | 巡检服务健康、监控趋势、归档历史 | 中（每周） | 熟悉 Linux/部署，会看 P95 趋势 |
| **测试工程师** | 压测后查看接口耗时分布、回归对比 | 中（每次版本） | 会用浏览器、能看分位数 |
| **技术负责人** | 评估性能优化效果、决策优化方向 | 低（每月） | 关注宏观趋势与对比 |

---

## 4. 用户场景

### 场景 S-1：开发期 CPU 热点定位

- **触发**：开发同学发现某服务 CPU 占用异常。
- **流程**：
  1. 调用 `firegraph.start_profile(30)` 启动 30 秒采样
  2. 采样结束自动上报到后端
  3. 浏览器打开 `/profiles.html`，找到刚上报的 profile
  4. 点击「查看火焰图」在 speedscope 中交互分析
  5. 在 Left Heavy 视图找到最宽的函数帧
- **预期结果**：5 分钟内定位到 CPU 热点函数。

### 场景 S-2：生产期定期巡检

- **触发**：运维配置 `firegraph_auto_profile_interval = 300`，每 5 分钟自动采样。
- **流程**：
  1. snlua 服务自动周期性采样并上报
  2. 运维每日打开 `/profiles.html` 查看新 profile
  3. 对比不同时间点的 profile，观察热点变化
- **预期结果**：积累历史 profile 库，支撑性能回归对比。

### 场景 S-3：慢接口排查

- **触发**：玩家反馈"登录卡"。
- **流程**：
  1. 打开 `/traces.html`
  2. service 过滤框输入 `login`，时间范围选 1h
  3. 查看表格：Login 命令的 P95 是否高于阈值
  4. 查看趋势图：P95 是否在某时刻开始抖动
  5. 点击「明细」查看该接口最近 100 条 trace，找出慢调用与失败调用
- **预期结果**：3 分钟内回答"慢不慢、慢多少、何时开始、失败率"。

### 场景 S-4：压测后回归分析

- **触发**：版本发布前压测。
- **流程**：
  1. 压测期间开启 `firegraph_enable_tracer = true`
  2. 压测结束后打开 `/traces.html`，时间范围选压测时段
  3. 对比上个版本的 P95/P99
  4. 用 FlameGraph.pl 对比新旧 profile（离线 diff）
- **预期结果**：量化版本性能变化，识别退化接口。

---

## 5. 功能需求

> 编号规则：`FR-<模块>-<序号>`。优先级定义见 [需求分析文档](./02-REQUIREMENTS_ANALYSIS.md)。

### 5.1 CPU 火焰图模块（FR-P）

| 编号 | 需求名称 | 描述 | 优先级 |
|---|---|---|---|
| **FR-P-01** | 运行时采样启停 | 支持在 snlua 服务运行时启动/停止 Lua 调用栈采样，不重启服务 | P0 |
| **FR-P-02** | 自动周期采样 | 支持配置 `auto_profile_interval` 周期性自动采样，0 表示不自动 | P1 |
| **FR-P-03** | 折叠栈生成 | 采样结果以 Folded Stacks 格式输出（`main;foo;bar 123`），兼容 FlameGraph.pl | P0 |
| **FR-P-04** | HTTP 上报 | 采样完成后通过 HTTP POST 上报到后端，失败重试 3 次，最终失败丢弃不阻塞业务 | P0 |
| **FR-P-05** | 后端存储 | 后端持久化 profile 元数据 + 折叠栈原文到 SQLite | P0 |
| **FR-P-06** | Profile 列表查询 | 支持 service/node/时间范围过滤，分页返回摘要（不含大字段） | P0 |
| **FR-P-07** | speedscope JSON 转换 | 后端按需将折叠栈转换为 speedscope `sampled` 格式 JSON | P0 |
| **FR-P-08** | speedscope 嵌入查看 | 前端列表页一键打开 speedscope，通过 `#profileURL=` 加载远程 JSON | P0 |
| **FR-P-09** | 折叠栈原文下载 | 支持下载原始 folded.txt，便于离线用 FlameGraph.pl 生成 SVG | P1 |
| **FR-P-10** | swt 适配器（可选） | 支持接入 swt 获得全服务精确采样，作为内置采样器的可选升级 | P2 |

### 5.2 接口耗时模块（FR-T）

| 编号 | 需求名称 | 描述 | 优先级 |
|---|---|---|---|
| **FR-T-01** | 无侵入埋点 | 通过包装 `skynet.dispatch` 自动记录每条消息处理耗时，业务代码零改动 | P0 |
| **FR-T-02** | 命令名标记 | 业务可在 handler 内调用 `firegraph.tag_cmd(cmd)` 标记真实命令名，未标记则用 proto 名 | P0 |
| **FR-T-03** | 批量上报 | 累积 100 条或 5 秒触发批量上报，NDJSON 格式，body 上限 8MB | P0 |
| **FR-T-04** | 后端批量入库 | 后端单事务批量插入，容错跳过格式错误行 | P0 |
| **FR-T-05** | 明细查询 | 支持按 service/cmd/时间范围过滤，分页返回 trace 明细 | P0 |
| **FR-T-06** | 聚合统计 | 按 service+cmd 分组返回 count/ok_count/avg/max/min + P50/P95/P99 | P0 |
| **FR-T-07** | 时间序列 | 按 bucket_sec 分桶返回每桶 count/avg/P95 | P0 |
| **FR-T-08** | 统计卡片 | 前端展示总调用/平均/P95/P99/慢调用 5 张汇总卡 | P0 |
| **FR-T-09** | 趋势折线图 | 前端纯 SVG 渲染 Avg/P95/P99 三条折线，无 ECharts 依赖 | P0 |
| **FR-T-10** | 慢调用高亮 | 表格中 cost_ms ≥ 500 红色、≥ 200 橙色 | P1 |
| **FR-T-11** | 时间范围切换 | 支持 1h/6h/24h/7d 四档时间范围切换，自动调整 bucket 粒度 | P0 |
| **FR-T-12** | 明细下钻 | 点击表格行展开该接口最近 100 条 trace | P1 |

### 5.3 系统管理模块（FR-S）

| 编号 | 需求名称 | 描述 | 优先级 |
|---|---|---|---|
| **FR-S-01** | 健康检查 | `GET /healthz` 返回 200 ok | P0 |
| **FR-S-02** | 配置文件 | YAML 配置文件，支持监听地址/DB 路径/保留天数 | P0 |
| **FR-S-03** | 数据自动过期 | 按 `retention_days` 自动清理过期 profile 与 trace（0=永久） | P1 |
| **FR-S-04** | 优雅关闭 | 收到 SIGINT/SIGTERM 后优雅关闭 HTTP 服务（5s 超时） | P1 |
| **FR-S-05** | 首页导航 | 提供 `/` 首页，导航到火焰图/接口耗时/健康检查 | P1 |

---

## 6. 非功能需求

> 编号规则：`NFR-<类别>-<序号>`。

### 6.1 性能（NFR-PERF）

| 编号 | 需求 | 指标 |
|---|---|---|
| **NFR-PERF-01** | 采样器开销 | 内置采样器对业务 CPU 开销 < 5% |
| **NFR-PERF-02** | 埋点开销 | dispatch 包装对单消息延迟增加 < 100μs |
| **NFR-PERF-03** | 上报非阻塞 | 上报通过 `skynet.fork` 异步，不阻塞 dispatch |
| **NFR-PERF-04** | 后端写入吞吐 | 批量上报 1000 条 trace 入库 < 1s |
| **NFR-PERF-05** | 查询响应 | stats/timeseries 查询响应 < 500ms（数据量 < 100 万） |
| **NFR-PERF-06** | 并发写入 | SQLite WAL 模式 + busy_timeout=5s 支持并发写 |

### 6.2 可靠性（NFR-REL）

| 编号 | 需求 | 指标 |
|---|---|---|
| **NFR-REL-01** | 上报失败容错 | 上报失败重试 3 次（间隔 1s），最终失败丢弃不阻塞业务 |
| **NFR-REL-02** | 解析容错 | NDJSON 解析跳过格式错误行，不阻塞整批 |
| **NFR-REL-03** | 数据完整性 | 批量插入用单事务，要么全部成功要么全部回滚 |
| **NFR-REL-04** | 服务可用性 | 后端单点即可，崩溃重启不丢数据（SQLite WAL） |

### 6.3 可维护性（NFR-MAINT）

| 编号 | 需求 | 指标 |
|---|---|---|
| **NFR-MAINT-01** | 单二进制部署 | 后端单一可执行文件，无外部 DB/中间件依赖 |
| **NFR-MAINT-02** | 无 CGO 依赖 | `CGO_ENABLED=0` 可编译，跨平台零障碍 |
| **NFR-MAINT-03** | 前端无构建链 | 原生 JS + SVG，无 npm/webpack |
| **NFR-MAINT-04** | 配置驱动 | 行为通过配置文件 + 环境变量驱动，无需改代码 |
| **NFR-MAINT-05** | 文档完整 | 提供 README + 技术设计文档 + 需求文档 + 代码设计文档 |

### 6.4 安全（NFR-SEC）

| 编号 | 需求 | 说明 |
|---|---|---|
| **NFR-SEC-01** | 内网部署 | MVP 不实现鉴权，依赖内网隔离 |
| **NFR-SEC-02** | body 大小限制 | profile upload 32MB / trace batch 8MB，防止超大上报打爆内存 |
| **NFR-SEC-03** | SQL 注入防护 | 所有 SQL 用 prepared statement + 占位符 |

### 6.5 兼容性（NFR-COMPAT）

| 编号 | 需求 | 说明 |
|---|---|---|
| **NFR-COMPAT-01** | Skynet 版本 | 内置采样器对 skynet 版本无要求；swt 需 skynet 应用 commit `4ace42e8` |
| **NFR-COMPAT-02** | Lua 版本 | 支持 Lua 5.3 / 5.4 |
| **NFR-COMPAT-03** | Go 版本 | 后端需 Go 1.22+（路由用 `METHOD /path/{id}` 语法） |
| **NFR-COMPAT-04** | 浏览器兼容 | 支持现代浏览器（Chrome/Firefox/Edge 最近 2 年版本），支持 SVG + fetch |

### 6.6 可观测性（NFR-OBS）

| 编号 | 需求 | 说明 |
|---|---|---|
| **NFR-OBS-01** | 日志输出 | Skynet 端通过 `skynet.error` 输出关键事件日志 |
| **NFR-OBS-02** | 后端日志 | Go 后端通过 `log.Printf` 输出启动/关闭/错误日志 |
| **NFR-OBS-03** | 健康检查 | `/healthz` 供外部探活 |

---

## 7. 验收标准

> 每个验收用例对应一个或多个功能需求，标记通过条件。

### 7.1 火焰图链路（FR-P）

| 用例 ID | 场景 | 步骤 | 预期结果 | 关联需求 |
|---|---|---|---|---|
| **AC-P-01** | 采样触发 | 在 snlua 服务调用 `firegraph.start_profile(30)` | 30s 后自动停止并上报，日志显示 reported | FR-P-01, FR-P-04 |
| **AC-P-02** | 自动采样 | 配置 `auto_profile_interval=300` 启动服务 | 每 5 分钟自动产生一条 profile 记录 | FR-P-02 |
| **AC-P-03** | 折叠栈格式 | 下载 folded.txt 检查内容 | 每行格式为 `a;b;c 123`，可被 FlameGraph.pl 解析 | FR-P-03, FR-P-09 |
| **AC-P-04** | 列表查询 | 上报 3 条 profile 后访问 `/api/profiles` | 返回 3 条摘要，不含 folded_text 大字段 | FR-P-06 |
| **AC-P-05** | speedscope 渲染 | 点击「查看火焰图」 | speedscope 在浏览器内正常渲染三视图，无控制台报错 | FR-P-07, FR-P-08 |
| **AC-P-06** | 上报重试 | 后端停止后触发采样上报 | Skynet 端日志显示重试 3 次后丢弃，业务不受影响 | NFR-REL-01 |
| **AC-P-07** | 数据量校验 | 上报 230 采样的 profile | 后端返回 `sample_count=230`，speedscope JSON 含对应 samples/weights | FR-P-05, FR-P-07 |

### 7.2 接口耗时链路（FR-T）

| 用例 ID | 场景 | 步骤 | 预期结果 | 关联需求 |
|---|---|---|---|---|
| **AC-T-01** | 埋点生效 | 启用 tracer 后向服务发送 100 条消息 | `SELECT count(*) FROM traces` ≥ 100 | FR-T-01, FR-T-04 |
| **AC-T-02** | 耗时准确 | handler 内 `skynet.sleep(100)`（1s） | trace 记录 cost_ms 在 950~1050 区间 | FR-T-01 |
| **AC-T-03** | cmd 标记 | handler 内调用 `firegraph.tag_cmd("Login")` | trace 记录 cmd="Login" | FR-T-02 |
| **AC-T-04** | 批量上报 | 触发 100 条消息后观察网络 | 累积 100 条立即触发一次上报 | FR-T-03 |
| **AC-T-05** | 聚合统计 | 查询 `/api/traces/stats` | 返回结构 `{service, cmd, count, ok_count, avg_ms, max_ms, min_ms, p50_ms, p95_ms, p99_ms}`，分位值合理 | FR-T-06 |
| **AC-T-06** | 时间序列 | 查询 `/api/traces/timeseries?bucket_sec=60` | 返回每桶 `{ts, count, avg_ms, p95_ms}`，桶数 = 时间范围/60 | FR-T-07 |
| **AC-T-07** | 统计卡片 | 打开 `/traces.html` | 5 张卡片正确显示总调用/平均/P95/P99/慢调用 | FR-T-08 |
| **AC-T-08** | 趋势图渲染 | 1h 范围查看图表 | SVG 折线图正常显示 3 条线（Avg/P95/P99），无控制台报错 | FR-T-09, FR-T-11 |
| **AC-T-09** | 慢调用高亮 | 制造 cost_ms=600 的慢调用 | 表格中该值显示为红色 | FR-T-10 |
| **AC-T-10** | 明细下钻 | 点击表格某行 | 展开明细表显示该接口最近 100 条 trace | FR-T-12 |
| **AC-T-11** | 解析容错 | 上报 200 条中夹 1 行格式错误 | 后端日志报错跳过该行，其余 199 条正常入库 | NFR-REL-02 |
| **AC-T-12** | ok 字段正确 | 上报 ok=true 与 ok=false 各 100 条 | stats 返回 ok_count 准确（100/100） | FR-T-06 |

### 7.3 系统管理（FR-S）

| 用例 ID | 场景 | 步骤 | 预期结果 | 关联需求 |
|---|---|---|---|---|
| **AC-S-01** | 健康检查 | `GET /healthz` | 返回 200 + "ok" | FR-S-01 |
| **AC-S-02** | 优雅关闭 | 启动后发送 SIGINT | 5s 内退出，日志输出 "bye" | FR-S-04 |
| **AC-S-03** | 配置加载 | 用自定义 yaml 启动 | 监听地址/DB 路径按配置生效 | FR-S-02 |
| **AC-S-04** | 首页可访问 | 浏览器访问 `/` | 显示首页三张功能卡片 | FR-S-05 |

### 7.4 非功能验收

| 用例 ID | 场景 | 预期结果 | 关联需求 |
|---|---|---|---|
| **AC-NFR-01** | 单二进制 | `go build` 产出单一可执行文件，无 .so/.dll 依赖 | NFR-MAINT-01, NFR-MAINT-02 |
| **AC-NFR-02** | 前端离线 | 断网情况下打开浏览器，所有页面正常工作（speedscope 已预下载） | NFR-MAINT-03, G-5 |
| **AC-NFR-03** | body 限制 | 上报 33MB profile | 返回 413 错误 | NFR-SEC-02 |
| **AC-NFR-04** | 批量入库性能 | 上报 1000 条 trace | 入库 < 1s | NFR-PERF-04 |
| **AC-NFR-05** | 跨平台编译 | `CGO_ENABLED=0 GOOS=linux go build` 成功 | NFR-MAINT-02 |

---

## 8. 项目范围

### 8.1 MVP 范围（v1.0，已实现）

- ✅ 火焰图核心链路：采样 → 上报 → 存储 → speedscope 查看
- ✅ 接口耗时埋点：dispatch 包装 → 批量上报 → 聚合统计 → 趋势图
- ✅ 内置采样器（debug.sethook）
- ✅ SQLite 持久化 + 自动过期
- ✅ 前端三页 UI（首页/火焰图/接口耗时）

### 8.2 v1.x 范围（计划）

- 🔲 swt 适配器实际接入（当前为示意代码）
- 🔲 数据自动过期定时任务（当前仅提供 store 层方法，未接入定时器）
- 🔲 单元测试 + 集成测试

### 8.3 v2+ 范围（非目标，未来考虑）

- 🔲 历史对比（Differential FlameGraph）
- 🔲 多节点聚合查询
- 🔲 告警（P95 超阈值 webhook）
- 🔲 鉴权
- 🔲 实时观测（WebSocket 推送）
- 🔲 服务拓扑图

---

## 9. 假设与约束

### 9.1 假设

1. **部署环境**：Skynet 服务器与 Go 后端均在 Linux 运行；开发可在 Windows。
2. **网络**：Skynet 服务器与 Go 后端网络可达，HTTP 上报无防火墙阻拦。
3. **数据量**：单服务日均 trace 量在百万级以内，SQLite + 索引可承载。
4. **Skynet 版本**：内置采样器对版本无要求；接入 swt 需 skynet 源码应用 patch。
5. **浏览器**：用户使用现代浏览器，支持 SVG + fetch + ES6。

### 9.2 约束

1. **无 CGO**：后端必须 `CGO_ENABLED=0` 可编译，禁止引入 CGO 依赖。
2. **无外部 DB**：不引入 MySQL/PostgreSQL/Redis，仅用 SQLite。
3. **无前端构建链**：不引入 npm/webpack/vite，前端纯静态。
4. **无 CDN 依赖**：speedscope 必须离线托管，不引用任何 CDN。
5. **业务零改动**：接入仅通过 skynet preload 配置，禁止要求业务代码改动。

### 9.3 已知风险

| 风险 | 影响 | 缓解措施 |
|---|---|---|
| 内置采样器只能采样当前协程 | 跨协程业务漏采 | 文档明确限制，提供 swt 升级路径 |
| SQLite 分位数内存计算 | 百万级数据查询慢 | 文档标注限制，提供预聚合优化方向 |
| swt 维护活跃度不确定 | swt 适配可能失效 | 内置采样器作为兜底，不强制依赖 swt |
| trace 上报对业务性能影响 | 高 QPS 场景开销累积 | 批量上报 + 异步发送，生产前压测 |

---

## 10. 附录：术语表

| 术语 | 含义 |
|---|---|
| Skynet | cloudwu/skynet，C 实现的 actor 模型游戏服务器框架 |
| snlua | skynet 中的 Lua 服务（actor），每个服务独立 Lua VM |
| dispatch | skynet 消息分发注册函数 |
| proto | 协议名（lua/text/response 等） |
| session | skynet 消息会话 ID |
| Folded Stacks | 折叠栈格式：`a;b;c 123`，业界标准 |
| speedscope | jlfwong/speedscope，纯浏览器火焰图查看器 |
| swt | lsg2020/swt，Skynet Lua profiler |
| WAL | SQLite Write-Ahead Logging |
| NDJSON | Newline-Delimited JSON，每行一个 JSON 对象 |
| P50/P95/P99 | 50/95/99 百分位数 |
| preload | skynet 配置项，snlua 服务启动时执行的 Lua 脚本 |

---

**文档结束。** 本文是 firegraph 项目的需求基线，后续需求变更需更新本文档并升级版本号。
