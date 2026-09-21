-- firegraph-adapter 模块入口
-- 同时导出 converter 和 reporter，方便外部单次 require 即可使用

local M = {}

M.reporter = require "firegraph-adapter.lua.reporter"
M.converter = require "firegraph-adapter.lua.profile_to_folded"

-- 便捷函数：一步完成转换 + 上报
-- @param cfg          reporter 配置表 { host, port, retry_count, ... }
-- @param service_name 服务名
-- @param node         节点标识
-- @param swt_result   profile.stop() 的返回结果 { time, nodes }
-- @param duration_sec 采样时长
-- @return true | false, err_msg
function M.convert_and_report(cfg, service_name, node, swt_result, duration_sec)
    if cfg then
        M.reporter.init(cfg)
    end

    local folded = M.converter.convert(swt_result)
    if not folded or folded == "" then
        return false, "no profile data to report"
    end

    local sampled_at = swt_result.time or os.time()
    return M.reporter.report(service_name, node, sampled_at, duration_sec, folded)
end

return M