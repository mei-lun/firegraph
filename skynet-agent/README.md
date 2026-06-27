# firegraph Skynet 端采集模块

## 目录结构

```
skynet-agent/
└── lua/
    ├── preload.lua              # skynet preload 入口（自动初始化）
    └── firegraph/
        ├── init.lua             # 模块入口，提供 API
        ├── swt_bridge.lua       # 采样器（内置 debug.sethook + 可选 swt 适配）
        ├── reporter.lua         # HTTP 上报客户端
        └── tracer.lua           # 接口埋点（阶段 2）
```

## 接入方式

### 方式 1：preload 自动初始化（推荐）

在 skynet 工作目录的 config 文件中设置：

```lua
-- 1. 把 skynet-agent/lua 加入 LUA_PATH
lua_path = "./skynet-agent/lua/?.lua;./skynet-agent/lua/?/init.lua"

-- 2. 设置 preload
preload = "./skynet-agent/lua/preload.lua"

-- 3. 配置 firegraph 环境变量
firegraph_host = "127.0.0.1"          -- 后端地址
firegraph_port = 8080
service_name   = "login"              -- 当前服务名（每个服务类型不同）
node_name      = "node1"              -- 节点名
firegraph_auto_profile_interval = 300 -- 每 5 分钟自动采样一次（0=不自动）
firegraph_auto_profile_duration = 30  -- 每次采样 30 秒
firegraph_enable_tracer = true        -- 启用接口埋点（阶段 2）
```

所有 snlua 服务启动时会自动初始化 firegraph，无需业务代码改动。

### 方式 2：业务代码手动初始化

```lua
local firegraph = require "firegraph"
firegraph.init({
    server_host = "127.0.0.1",
    server_port = 8080,
    service     = "login",
    node        = "node1",
})
-- 手动触发一次 60 秒采样
firegraph.start_profile(60)
```

## 采样器说明

`swt_bridge.lua` 提供两种采样器实现：

### 内置采样器（默认）

基于 `debug.sethook("l", 5000)`，每 5000 行 Lua 指令采样一次调用栈。
- **优点**：开箱即用，无需编译 C 模块
- **局限**：只能采样设置了 hook 的协程，跨协程采样不完整
- **适用**：CPU 密集型业务定位、开发期分析

### swt 适配器（可选）

接入 [lsg2020/swt](https://github.com/lsg2020/swt) 获得精确的全服务采样：
- **前提**：skynet 源码应用 swt 要求的 patch（commit `4ace42e8`）
- **接入**：在 `skynet-agent/lua/firegraph/swt_bridge.lua` 的 `start`/`stop` 中
  调用 swt 的实际 API（当前为示意代码，需根据 swt 版本调整）
- **优势**：精确采样所有协程的 Lua 调用栈

## 上报机制

- 协议：HTTP/JSON
- 端点：`POST /api/profiles/upload`
- 失败重试：3 次，每次间隔 1 秒
- 超过重试次数：丢弃本次采样（不阻塞业务）
- 体积限制：单次上报折叠栈最大 32MB

## 接口埋点（阶段 2）

启用 `firegraph_enable_tracer = true` 后，自动包装 `skynet.dispatch` 注册的
handler，记录每条消息的处理耗时，批量上报到 `POST /api/traces/batch`。

## 依赖

- skynet（cloudwu/skynet）
- skynet.httpc 模块（skynet 自带）
- 可选：swt（lsg2020/swt）
