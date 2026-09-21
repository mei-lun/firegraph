-- reporter.lua
-- Firegraph HTTP 上报客户端（SWT master 侧）
--
-- 负责将 folded stack 文本通过 HTTP POST 发送到 Firegraph 后端。
-- 运行在 SWT master 进程内（一个 skynet 进程），使用 skynet.socket 进行 HTTP 通信。
--
-- 用法：
--   local reporter = require "firegraph-adapter.lua.reporter"
--   reporter.init({ host = "127.0.0.1", port = 8080 })
--   reporter.report(service, node, sampled_at, duration_sec, folded_text)

local skynet = require "skynet"

local M = {}

local cfg = {
    host = "127.0.0.1",
    port = 8080,
    upload_path = "/api/profiles/upload",
    retry_count = 3,
    retry_interval = 100,  -- ms
}

function M.init(opts)
    opts = opts or {}
    cfg.host = opts.host or cfg.host
    cfg.port = opts.port or cfg.port
    cfg.upload_path = opts.upload_path or cfg.upload_path
    cfg.retry_count = opts.retry_count or cfg.retry_count
    cfg.retry_interval = opts.retry_interval or cfg.retry_interval
end

-- 手工 JSON 编码，避免对 cjson 的依赖
local function json_string_escape(s)
    if not s then
        return ""
    end
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    return s
end

local function build_request_body(service_name, node, sampled_at, duration_sec, folded_text)
    return string.format(
        '{"service_name":"%s","node":"%s","sampled_at":%d,"duration_sec":%d,"folded_text":"%s"}',
        json_string_escape(service_name),
        json_string_escape(node),
        sampled_at,
        duration_sec,
        json_string_escape(folded_text)
    )
end

-- 使用 skynet.socket 发送 HTTP POST
local function http_post(path, headers, body)
    local socket = require "skynet.socket"
    local fd = socket.open(cfg.host, cfg.port)
    if not fd then
        return nil, "failed to connect to " .. cfg.host .. ":" .. tostring(cfg.port)
    end

    local request_line = string.format("POST %s HTTP/1.1\r\nHost: %s:%s\r\n",
        path, cfg.host, tostring(cfg.port))

    for k, v in pairs(headers) do
        request_line = request_line .. k .. ": " .. tostring(v) .. "\r\n"
    end
    request_line = request_line .. "Connection: close\r\n\r\n" .. body

    socket.write(fd, request_line)

    local response = socket.readall(fd)
    socket.close(fd)

    if not response then
        return nil, "empty response"
    end

    local status = tonumber(response:match("HTTP/%d%.%d (%d+)"))
    return status or 0, response
end

-- report: 上报一次 profile 到 Firegraph
-- @param service_name  服务名（如 "gardenserver"）
-- @param node          节点标识（如 "game_1"）
-- @param sampled_at    采样时间戳（UNIX 秒）
-- @param duration_sec  采样时长（秒）
-- @param folded_text   folded stack 格式字符串
-- @return true | false, err_msg
function M.report(service_name, node, sampled_at, duration_sec, folded_text)
    local body = build_request_body(service_name, node, sampled_at, duration_sec, folded_text)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body),
    }

    for attempt = 1, cfg.retry_count do
        local ok, status_or_err, resp = pcall(http_post, cfg.upload_path, headers, body)

        if not ok then
            skynet.error(string.format(
                "[firegraph-adapter] report attempt %d/%d exception: %s",
                attempt, cfg.retry_count, tostring(status_or_err)
            ))
        elseif status_or_err == 200 then
            return true
        else
            skynet.error(string.format(
                "[firegraph-adapter] report attempt %d/%d HTTP %d: %s",
                attempt, cfg.retry_count, status_or_err, resp or ""
            ))
        end

        if attempt < cfg.retry_count then
            skynet.sleep(cfg.retry_interval)
        end
    end

    return false, "all retries exhausted"
end

return M