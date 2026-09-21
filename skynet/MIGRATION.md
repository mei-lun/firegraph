# Firegraph 服务端整合包 — 迁移使用文档

本目录 `skynet/` 是把 Firegraph（火焰图 + 接口耗时）集成进 skynet 游戏服务端所需的**全部服务端材料**，已从 gardenserver 项目中抽取并整理成一套相对独立的模块。

配合 `firegraph/web/`（前端源文件）和 `firegraph/web/assets/vendor/speedscope/`（speedscope 离线资源），可将火焰图能力无缝迁移到其他同类 skynet 项目。

---

## 一、架构概述（无后端方案）

当前方案**不需要独立的 Go/Python 后端**，数据流如下：

```
每个 snlua 服务（gate/login/zone/... 各自独立 Lua VM）
   │
   ├─ firegraph.monitor  → debug.sethook 采样调用栈（monkey-patch skynet.start + coroutine）
   │       └─ 周期性生成 folded stack → skynet.send(swt/agent, "fg_profile", ...)
   │
   └─ firegraph.tracer   → 包装 skynet.dispatch 记录消息耗时（接口耗时埋点）
           └─ 批量 skynet.send(swt/agent, "fg_traces", ...)
                    │
                    ▼
        swt/agent 服务（handle_firegraph.lua）
           ├─ 内存缓存 profile / traces
           ├─ HTTP 路由：/firegraph（火焰图列表）、/firegraph/view（实时查看器）、
           │             /traces.html（接口耗时页）、/api/*（数据接口）
           ├─ WebSocket 实时推送新 profile
           └─ speedscope 静态资源服务 + folded.stack 文本生成
                    │
                    ▼
              浏览器（火焰图 + 接口耗时表格，实时刷新）
```

关键点：

- **无后端**：不依赖 `firegraph/server`（Go）或 `app.py`（Python），全部由 SWT agent 内置 HTTP/WebSocket 服务承载。
- **跨 snlua 采样**：通过 monkey-patch 让每一个 snlua 实例独立采样上报（不是只采样 launcher）。
- **纯 Lua 采样**：用 `debug.sethook` 替代 SWT 原生 `profile.so`（后者与 gardenserver 的 skynet ABI 不兼容，已废弃）。

---

## 二、前置条件

| 项 | 要求 |
|----|------|
| skynet | 基于 C 的 skynet 分支，Lua 5.4（与目标项目一致即可） |
| cjson | 需有 `cjson.so`（本包已提供，见 `luaclib/cjson.so`） |
| http 模块 | 需具备 `httpd/sockethelper/websocket/url`（本包已提供完整 `lualib/http/`） |
| 目标项目 | 使用 `zn.startup_app` 这类启动回调（gardenserver 系）；其他框架需自行找等价钩子 |

⚠ 若目标项目的 skynet **缺 `http/websocket.lua` 或 `http/sockethelper.lua`**（标准 skynet 常缺），请把本包 `lualib/http/` 整目录覆盖到目标项目的 skynet http 目录。

---

## 三、整合包文件清单

```
skynet/
├── lualib/
│   ├── firegraph/          # Firegraph 核心模块
│   │   ├── init.lua        # 入口：init() / start_profile() / install_tracer()
│   │   ├── monitor.lua     # debug.sethook 采样 + monkey-patch skynet.start/协程
│   │   ├── tracer.lua      # 包装 skynet.dispatch 的接口耗时埋点
│   │   ├── reporter.lua    # 上报客户端（旧 HTTP POST，已由 skynet.send 取代，保留兼容）
│   │   └── swt_bridge.lua  # SWT 调用树 → folded stack 转换（保留兼容）
│   ├── swt/                # SWT（Simple Web Toolkit）Lua 库
│   │   ├── init.lua        # start_agent() / start_master()
│   │   ├── http_helper.lua # HTTP 响应/路由分发/静态文件/WebSocket upgrade 封装
│   │   ├── util.lua        # pack/unpack/log_error/bind 工具
│   │   ├── debug.lua       # 注册 SWT_RUN 调试命令
│   │   └── ws_client.lua   # WebSocket 客户端（可选）
│   ├── http/               # skynet http 扩展（websocket/sockethelper 等）
│   │   ├── httpd.lua  sockethelper.lua  websocket.lua  url.lua
│   │   ├── internal.lua  httpc.lua  tlshelper.lua
│   └── router.lua          # HTTP 路由（radix 风格）
├── service/
│   └── swt/
│       ├── agent/
│       │   ├── main.lua            # agent 服务入口，注册 command.start
│       │   ├── handle_debug.lua    # 远程调试（可选）
│       │   └── handle_firegraph.lua# 火焰图 + 接口耗时后端（核心，内嵌 HTML/CSS/JS）
│       └── master/                # SWT master（当前方案未启用，保留）
│           ├── main.lua  agent_mgr.lua  global.lua  handle_api.lua
├── appmod/
│   ├── firegraph_boot.lua  # 启动引导（在 zn.startup_app 末尾调用）
│   └── dev_preload.lua     # 开发 preload（os.time 重写 + monitor/tracer）
├── luaclib/
│   ├── cjson.so            # 必需（firegraph 依赖 cjson）
│   └── profile.so          # 已废弃（debug.sethook 取代，保留备用）
└── config/
    └── mei_common.path.example.lua  # 配置改动片段（见下）
```

> frontend（`web/`）与 speedscope（`web/assets/vendor/speedscope/`）不在本目录，位于 firegraph 项目根目录 `web/` 下，属于前端材料。

---

## 四、目录映射（本包 → 目标项目）

| 本包路径 | 目标项目落点 |
|----------|--------------|
| `skynet/lualib/firegraph/` | `<module_dir>/lualib/firegraph/` |
| `skynet/lualib/swt/` | `<module_dir>/lualib/swt/` |
| `skynet/lualib/router.lua` | `<module_dir>/lualib/router.lua` |
| `skynet/lualib/http/` | `<skynet_dir>/lualib/http/` （注意：skynet 的 http 目录） |
| `skynet/service/swt/` | `<module_dir>/service/swt/` |
| `skynet/appmod/firegraph_boot.lua` | `<src_dir>/appmod/firegraph_boot.lua` |
| `skynet/appmod/dev_preload.lua` | `<src_dir>/appmod/dev_preload.lua` |
| `skynet/luaclib/*.so` | `<module_dir>/luaclib/` 或 `<skynet_dir>/luaclib/` |
| `skynet/config/*` | 合并进目标项目 config（见下） |

---

## 五、迁移步骤（6 步）

### 步骤 1：拷贝文件

```bash
# 假设目标项目根目录为 /path/to/target
# module_dir 通常 = target/modules，skynet_dir = target/modules/skynet

cp -r skynet/lualib/firegraph   target/modules/lualib/
cp -r skynet/lualib/swt         target/modules/lualib/
cp    skynet/lualib/router.lua  target/modules/lualib/
cp -r skynet/lualib/http        target/modules/skynet/lualib/   # ← 注意落到 skynet 下
cp -r skynet/service/swt        target/modules/service/
cp    skynet/appmod/firegraph_boot.lua target/src/appmod/
cp    skynet/appmod/dev_preload.lua     target/src/appmod/
cp    skynet/luaclib/cjson.so   target/modules/luaclib/
```

### 步骤 2：修改配置（3 处）

参照 `config/mei_common.path.example.lua`，在目标项目 config 中确保：

1. `lua_path` 增加 `module_dir .. "/lualib/?.lua;"` 和 `module_dir .. "/lualib/?/init.lua;"`
2. `luaservice` 增加 `module_dir .. "/service/?/main.lua;"`
3. dev 环境 `preload` 指向 `src_dir .. "/appmod/dev_preload.lua"`

### 步骤 3：接入启动引导

在目标项目每个 `app/xxx/main.lua` 的 `zn.startup_app` 回调**末尾**加一行：

```lua
require("appmod.firegraph_boot")()
```

> 必须在 startup 回调里调用，**不能在 preload 阶段**调用 skynet.error/init 或 require swt/firegraph。

### 步骤 4：修正 speedscope 路径

`handle_firegraph.lua` 的 `get_speedscope_root()` 内置了硬编码路径，需改成目标项目的 speedscope 目录（或把 speedscope 资源放到其中一个路径）：
- `firegraph/web/assets/vendor/speedscope`
- `<target>/vendor/speedscope`

### 步骤 5：配置 agent 端口

`firegraph_boot.lua` 读取 env `swt_agent_port`（默认 `9528`）并加 harbor 偏移。若目标项目已占用该端口，在启动环境里设置 `swt_agent_port` 覆盖。

### 步骤 6：启动并验证

```bash
# 启动服务器后验证
curl -s http://127.0.0.1:9528/healthz          # 期望 {"ok":true}
curl -s http://127.0.0.1:9528/firegraph          # 期望 200，火焰图列表页
curl -s http://127.0.0.1:9528/traces.html        # 期望 200，接口耗时页
curl -s http://127.0.0.1:9528/api/profiles       # 期望返回 profile items
curl -s http://127.0.0.1:9528/api/traces/stats   # 期望返回耗时聚合
```

浏览器打开 `http://127.0.0.1:9528/firegraph`（火焰图）与 `/traces.html`（接口耗时），确认有数据且实时刷新。

---

## 六、验证清单

- [ ] 所有节点进程正常启动（无 `NODE START FAILED`，除非是环境依赖如 Mongo 缺失）
- [ ] `/healthz` 返回 `{"ok":true}`
- [ ] `/api/profiles` 返回多条 profile，`service_name` 字段是真实服务名（非 `unknown`）
- [ ] `/firegraph` 列表页能点击「查看火焰图」且 speedscope 正常渲染折叠栈
- [ ] `/traces.html` 表格有数据行（service/cmd/调用数/P50/P95/P99/avg/max）
- [ ] 火焰图页面有暂停/继续、保存功能，并能实时更新
- [ ] 无 `ERR_SOCKET_NOT_CONNECTED`、`Firegraph is not defined` 等浏览器报错

---

## 七、常见问题排错

| 问题 | 原因 | 解决 |
|------|------|------|
| preload 后无 launcher、服务不启动 | preload 阶段调用了 skynet.error/skynet.init，或在 require "znf/preload" 前 require swt/firegraph | 保持 dev_preload.lua 仅做 os.time 重写 + require znf/preload + pcall 加载 monitor/tracer |
| 火焰图/接口耗时页面空白或一直转圈 | 浏览器复用已关闭的 HTTP 连接（HTTP/1.1 默认 keep-alive），`app.js` 加载失败 | 所有 HTTP 响应头加 `Connection: close`（本包 http_helper.lua 已修复）；硬刷新 Ctrl+F5 |
| 火焰图无业务调用栈 | 仅采样了 launcher snlua | 确认 monitor.lua 已 monkey-patch skynet.start + coroutine.create/wrap |
| `service` 字段全为 `unknown` | 用了 skynet.getenv("service_name")（未设置） | 改为 `SERVICE_NAME or skynet.getenv("service_name") or "unknown"`（本包已修复） |
| speedscope 报 inflate 错误 | 走了 JSON 导入的 gzip 解压分支 | 使用 `.collapsedstack.txt` 折叠栈文本，走 speedscope 文本导入路径（本包已处理） |
| `profile.so` 段错误 | 与目标 skynet ABI 不匹配 | 使用 debug.sethook 纯 Lua 采样，丢弃 profile.so |
| 同一 node 多条几乎同时的 profile | 每个 snlua 服务独立采样上报（正常） | 依据 `service_name` 区分不同服务即可 |
| HTTP 连接泄漏 / 卡死 | 响应后未关闭 socket | 每个 handler 写完后 `socket.close(request.id)` |

---

## 八、涉及的关键文件（源码索引）

| 文件 | 职责 |
|------|------|
| `lualib/firegraph/monitor.lua` | `debug.sethook` 采样 + `skynet.start`/协程 monkey-patch + `fg_profile` 上报 |
| `lualib/firegraph/tracer.lua` | `skynet.dispatch` monkey-patch + 接口耗时 + `fg_traces` 上报 |
| `service/swt/agent/handle_firegraph.lua` | 内嵌前端 HTML/CSS/JS + 内存缓存 + WebSocket + 数据聚合 API |
| `service/swt/agent/main.lua` | agent 服务入口，注册 command.start，加载 handle_debug/handle_firegraph |
| `lualib/swt/http_helper.lua` | HTTP 响应/路由分发/WebSocket upgrade（含 `Connection: close`） |
| `appmod/firegraph_boot.lua` | 启动引导，异步启动 SWT agent + 初始化 Firegraph |
| `appmod/dev_preload.lua` | 开发 preload，加载 monitor/tracer（覆盖所有 snlua） |