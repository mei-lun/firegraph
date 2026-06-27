-- firegraph preload 脚本
--
-- 在 skynet 配置中设置 preload = "./skynet-agent/lua/preload.lua"
-- 所有 snlua 服务启动时会先 require 此脚本，完成 firegraph 自动初始化
--
-- 配置通过 skynet getenv 读取：
--   firegraph_host      (默认 127.0.0.1)
--   firegraph_port      (默认 8080)
--   service_name        (必填，建议每个服务类型不同)
--   node_name           (默认 default)
--   firegraph_auto_profile_interval  (默认 0=不自动采样，单位秒)
--   firegraph_auto_profile_duration  (默认 30)
--   firegraph_enable_tracer          (默认 false，阶段 2 启用)

local skynet = require "skynet"
local firegraph = require "firegraph"

local function env(name, default)
    local v = skynet.getenv(name)
    if v == nil then
        return default
    end
    return v
end

local ok, err = pcall(function()
    firegraph.init({
        server_host            = env("firegraph_host", "127.0.0.1"),
        server_port            = tonumber(env("firegraph_port", "8080")),
        service                = env("service_name", "unknown"),
        node                   = env("node_name", "default"),
        auto_profile_interval  = tonumber(env("firegraph_auto_profile_interval", "0")),
        auto_profile_duration  = tonumber(env("firegraph_auto_profile_duration", "30")),
    })

    -- 接口埋点（阶段 2）
    if env("firegraph_enable_tracer", false) then
        firegraph.install_tracer()
    end
end)

if not ok then
    skynet.error("[firegraph] preload init failed: " .. tostring(err))
end

return firegraph
