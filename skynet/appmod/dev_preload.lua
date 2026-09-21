local skynet = require "skynet"
local old_os_time = os.time
function os.time(date)
    if date then return old_os_time(date) end
    return old_os_time() + skynet.getoffsettime()
end
require "znf/preload"

-- Firegraph 协程监控: monkey-patch coroutine.create/wrap
-- 在 preload 中加载以覆盖所有 snlua 实例
pcall(require, "firegraph.monitor")

-- Firegraph 接口埋点: monkey-patch skynet.dispatch，覆盖所有 snlua 记录接口耗时
local ok_tracer, tracer = pcall(require, "firegraph.tracer")
if ok_tracer then
    tracer.install()
end