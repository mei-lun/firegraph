#!/bin/bash
set -e

# 1. 获取 Windows 主机 IP（WSL2 中 default gateway 指向 Windows）
WIN_HOST=$(ip route show | grep default | awk '{print $3}')
echo "Windows host IP: $WIN_HOST"

# 2. 测试 firegraph 后端连通性
echo "--- 测试 firegraph 后端连通 ---"
if curl -s --connect-timeout 3 "http://${WIN_HOST}:8080/healthz" >/dev/null 2>&1; then
    echo "firegraph OK at http://${WIN_HOST}:8080"
else
    echo "firegraph NOT reachable, trying 127.0.0.1..."
    if curl -s --connect-timeout 3 "http://127.0.0.1:8080/healthz" >/dev/null 2>&1; then
        WIN_HOST="127.0.0.1"
        echo "firegraph OK at 127.0.0.1:8080"
    else
        echo "ERROR: firegraph 后端不可达"
        exit 1
    fi
fi

# 3. 复制 firegraph agent 到 myskynet
echo "--- 复制 firegraph agent ---"
mkdir -p /mnt/d/MyPoj/myskynet/firegraph-agent
cp -r /mnt/d/MyPoj/firegraph/skynet-agent/lua/* /mnt/d/MyPoj/myskynet/firegraph-agent/
ls -la /mnt/d/MyPoj/myskynet/firegraph-agent/firegraph/

# 4. 生成 skynet 配置（基于 examples/config，加入 firegraph）
echo "--- 生成 skynet 配置 ---"
cat > /mnt/d/MyPoj/myskynet/examples/config.firegraph <<EOF
include "config.path"

thread = 8
harbor = 1
start = "mainfg"

bootstrap = "snlua bootstrap"
standalone = "0.0.0.0:2013"
master = "127.0.0.1:2013"
address = "127.0.0.1:2526"

-- firegraph agent 路径
lua_path = "./lualib/?.lua;;./firegraph-agent/?.lua;;./firegraph-agent/?/init.lua;;"
lua_cpath = "./luaclib/?.so;;"
luaservice = "./service/?.lua;;./test/?.lua;;./examples/?.lua;;./firegraph-agent/?.lua;;"
lualoader = "lualib/loader.lua"

-- preload firegraph
preload = "./firegraph-agent/preload.lua"

-- firegraph 配置
firegraph_host = "${WIN_HOST}"
firegraph_port = 8080
service_name = "demo"
node_name = "wsl1"
firegraph_auto_profile_interval = 0
firegraph_auto_profile_duration = 30
firegraph_enable_tracer = true
EOF

echo "配置已生成: examples/config.firegraph"
cat /mnt/d/MyPoj/myskynet/examples/config.firegraph

# 5. 创建 mainfg.lua（基于 main.lua，加入 firegraph tag_cmd）
echo "--- 创建 mainfg.lua ---"
cat > /mnt/d/MyPoj/myskynet/examples/mainfg.lua <<'LUAEOF'
local skynet = require "skynet"
local firegraph = require "firegraph"

skynet.start(function()
    print("=== firegraph demo 启动 ===")
    -- 启动 firegraph（preload 已自动初始化，这里确保 tracer 安装）
    pcall(firegraph.install_tracer)

    local console = skynet.newservice("console")
    skynet.newservice("debug_console",8000)
    skynet.newservice("simpledb")
    local watchdog = skynet.newservice("watchdog")
    skynet.call(watchdog, "lua", {
        port = 8888,
        maxclient = 1024,
        nodelay = true,
    })
    print("=== Watchdog listen on 0.0.0.0:8888 (firegraph enabled) ===")

    -- 触发一次采样（5 秒）生成火焰图数据
    skynet.fork(function()
        skynet.sleep(100)  -- 等 1 秒服务稳定
        print("=== 触发 firegraph 采样 (5s) ===")
        pcall(firegraph.start_profile, 5)
    end)

    -- 模拟一些业务消息产生 trace 数据
    skynet.fork(function()
        skynet.sleep(200)  -- 等 2 秒
        for i = 1, 50 do
            skynet.fork(function()
                -- 模拟 Login/Logout/Query/Attack 等命令
                firegraph.tag_cmd("Login")
                skynet.sleep(math.random(1, 30))  -- 10-300ms
            end)
        end
        for i = 1, 40 do
            skynet.fork(function()
                firegraph.tag_cmd("Logout")
                skynet.sleep(math.random(1, 35))
            end)
        end
        for i = 1, 60 do
            skynet.fork(function()
                firegraph.tag_cmd("Query")
                skynet.sleep(math.random(1, 25))
            end)
        end
        for i = 1, 30 do
            skynet.fork(function()
                firegraph.tag_cmd("Attack")
                skynet.sleep(math.random(1, 40))
            end)
        end
        print("=== 已触发模拟业务消息 ===")
    end)

    skynet.exit()
end)
LUAEOF

echo "=== 部署脚本完成 ==="
