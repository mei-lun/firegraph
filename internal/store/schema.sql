-- profile 元数据 + 折叠栈原文
CREATE TABLE IF NOT EXISTS profiles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  service_name TEXT NOT NULL,
  node TEXT NOT NULL,
  sampled_at INTEGER NOT NULL,    -- 采样结束 unix 时间戳（秒）
  duration_sec INTEGER NOT NULL,  -- 采样持续时长
  folded_text TEXT NOT NULL,      -- 折叠栈原文（main;foo;bar 123\n...）
  sample_count INTEGER NOT NULL,  -- 采样总数
  created_at INTEGER NOT NULL     -- 入库时间戳
);
CREATE INDEX IF NOT EXISTS idx_profiles_lookup ON profiles(service_name, sampled_at);

-- 接口耗时明细
CREATE TABLE IF NOT EXISTS traces (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,            -- 消息处理时间戳（秒）
  service TEXT NOT NULL,          -- snlua 服务名
  proto TEXT NOT NULL,            -- 协议名（如 lua/text/response）
  cmd TEXT NOT NULL,              -- 命令名（dispatch 第一个参数）
  session INTEGER,                -- skynet session id（可空）
  cost_ms INTEGER NOT NULL,       -- 处理耗时（毫秒）
  ok INTEGER NOT NULL             -- 1=成功 0=失败
);
CREATE INDEX IF NOT EXISTS idx_traces_lookup ON traces(service, cmd, ts);
CREATE INDEX IF NOT EXISTS idx_traces_ts ON traces(ts);
