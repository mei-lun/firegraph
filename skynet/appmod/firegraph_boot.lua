-- firegraph_boot.lua
-- SWT Agent + Firegraph 初始化引导
-- 在 zn.startup_app 回调末尾调用，不依赖 preload
--
-- 用法：
--   require("appmod.firegraph_boot")()

local skynet = require "skynet"

return function()
    skynet.fork(function()
        -- 等待一小段时间，确保所有基础服务完全就绪
        skynet.sleep(100)  -- 1 秒 (单位 1/100 秒)

        local node_name = skynet.getenv("id") or "unknown"
        local node_type = skynet.getenv("node_type") or "game"
        local harbor = tonumber(skynet.getenv("harbor")) or 0
        local agent_port = (tonumber(skynet.getenv("swt_agent_port")) or 9528) + harbor
        local listen_addr = string.format("127.0.0.1:%d", agent_port)

        -- 1. 尝试加载 swt.debug（注册 SWT_RUN 调试命令）
        local ok_debug, err_debug = pcall(require, "swt.debug")
        if not ok_debug then
            skynet.error("[firegraph_boot] swt.debug: " .. tostring(err_debug))
        end

        -- 2. 启动 SWT agent
        local ok_swt, swt = pcall(require, "swt")
        if ok_swt then
            swt.start_agent(node_type, node_name, listen_addr)
            skynet.error(string.format(
                "[firegraph_boot] SWT agent started: type=%s name=%s addr=%s",
                node_type, node_name, listen_addr
            ))
        else
            skynet.error("[firegraph_boot] swt not available: " .. tostring(swt))
        end

        -- 3. 初始化 Firegraph
        local ok_fg, fg = pcall(require, "firegraph")
        if ok_fg then
            fg.init({
                server_host = "127.0.0.1",
                server_port = 8080,
                service     = skynet.getenv("service_name") or "unknown",
                node        = node_name,
                auto_profile_interval = 0,   -- monitor preload 已接管全 snlua 采样
            })
            fg.install_tracer()
            skynet.error(string.format(
                "[firegraph_boot] firegraph initialized: service=%s node=%s",
                skynet.getenv("service_name") or "unknown",
                node_name
            ))
        else
            skynet.error("[firegraph_boot] firegraph not available: " .. tostring(fg))
        end
    end)
end