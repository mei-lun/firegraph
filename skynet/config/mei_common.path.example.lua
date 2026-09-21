-- ============================================================================
-- Firegraph 集成所需的最小配置片段（路径相关部分）
-- ----------------------------------------------------------------------------
-- 说明：
--   本文件不是完整配置文件，仅摘录目标项目（skynet 游戏服务端）需要新增/修改
--   的「路径」与「preload」相关配置。请将对应行合并到你自己的 config 文件中。
--
--   以 gardenserver 的 config/mei_common.config 为例，变量约定如下：
--     src_dir    = "./src"                   -- 业务源码目录
--     module_dir = "$ZN_PATH"                -- 公共模块目录（通常 = ./modules）
--     skynet_dir = "$ZN_PATH/skynet"         -- skynet 框架目录
--   如果你的项目变量命名不同，请自行替换为对应变量。
-- ============================================================================

src_dir    = "./src"
module_dir = "$ZN_PATH"
skynet_dir = "$ZN_PATH/skynet"

-- ----------------------------------------------------------------------------
-- 1) lua_path —— 必须包含以下三个路径：
--    a. module_dir .. "/lualib/?.lua"         用于加载 router.lua
--    b. module_dir .. "/lualib/?/init.lua"     用于加载 firegraph/init.lua、swt/init.lua
--    c. skynet_dir .. "/lualib/?/init.lua"     用于加载 http/ 模块（websocket 等）
-- ----------------------------------------------------------------------------
lua_path = src_dir .. "/?.lua;"
        .. module_dir .. "/lualib/?.lua;"
        .. module_dir .. "/lualib/?/init.lua;"
        .. skynet_dir .. "/lualib/?.lua;"
        .. skynet_dir .. "/lualib/?/init.lua"

-- ----------------------------------------------------------------------------
-- 2) lua_cpath —— 必须能加载 cjson.so（firegraph 依赖 cjson）
--    cjson.so 已放在本整合包的 luaclib/ 目录，同步到目标项目后落在
--    <module_dir>/luaclib/cjson.so 或 <skynet_dir>/luaclib/cjson.so
-- ----------------------------------------------------------------------------
lua_cpath = module_dir .. "/luaclib/?.so;" .. skynet_dir .. "/luaclib/?.so"

-- ----------------------------------------------------------------------------
-- 3) luaservice —— 必须包含 service 的 main.lua 路径，用于启动 swt/agent、swt/master
-- ----------------------------------------------------------------------------
luaservice = src_dir .. "/?.lua;"
          .. module_dir .. "/service/?.lua;"
          .. module_dir .. "/service/?/main.lua;"
          .. skynet_dir .. "/service/?.lua;"

cpath = module_dir .. "/cservice/?.so;" .. skynet_dir .. "/cservice/?.so"

-- ----------------------------------------------------------------------------
-- 4) preload —— 开发环境需指向整合包内的 dev_preload.lua
--    dev_preload.lua 的职责：os.time 重写 + require "znf/preload" + 加载
--    firegraph.monitor / firegraph.tracer（pcall 包裹，覆盖所有 snlua 实例）
--
--    ⚠ 注意：dev_preload.lua 里禁止调用 skynet.error / skynet.init，
--    亦不可在 require "znf/preload" 之前 require swt/firegraph（会破坏 preload）。
-- ----------------------------------------------------------------------------
if app_env == "dev" then
    lua_path  = "./src_hook/?.lua;./src_dev/?.lua;" .. lua_path
    luaservice = "./src_hook/?.lua;./src_dev/?.lua;" .. luaservice
    thread = 1
    preload = src_dir .. "/appmod/dev_preload.lua"
end

-- ----------------------------------------------------------------------------
-- 5) firegraph_boot.lua 的调用点 —— 在各个 app/xxx/main.lua 的
--    zn.startup_app 回调「末尾」调用（不是 preload！）：
--
--      require("appmod.firegraph_boot")()
--
--    它会异步（skynet.fork）启动 SWT agent、注册调试命令、初始化 Firegraph。
--    agent 监听端口通过 env swt_agent_port（默认 9528）+ harbor 计算。
-- ----------------------------------------------------------------------------