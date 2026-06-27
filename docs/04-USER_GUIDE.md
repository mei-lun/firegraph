# firegraph 使用教程

| 项 | 内容 |
|---|---|
| 文档版本 | v1.0 |
| 适用版本 | firegraph v1.0 |
| 目标读者 | 服务端开发 / 运维工程师 / 测试工程师 |
| 阅读建议 | 新手按顺序通读；老手直接跳到 [§4 核心功能操作指南](#4-核心功能操作指南) |
| 配套文档 | [需求文档](./01-REQUIREMENTS.md)、[需求分析](./02-REQUIREMENTS_ANALYSIS.md)、[代码设计](./03-CODE_DESIGN.md)、[技术设计](./TECHNICAL_DESIGN.md) |

---

## 目录

1. [产品介绍](#1-产品介绍)
2. [系统环境要求](#2-系统环境要求)
3. [安装与配置](#3-安装与配置)
4. [核心功能操作指南](#4-核心功能操作指南)
5. [进阶用法](#5-进阶用法)
6. [常见问题解答（FAQ）](#6-常见问题解答faq)
7. [故障排除](#7-故障排除)
8. [附录](#8-附录)

---

## 1. 产品介绍

### 1.1 firegraph 是什么

firegraph 是一款面向 **Skynet + Lua** 游戏服务器的性能监测工具，提供两大核心能力：

| 能力 | 描述 | 输出形态 |
|---|---|---|
| **CPU 火焰图** | 采样 Lua 运行时调用栈，可视化定位 CPU 热点函数 | 浏览器内交互式火焰图（speedscope） |
| **接口耗时统计** | 自动埋点每条消息处理耗时，按 service/cmd 聚合 | 分位数（P50/P95/P99）+ 趋势图 + 明细 |

### 1.2 适用场景

- 开发期：定位 CPU 密集型函数、验证优化效果
- 测试期：压测后查看接口耗时分布、版本回归对比
- 运维期：定期巡检、慢接口排查、性能趋势监控

### 1.3 产品架构一览

```
┌─────────────────┐  HTTP 上报   ┌──────────────────┐  HTTP   ┌──────────────┐
│ Skynet 服务器   │ ──────────► │ firegraph 后端   │ ◄────── │ 运维浏览器   │
│ (Lua 采集端)    │             │ (Go + SQLite)    │         │ (UI + 火焰图)│
└─────────────────┘             └──────────────────┘         └──────────────┘
```

- **Skynet 端**：Lua 模块，通过 preload 自动注入，业务零改动
- **后端**：Go 单二进制 + SQLite，无外部依赖
- **前端**：原生 JS + speedscope 离线包，无 CDN 依赖

### 1.4 核心特性

- ✅ **无侵入接入**：业务代码零改动，仅配置 skynet preload
- ✅ **单二进制部署**：后端一个可执行文件，无外部 DB/中间件
- ✅ **内网零依赖**：前端无 CDN，离线环境可用
- ✅ **轻量开销**：采样对业务 CPU 开销 < 5%；埋点对单消息延迟增加 < 100μs

---

## 2. 系统环境要求

### 2.1 后端环境

| 项 | 要求 | 验证命令 |
|---|---|---|
| 操作系统 | Linux x86_64（生产）/ Windows / macOS（开发） | `uname -a` |
| Go 版本 | **1.22 或以上**（路由用 `METHOD /path/{id}` 语法） | `go version` |
| 磁盘空间 | ≥ 1GB（SQLite 数据文件 + speedscope 离线包） | `df -h` |
| 内存 | ≥ 256MB（小数据量场景） | `free -h` |
| 网络 | Skynet 服务器到后端 HTTP 可达；浏览器到后端 HTTP 可达 | `curl http://后端:8080/healthz` |

> **注意**：Go 必须支持 1.22+ 的 `http.ServeMux` 路由语法。低版本 Go 编译会报错。

### 2.2 Skynet 端环境

| 项 | 要求 | 验证方式 |
|---|---|---|
| Skynet | cloudwu/skynet 任意版本（内置采样器无版本要求） | `skynet --version` 或源码版本 |
| Lua 版本 | Lua 5.3 / 5.4 | skynet 编译配置 |
| swt（可选） | lsg2020/swt，需 skynet 应用 commit `4ace42e8` patch | 见 [§5.2 swt 接入](#52-swt-适配器接入可选) |

### 2.3 浏览器环境

| 项 | 要求 |
|---|---|
| 浏览器 | Chrome / Firefox / Edge 最近 2 年版本 |
| 功能支持 | SVG 渲染、fetch API、ES6 语法 |
| 网络 | 能访问后端 HTTP 端口 |

### 2.4 端口与防火墙

| 端口 | 用途 | 默认 | 是否可改 |
|---|---|---|---|
| 8080 | 后端 HTTP | 是 | 配置 `server.addr` |
| 无 | Skynet → 后端 出站 | - | 确保 Skynet 能访问后端 8080 |

---

## 3. 安装与配置

### 3.1 后端安装

#### 步骤 1：获取源码

```bash
# 假设源码已克隆到本地
cd /path/to/firegraph
```

#### 步骤 2：下载依赖

```bash
go mod tidy
```

**验证标准**：无报错输出，`go.mod` 包含 `modernc.org/sqlite` 与 `gopkg.in/yaml.v3`。

#### 步骤 3：构建二进制

**方式 A：使用构建脚本（推荐）**

```bash
bash scripts/build.sh
```

构建参数说明：
- `CGO_ENABLED=0`：纯 Go 编译，无 C 依赖
- `-trimpath`：去除路径信息（可重现构建）
- `-ldflags "-s -w"`：去除调试符号，减小体积

**方式 B：手动构建**

```bash
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o bin/firegraph ./cmd/firegraph
```

**验证标准**：

```bash
ls -lh bin/firegraph
# 应输出类似：-rwxr-xr-x 1 user user 15M Jun 28 10:00 bin/firegraph

# 跨平台编译验证（Linux 目标）
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bin/firegraph-linux ./cmd/firegraph
file bin/firegraph-linux
# 应输出：ELF 64-bit LSB executable, x86-64...
```

#### 步骤 4：下载 speedscope 离线包

```bash
bash scripts/fetch_assets.sh
```

**验证标准**：

```bash
ls web/assets/vendor/speedscope/index.html
# 应输出该文件路径，无 "No such file" 错误
```

> **注意**：此步骤需联网下载 speedscope v1.25.0 release zip。若内网部署，可在有网机器执行后，将 `web/assets/vendor/speedscope/` 目录整体拷贝到内网。

#### 步骤 5：准备配置文件

```bash
cp configs/firegraph.yaml configs/firegraph.prod.yaml
```

编辑 `configs/firegraph.prod.yaml`：

```yaml
server:
  addr: ":8080"              # 监听地址，:8080 表示所有网卡
  web_dir: "./web"           # 前端静态资源目录

store:
  dsn: "firegraph.db"        # SQLite 文件路径
  retention_days: 7          # 数据保留天数（0=永久）
```

**配置项详解**：

| 配置项 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `server.addr` | string | `:8080` | HTTP 监听地址。格式 `host:port`，省略 host 监听所有网卡 |
| `server.web_dir` | string | `./web` | 前端静态资源目录路径。相对路径相对于二进制工作目录 |
| `store.dsn` | string | `firegraph.db` | SQLite 数据库文件路径 |
| `store.retention_days` | int | `7` | 数据保留天数。0 = 永久保留；>0 自动清理过期数据 |

> **注意**：`web_dir` 路径相对于**启动二进制时的工作目录**，不是二进制所在目录。建议用绝对路径或固定工作目录启动。

#### 步骤 6：启动后端

```bash
./bin/firegraph -config configs/firegraph.prod.yaml
```

启动成功日志示例：

```
2026/06/28 10:00:00 firegraph starting on :8080, db=firegraph.db
2026/06/28 10:00:00 firegraph serving
```

**验证标准**：

```bash
# 健康检查
curl http://localhost:8080/healthz
# 应输出：ok

# 浏览器访问首页
# 打开 http://localhost:8080/
# 应显示三张功能卡片：火焰图 / 接口耗时 / 健康检查
```

#### 步骤 7：配置开机自启（生产环境可选）

创建 systemd 服务文件 `/etc/systemd/system/firegraph.service`：

```ini
[Unit]
Description=firegraph performance monitor
After=network.target

[Service]
Type=simple
User=firegraph
WorkingDirectory=/opt/firegraph
ExecStart=/opt/firegraph/bin/firegraph -config /opt/firegraph/configs/firegraph.prod.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

启用并启动：

```bash
sudo systemctl daemon-reload
sudo systemctl enable firegraph
sudo systemctl start firegraph
sudo systemctl status firegraph
```

**验证标准**：`systemctl status firegraph` 显示 `active (running)`。

---

### 3.2 Skynet 端接入

#### 步骤 1：部署 Lua 模块

将 `skynet-agent/lua/` 目录拷贝到 Skynet 服务器：

```bash
# 假设 skynet 根目录为 /opt/skynet
cp -r skynet-agent/lua /opt/skynet/firegraph-agent
```

目录结构：

```
/opt/skynet/firegraph-agent/
├── preload.lua
└── firegraph/
    ├── init.lua
    ├── swt_bridge.lua
    ├── tracer.lua
    └── reporter.lua
```

#### 步骤 2：修改 skynet 配置

在 skynet 主配置文件（如 `config`）中添加：

```lua
-- lua_path 加入 firegraph 模块路径
lua_path = "./?.lua;./firegraph-agent/?.lua;./firegraph-agent/?/init.lua;" .. lua_path

-- preload 指定 firegraph 的 preload.lua
preload = "./firegraph-agent/preload.lua"

-- firegraph 配置（自定义环境变量）
firegraph_host = "127.0.0.1"                    -- 后端地址
firegraph_port = 8080                            -- 后端端口
service_name = "login"                           -- 当前服务名（每个 snlua 服务不同）
node_name    = "node1"                           -- 节点名
firegraph_auto_profile_interval = 0              -- 自动采样间隔（秒），0=不自动
firegraph_auto_profile_duration  = 30            -- 每次采样持续秒
firegraph_enable_tracer = true                   -- 启用接口埋点
```

> **注意**：`service_name` 应与 snlua 服务名一致。如果多个 snlua 服务共用同一 config，需要通过其他机制（如 skynet 启动参数）区分。

#### 步骤 3：重启 skynet 服务

```bash
# 重启 skynet
kill -SIGUSR1 $(cat skynet.pid)   # 或其他重启方式
```

**验证标准**：

```bash
# 1. 检查 snlua 服务启动日志，应无 firegraph 相关报错
tail -f skynet.log | grep -i firegraph

# 2. 在后端查看是否有 trace 上报（启用 tracer 后 5 秒内应有数据）
sqlite3 firegraph.db "SELECT count(*) FROM traces;"
# 应输出 > 0 的数字
```

---

### 3.3 快速验证（端到端冒烟测试）

完成 §3.1 和 §3.2 后，执行以下冒烟测试：

#### 验证 1：火焰图链路

在 snlua 服务中执行（可通过 skynet debug console）：

```lua
local firegraph = require "firegraph"
firegraph.start_profile(10)   -- 采样 10 秒
```

10 秒后：

```bash
# 后端日志应显示上报成功
tail -f firegraph.log | grep "profile"

# 查询 profile 列表
curl http://localhost:8080/api/profiles | python -m json.tool
# 应返回包含刚上报 profile 的列表

# 浏览器打开 http://localhost:8080/profiles.html
# 应看到列表中有一条记录，点击「查看火焰图」应正常显示
```

#### 验证 2：接口耗时链路

启用 `firegraph_enable_tracer = true` 并向服务发送若干消息后：

```bash
# 查询聚合统计
curl "http://localhost:8080/api/traces/stats" | python -m json.tool
# 应返回 [{service, cmd, count, ok_count, avg_ms, p50_ms, p95_ms, p99_ms, ...}]

# 查询时间序列
curl "http://localhost:8080/api/traces/timeseries?bucket_sec=60" | python -m json.tool
# 应返回 [{ts, count, avg_ms, p95_ms}, ...]

# 浏览器打开 http://localhost:8080/traces.html
# 应看到统计卡片、趋势图、表格
```

**冒烟测试通过条件**：以上 4 个 curl 命令均返回有效 JSON，浏览器页面正常渲染。

---

## 4. 核心功能操作指南

### 4.1 火焰图：CPU 热点定位

#### 4.1.1 手动触发采样

适用场景：开发期定位 CPU 热点。

**方式 A：业务代码主动调用**

```lua
-- 在需要分析的代码段前后调用
local firegraph = require "firegraph"
firegraph.start_profile(30)   -- 采样 30 秒
-- 业务正常运行...
-- 30 秒后自动停止并上报
```

**方式 B：通过 skynet debug console 触发**

```bash
# 进入 skynet debug console
nc 127.0.0.1 8000
> debug login_service_addr
> inject firegraph.start_profile(30)
```

**验证标准**：
- snlua 日志显示 `firegraph profile started, duration=30`
- 30 秒后日志显示 `firegraph profile reported, samples=XXX`

#### 4.1.2 自动周期采样

适用场景：生产期定期巡检。

修改 skynet config：

```lua
firegraph_auto_profile_interval = 300   -- 每 5 分钟自动采样
firegraph_auto_profile_duration  = 30   -- 每次采样 30 秒
```

重启 skynet 后，snlua 服务会自动周期性采样并上报。

**验证标准**：

```bash
# 等待 10 分钟后查询 profile 列表
curl http://localhost:8080/api/profiles?limit=10 | python -m json.tool
# 应看到约 2 条新 profile（10 分钟 / 5 分钟 = 2 次）
```

#### 4.1.3 浏览火焰图

1. 打开浏览器访问 `http://后端:8080/profiles.html`
2. 在筛选框中输入 `service` 或 `node` 过滤
3. 点击列表中某条记录右侧的「查看火焰图」按钮
4. speedscope 在新标签页打开，提供三种视图：

| 视图 | 用途 | 推荐场景 |
|---|---|---|
| **Time Order** | 按采样时间顺序展示 | 查看热点随时间变化 |
| **Left Heavy** | 按调用栈聚合，宽度=CPU 占比 | **定位热点函数首选** |
| **Sandwich** | 按函数聚合，显示 callers/callees | 分析某函数的调用关系 |

**操作技巧**：
- 在 Left Heavy 视图中，**最宽的函数帧**就是 CPU 热点
- 点击某帧可放大该子树
- 右上角搜索框可按函数名过滤
- 鼠标悬停显示函数名 + 采样数 + 占比

#### 4.1.4 下载折叠栈离线分析

适用场景：用 FlameGraph.pl 生成静态 SVG，或做版本对比。

```bash
# 下载某条 profile 的原始折叠栈
curl http://localhost:8080/api/profiles/1/folded.txt -o profile_1.folded

# 检查格式
head -5 profile_1.folded
# 应输出类似：
# main;skynet.dispatch;login_handler;check_token 50
# main;skynet.dispatch;login_handler;db_query 150

# 用 FlameGraph.pl 生成 SVG（需先安装）
git clone https://github.com/brendangregg/FlameGraph
./FlameGraph/flamegraph.pl profile_1.folded > profile_1.svg
```

**验证标准**：`profile_1.svg` 可在浏览器打开，显示静态火焰图。

---

### 4.2 接口耗时：慢接口排查

#### 4.2.1 启用埋点

确保 skynet config 中：

```lua
firegraph_enable_tracer = true
```

重启 skynet 后自动生效，业务代码无需任何改动。

**验证标准**：

```bash
# 向服务发送几条消息后查询
sqlite3 firegraph.db "SELECT count(*) FROM traces;"
# 应输出 > 0
```

#### 4.2.2 业务侧标记 cmd（推荐）

默认情况下，`cmd` 字段为 skynet 协议名（如 `lua`）。为获得有意义的统计，业务应在 handler 内调用 `tag_cmd`：

```lua
local firegraph = require "firegraph"

skynet.dispatch("lua", function(session, source, cmd, ...)
    firegraph.tag_cmd(cmd)          -- 用业务协议的 cmd 字段
    -- 业务逻辑
    if cmd == "Login" then
        -- ...
    elseif cmd == "Logout" then
        -- ...
    end
end)
```

> **注意**：`tag_cmd` 必须在 handler 协程内调用，标记的是当前消息。`tracer` 用 `coroutine.running()` 做 key 存储，避免多协程并发污染。

#### 4.2.3 查看接口耗时面板

1. 打开浏览器访问 `http://后端:8080/traces.html`
2. 页面布局：

```
┌─────────────────────────────────────────────────────────────┐
│ [Service: ___] [Cmd: ___]  [1h] [6h] [24h] [7d]  [刷新]    │  ← 筛选区
├─────────────────────────────────────────────────────────────┤
│ [总调用]  [平均耗时]  [P95]  [P99]  [慢调用]               │  ← 5 张统计卡
├─────────────────────────────────────────────────────────────┤
│                                                             │
│           [SVG 趋势折线图：Avg/P95/P99]                     │  ← 趋势图
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ Service │ Cmd    │ Count │ Ok  │ Avg  │ P95  │ P99  │ 操作 │  ← 表格
│ login   │ Login  │  46   │ 40  │ 196  │ 330  │ 342  │明细 │
│ login   │ Logout │  43   │ 35  │ 209  │ 338  │ 342  │明细 │
└─────────────────────────────────────────────────────────────┘
```

3. **筛选**：在 Service / Cmd 输入框输入关键词（支持部分匹配），点击「刷新」或回车
4. **时间范围**：点击 `1h` / `6h` / `24h` / `7d` 切换时间范围，趋势图自动调整桶粒度：
   - 1h → 60 秒/桶
   - 6h → 5 分钟/桶
   - 24h → 30 分钟/桶
   - 7d → 2 小时/桶

#### 4.2.4 排查慢接口

**典型排查流程**：

1. **玩家反馈"登录卡"**
2. 打开 `/traces.html`，Service 框输入 `login`，时间范围选 `1h`
3. 查看表格：
   - 若 `Login` 的 `P95` > 500ms（红色高亮）→ 确认慢
   - 若 `Ok` < `Count` → 存在失败
4. 查看趋势图：
   - 若 P95 在某时刻突然升高 → 可能是突发事件（如 DB 慢查询）
   - 若 P95 持续偏高 → 可能是代码问题（如 N+1 查询）
5. 点击「明细」按钮，查看该接口最近 100 条 trace
6. 找出 `cost_ms` 显著高的记录，对照时间点排查业务日志

**颜色含义**：
- 表格中 `Avg` / `P95` / `P99` 数值：
  - ≥ 500 ms → **红色**（严重慢）
  - ≥ 200 ms → **橙色**（偏慢）
  - < 200 ms → 默认色（正常）

#### 4.2.5 明细下钻

点击表格行的「明细」按钮，展开该接口最近 100 条 trace：

| 字段 | 说明 |
|---|---|
| ts | 消息处理时间戳（可读时间） |
| service | snlua 服务名 |
| cmd | 命令名 |
| session | skynet session id |
| cost_ms | 处理耗时（毫秒） |
| ok | ✓ 成功 / ✗ 失败 |

**用途**：
- 找出最慢的几条 trace，定位偶发抖动
- 查看失败 trace 的 session id，对照业务日志排查

---

### 4.3 系统管理

#### 4.3.1 健康检查

```bash
curl http://后端:8080/healthz
# 输出：ok（HTTP 200）
```

可用于负载均衡探活或监控系统检查。

#### 4.3.2 优雅关闭

```bash
# 发送 SIGINT 或 SIGTERM
kill -SIGINT $(pgrep firegraph)

# 后端日志应显示：
# firegraph shutting down...
# firegraph bye
```

**优雅关闭行为**：
- 拒绝新请求
- 等待在途请求完成（最多 5 秒）
- 关闭 SQLite 连接
- 退出进程

#### 4.3.3 数据备份

SQLite 单文件备份，停服或热备均可：

```bash
# 方式 A：停服后拷贝（最简单）
systemctl stop firegraph
cp firegraph.db firegraph.db.bak.$(date +%Y%m%d)
systemctl start firegraph

# 方式 B：在线热备（不停服，用 sqlite3 .backup 命令）
sqlite3 firegraph.db ".backup firegraph.db.bak.$(date +%Y%m%d)"
```

**验证标准**：

```bash
# 校验备份文件
sqlite3 firegraph.db.bak.20260628 "SELECT count(*) FROM traces;"
# 应输出与生产 DB 相近的数字
```

---

## 5. 进阶用法

### 5.1 多服务接入

每个 snlua 服务独立接入，只需在各自的 skynet config 中设置不同的 `service_name`：

```lua
# login 服务
service_name = "login"

# game 服务
service_name = "game"

# chat 服务
service_name = "chat"
```

后端会按 service 维度聚合统计，前端可按 service 过滤。

### 5.2 swt 适配器接入（可选）

适用场景：需要全服务精确采样（跨协程），且内置采样器覆盖不足。

#### 步骤 1：准备 swt

参考 [lsg2020/swt](https://github.com/lsg2020/swt) 项目，需在 skynet 源码应用 commit `4ace42e8` 的 patch，重新编译 skynet。

#### 步骤 2：调整 swt_bridge.lua

编辑 `skynet-agent/lua/firegraph/swt_bridge.lua` 中的 swt API 调用，根据 swt 实际版本调整：

```lua
function M.start(duration_sec)
    local ok, swt = pcall(require, "swt")
    if ok and swt and swt.start_profile then
        M._use_swt = true
        M._swt = swt
        -- ⚠️ 以下 API 需根据 swt 实际版本调整
        swt.start_profile(duration_sec)
    else
        -- 回退到内置采样器
        M._use_swt = false
        debug.sethook(hook_fn, "l", line_threshold)
    end
end
```

#### 步骤 3：验证

```lua
local firegraph = require "firegraph"
firegraph.start_profile(30)
-- 日志应显示：firegraph using swt sampler
```

> **注意**：swt 的具体 API 可能随版本变化。若 swt 接入失败，会自动回退到内置采样器，不影响业务。

### 5.3 离线生成火焰图 SVG

适用场景：版本对比、归档报告。

```bash
# 下载两条 profile 的折叠栈
curl http://localhost:8080/api/profiles/1/folded.txt -o v1.folded
curl http://localhost:8080/api/profiles/2/folded.txt -o v2.folded

# 生成单条火焰图
./flamegraph.pl v1.folded > v1.svg

# 生成对比火焰图（红=增加，蓝=减少）
./difffolded.pl v1.folded v2.folded | ./flamegraph.pl > diff.svg
```

### 5.4 自定义采样阈值

默认每 5000 行 Lua 指令采样一次。如需调整，编辑 `swt_bridge.lua`：

```lua
local line_threshold = 5000   -- 调大 = 开销小但精度低；调小 = 开销大但精度高
```

**权衡建议**：
- 开发期：`1000`（精度高，开销可接受）
- 生产期：`5000`（默认，平衡）
- 高 QPS 场景：`10000`（降低开销）

### 5.5 调整 trace 上批参数

默认累积 100 条或 5 秒触发上报。如需调整，编辑 `tracer.lua`：

```lua
local FLUSH_THRESHOLD = 100       -- 累积条数
local FLUSH_INTERVAL  = 5 * 100   -- 时间间隔（1/100 秒）
```

**权衡建议**：
- 高 QPS 场景：调大 `FLUSH_THRESHOLD`（如 500）减少上报次数
- 低延迟场景：调小 `FLUSH_INTERVAL`（如 200 = 2 秒）降低数据延迟

---

## 6. 常见问题解答（FAQ）

### Q1：firegraph 会影响业务性能吗？

**A**：影响很小，但需注意：

| 操作 | 开销 | 说明 |
|---|---|---|
| 采样（开启时） | CPU +5% 以内 | 仅采样期间，关闭后零开销 |
| 接口埋点 | 单消息 +100μs 以内 | 持续开销，高 QPS 需压测 |
| 上报 | 异步，不阻塞 dispatch | `skynet.fork` 异步发送 |

**建议**：
- 生产环境开启埋点前，先在压测环境验证
- 高 QPS 服务（>1万 QPS）可适当调大 `FLUSH_THRESHOLD`
- 采样仅在需要时开启，不要长期持续采样

### Q2：内置采样器为什么采不到某些协程的数据？

**A**：内置采样器基于 `debug.sethook`，只能采样设置了 hook 的协程。Skynet snlua 服务是多协程的，跨协程采样不完整。

**影响**：
- CPU 密集型业务（通常集中在少数协程）：足够
- IO 密集型跨协程业务：可能漏采

**解决**：接入 swt 获得全服务精确采样，见 [§5.2](#52-swt-适配器接入可选)。

### Q3：speedscope 打不开或显示白屏？

**A**：常见原因：

1. **未下载 speedscope 离线包**
   ```bash
   ls web/assets/vendor/speedscope/index.html
   # 若不存在，执行：
   bash scripts/fetch_assets.sh
   ```

2. **后端响应未设置 CORS 头**
   ```bash
   curl -I http://localhost:8080/api/profiles/1/speedscope.json
   # 应包含：Access-Control-Allow-Origin: *
   ```

3. **浏览器控制台报错**
   - F12 打开控制台，查看 Network 与 Console 标签
   - 常见：404（路径错误）、CORS 错误（后端配置问题）

### Q4：trace 数据看不到 cmd，全是 "lua"？

**A**：业务未调用 `firegraph.tag_cmd(cmd)`。默认 `cmd` 字段为 skynet 协议名（`lua`/`text`/`response`）。

**解决**：在 dispatch handler 内调用：

```lua
skynet.dispatch("lua", function(session, source, cmd, ...)
    firegraph.tag_cmd(cmd)   -- 加这一行
    -- 业务逻辑
end)
```

### Q5：数据库文件越来越大怎么办？

**A**：

1. **配置自动过期**：`retention_days: 7` 会自动清理 7 天前的数据
   > ⚠️ 注意：v1.0 的自动过期定时器尚未接入，需手动清理或等待 v1.1

2. **手动清理**：
   ```bash
   sqlite3 firegraph.db "DELETE FROM traces WHERE ts < strftime('%s', 'now', '-7 days');"
   sqlite3 firegraph.db "DELETE FROM profiles WHERE sampled_at < strftime('%s', 'now', '-7 days');"
   sqlite3 firegraph.db "VACUUM;"   # 回收空间
   ```

3. **永久保留**：设置 `retention_days: 0`

### Q6：可以同时监测多个 Skynet 节点吗？

**A**：可以。每个节点的 snlua 服务都配置 firegraph 上报到同一个后端，后端按 `service_name` + `node_name` 区分。查询时可通过 service 过滤。

### Q7：可以在 Windows 上运行后端吗？

**A**：可以开发调试，但生产建议 Linux。

```powershell
# Windows 编译
$env:CGO_ENABLED = "0"
go build -o bin/firegraph.exe ./cmd/firegraph

# 运行
.\bin\firegraph.exe -config configs\firegraph.yaml
```

### Q8：如何查看数据库中的数据？

**A**：用 sqlite3 命令行或 GUI 工具：

```bash
# 命令行
sqlite3 firegraph.db
sqlite> .tables
sqlite> SELECT count(*) FROM traces;
sqlite> SELECT service, cmd, count(*) FROM traces GROUP BY service, cmd;

# GUI 工具推荐：DB Browser for SQLite、DBeaver
```

### Q9：上报失败会丢失数据吗？

**A**：会。当前设计是"重试 3 次后丢弃"，不缓存数据。理由：
- profile 是一次性采样数据，丢失可重新采样
- trace 是持续上报，偶尔丢失不影响整体统计
- 缓存重放会增加复杂度

**生产建议**：确保后端高可用（监控 + 自动重启），减少上报失败概率。

### Q10：可以禁用某个功能吗？

**A**：可以：

```lua
-- 仅用火焰图，不埋点
firegraph_enable_tracer = false

-- 仅埋点，不自动采样
firegraph_auto_profile_interval = 0
firegraph_enable_tracer = true
```

---

## 7. 故障排除

### 7.1 后端启动失败

#### 症状 1：端口被占用

```
listen tcp :8080: bind: address already in use
```

**排查**：

```bash
# Linux
sudo lsof -i :8080
# 或
sudo netstat -tlnp | grep 8080

# Windows
Get-NetTCPConnection -LocalPort 8080
```

**解决**：
- 停止占用进程：`kill -9 <PID>`
- 或修改配置 `server.addr: ":8081"`

#### 症状 2：数据库打开失败

```
open firegraph.db: no such file or directory
```

**排查**：检查 `store.dsn` 路径所在目录是否存在。

**解决**：
```bash
mkdir -p /opt/firegraph/data
# 修改配置
# store.dsn: "/opt/firegraph/data/firegraph.db"
```

#### 症状 3：权限不足

```
permission denied
```

**解决**：
```bash
chown -R firegraph:firegraph /opt/firegraph
chmod 755 /opt/firegraph/bin/firegraph
```

### 7.2 Skynet 端问题

#### 症状 1：preload 加载失败

snlua 启动日志报错：

```
error: module 'firegraph' not found
```

**排查**：
1. 检查 `lua_path` 是否包含 firegraph 模块路径
2. 检查文件是否存在：

```bash
ls /opt/skynet/firegraph-agent/firegraph/init.lua
```

**解决**：修正 `lua_path` 配置：

```lua
lua_path = "./?.lua;./firegraph-agent/?.lua;./firegraph-agent/?/init.lua;" .. lua_path
```

#### 症状 2：上报失败

snlua 日志报错：

```
firegraph report failed: connection refused
```

**排查**：
```bash
# 在 skynet 服务器上测试后端连通性
curl http://后端:8080/healthz
```

**解决**：
- 确认后端已启动
- 确认 `firegraph_host` / `firegraph_port` 配置正确
- 确认防火墙未阻拦

#### 症状 3：trace 数据全是 proto 名

**症状**：`cmd` 字段全是 `lua` / `text`，看不到真实命令名。

**原因**：业务未调用 `firegraph.tag_cmd(cmd)`。

**解决**：见 [Q4](#q4trace-数据看不到-cmd全是-lua)。

#### 症状 4：tracer 安装后业务消息处理报错

**症状**：启用 tracer 后业务 handler 抛错。

**排查**：tracer 用 `pcall` 包裹业务 handler，错误会重新抛出，不影响 skynet 原行为。检查业务代码本身是否有问题。

**验证**：临时禁用 tracer（`firegraph_enable_tracer = false`）确认是否是 tracer 引入的问题。

### 7.3 前端问题

#### 症状 1：页面 404

**排查**：
```bash
curl http://localhost:8080/
# 应返回 HTML 内容
```

**解决**：
- 检查 `server.web_dir` 配置是否指向正确的 web 目录
- 检查工作目录是否正确

#### 症状 2：speedscope 加载失败

见 [Q3](#q3speedscope-打不开或显示白屏)。

#### 症状 3：趋势图不显示

**排查**：
1. F12 打开浏览器控制台，查看 Network 标签
2. 检查 `/api/traces/timeseries` 请求是否返回 200
3. 检查响应是否为有效 JSON 数组

**常见原因**：
- 该时间范围内无数据 → 表格也会显示"暂无数据"
- `bucket_sec` 参数缺失 → 后端用默认值 60

#### 症状 4：统计数据为 0

**排查**：
```bash
sqlite3 firegraph.db "SELECT count(*) FROM traces;"
```

- 若为 0：tracer 未生效或上报失败，见 [§7.2](#72-skynet-端问题)
- 若 > 0 但前端显示 0：检查时间范围是否选错（如选了 1h 但数据在 24h 前）

### 7.4 性能问题

#### 症状 1：查询响应慢

**现象**：`/api/traces/stats` 响应超过 500ms。

**排查**：
```bash
# 查询数据量
sqlite3 firegraph.db "SELECT count(*) FROM traces;"

# 查询执行计划
sqlite3 firegraph.db "EXPLAIN QUERY PLAN SELECT service, cmd, count(*) FROM traces GROUP BY service, cmd;"
```

**解决**：
- 数据量 < 100 万：检查索引是否创建（`idx_traces_lookup`）
- 数据量 > 100 万：分位数内存计算变慢，考虑：
  - 缩短 `retention_days`
  - 定期 VACUUM
  - 等待 v1.2 预聚合优化

#### 症状 2：后端内存占用高

**原因**：分位数计算需加载排序数组到内存。

**解决**：
- 缩短 `retention_days`
- 限制查询时间范围（用 1h 而非 7d）
- 增加服务器内存

#### 症状 3：Skynet 服务 CPU 飙高

**排查**：临时禁用 firegraph 确认是否是 firegraph 引起：

```lua
firegraph_enable_tracer = false
firegraph_auto_profile_interval = 0
```

**若确认是 firegraph 引起**：
- 降低采样频率（增大 `line_threshold`）
- 增大 `FLUSH_THRESHOLD` 减少上报次数
- 联系开发者优化

### 7.5 数据问题

#### 症状 1：ok_count 始终为 0

**原因**：v1.0 之前的 bug，`ok` 字段（boolean）被当 string 解析。

**解决**：升级到 v1.0+，已修复（`jsonGetBool` 优先解析 boolean）。

**验证**：
```bash
sqlite3 firegraph.db "SELECT cmd, count(*), sum(ok) FROM traces GROUP BY cmd;"
# sum(ok) 应 > 0
```

#### 症状 2：时间戳显示错误

**原因**：时区问题。firegraph 存储使用 unix 秒（UTC），前端按本地时区显示。

**解决**：检查浏览器时区设置。后端存储的时间戳是时区无关的。

---

## 8. 附录

### 8.1 命令速查表

| 操作 | 命令 |
|---|---|
| 构建后端 | `bash scripts/build.sh` |
| 下载 speedscope | `bash scripts/fetch_assets.sh` |
| 启动后端 | `./bin/firegraph -config configs/firegraph.yaml` |
| 健康检查 | `curl http://localhost:8080/healthz` |
| 查看 profile 列表 | `curl http://localhost:8080/api/profiles` |
| 查看 trace 统计 | `curl http://localhost:8080/api/traces/stats` |
| 查看时间序列 | `curl "http://localhost:8080/api/traces/timeseries?bucket_sec=60"` |
| 优雅关闭 | `kill -SIGINT $(pgrep firegraph)` |
| 数据库查询 | `sqlite3 firegraph.db "SELECT count(*) FROM traces;"` |
| 数据库备份 | `sqlite3 firegraph.db ".backup backup.db"` |
| 数据库清理 | `sqlite3 firegraph.db "DELETE FROM traces WHERE ts < strftime('%s','now','-7 days');"` |

### 8.2 关键文件清单

| 文件 | 用途 |
|---|---|
| `bin/firegraph` | 后端可执行文件 |
| `configs/firegraph.yaml` | 后端配置 |
| `firegraph.db` | SQLite 数据文件 |
| `firegraph.db-wal` | SQLite WAL 日志（运行时存在） |
| `firegraph.db-shm` | SQLite 共享内存（运行时存在） |
| `web/` | 前端静态资源目录 |
| `web/assets/vendor/speedscope/` | speedscope 离线包 |
| `skynet-agent/lua/` | Skynet 端 Lua 模块 |

### 8.3 关键参数速查

#### 后端配置（`firegraph.yaml`）

| 参数 | 默认值 | 说明 |
|---|---|---|
| `server.addr` | `:8080` | 监听地址 |
| `server.web_dir` | `./web` | 前端目录 |
| `store.dsn` | `firegraph.db` | 数据库路径 |
| `store.retention_days` | `7` | 保留天数 |

#### Skynet 配置（环境变量）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `firegraph_host` | `127.0.0.1` | 后端地址 |
| `firegraph_port` | `8080` | 后端端口 |
| `service_name` | `unknown` | 服务名 |
| `node_name` | `default` | 节点名 |
| `firegraph_auto_profile_interval` | `0` | 自动采样间隔（秒） |
| `firegraph_auto_profile_duration` | `30` | 每次采样持续秒 |
| `firegraph_enable_tracer` | `false` | 启用接口埋点 |

#### Skynet 端可调常量

| 常量 | 默认值 | 位置 | 说明 |
|---|---|---|---|
| `line_threshold` | `5000` | `swt_bridge.lua` | 采样间隔（行数） |
| `FLUSH_THRESHOLD` | `100` | `tracer.lua` | trace 上报条数阈值 |
| `FLUSH_INTERVAL` | `500`（5s） | `tracer.lua` | trace 上报时间阈值（1/100 秒） |

### 8.4 HTTP API 速查

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/healthz` | 健康检查 |
| POST | `/api/profiles/upload` | 上报折叠栈 |
| GET | `/api/profiles` | profile 列表 |
| GET | `/api/profiles/{id}` | profile 详情 |
| GET | `/api/profiles/{id}/speedscope.json` | speedscope JSON |
| GET | `/api/profiles/{id}/folded.txt` | 折叠栈下载 |
| POST | `/api/traces/batch` | 批量上报 trace（NDJSON） |
| GET | `/api/traces` | trace 明细 |
| GET | `/api/traces/stats` | trace 聚合统计 |
| GET | `/api/traces/timeseries` | trace 时间序列 |

### 8.5 验证标准汇总

| 场景 | 验证方法 | 成功标准 |
|---|---|---|
| 后端启动 | `curl /healthz` | 返回 200 "ok" |
| 前端可访问 | 浏览器打开 `/` | 显示首页三张卡片 |
| speedscope 已部署 | `ls web/assets/vendor/speedscope/index.html` | 文件存在 |
| Skynet 接入成功 | snlua 启动日志 | 无 firegraph 报错 |
| 火焰图上报成功 | `curl /api/profiles` | 列表含新 profile |
| speedscope 渲染 | 点击「查看火焰图」 | 浏览器显示三视图 |
| trace 上报成功 | `sqlite3 firegraph.db "SELECT count(*) FROM traces;"` | > 0 |
| trace 统计正确 | `curl /api/traces/stats` | 返回含 P50/P95/P99 的 JSON |
| 优雅关闭 | `kill -SIGINT` | 日志显示 "bye" |

### 8.6 获取帮助

- 项目文档：[README.md](../README.md)
- 技术设计：[docs/TECHNICAL_DESIGN.md](./TECHNICAL_DESIGN.md)
- 需求文档：[docs/01-REQUIREMENTS.md](./01-REQUIREMENTS.md)
- 需求分析：[docs/02-REQUIREMENTS_ANALYSIS.md](./02-REQUIREMENTS_ANALYSIS.md)
- 代码设计：[docs/03-CODE_DESIGN.md](./03-CODE_DESIGN.md)

---

**文档结束。** 按本教程操作遇阻，请先查阅 [§7 故障排除](#7-故障排除) 与 [§6 FAQ](#6-常见问题解答faq)，仍无法解决可对照代码设计文档定位问题。
