-- handle_firegraph.lua
-- 保持原始前端完全不变，仅实现后端 API + 静态文件服务
-- 前端来源：D:\MyPoj\firegraph\web\  (profiles.html, app.js, app.css)
-- Speedscope 来源：D:\MyPoj\firegraph\web\assets\vendor\speedscope/

local skynet      = require "skynet"
local http_helper = require "swt.http_helper"
local websocket   = require "http.websocket"
local json        = require "cjson"

-- cjson 空数组元表：强制空 table 编码为 [] 而非 {}
local json_array_mt = { __jsontype = "array" }
local function json_array(t)
    if next(t) == nil then
        return setmetatable({}, json_array_mt)
    end
    return t
end

-- ===== 内存缓存：最近 N 条 profile =====
local max_cache = 30
local cache = {}
local cache_index = 0
local next_id = 1

-- WebSocket 客户端
local ws_clients = {}

-- ===== 接口耗时缓存 =====
local traces = {}
local max_traces = 20000

local function add_traces(batch)
    for _, t in ipairs(batch) do
        traces[#traces + 1] = t
    end
    while #traces > max_traces do
        table.remove(traces, 1)
    end
end

-- ===== 工具函数 =====
local function add_profile(node, service, time, folded_text, total)
    cache_index = cache_index + 1
    if cache_index > max_cache then cache_index = 1 end
    local data = {
        id = next_id,
        node = node,
        service = service,
        time = time,
        folded = folded_text,
        total = total,
    }
    next_id = next_id + 1
    cache[cache_index] = data

    -- WebSocket 推送
    local payload = json.encode(data)
    local dead = {}
    for id, _ in pairs(ws_clients) do
        local ok = pcall(websocket.write, id, payload, "text")
        if not ok then dead[id] = true end
    end
    for id in pairs(dead) do ws_clients[id] = nil end
end

-- 从 folded text 生成 speedscope JSON
local function folded_to_speedscope(folded_text, profile_name)
    local frames = {}
    local frame_indices = {}
    local samples = {}
    local weights = {}
    local total_weight = 0

    for line in string.gmatch(folded_text .. "\n", "(.-)\n") do
        if line ~= "" then
            local sp = line:find(" [^ ]*$")
            if sp then
                local stack_str = line:sub(1, sp - 1)
                local count_str = line:sub(sp + 1)
                local count = tonumber(count_str)
                if count and count > 0 then
                    local stack_frames = {}
                    for frame in string.gmatch(stack_str, "([^;]+)") do
                        local idx = frame_indices[frame]
                        if not idx then
                            idx = #frames
                            frame_indices[frame] = idx
                            frames[idx + 1] = {name = frame}
                        end
                        table.insert(stack_frames, idx)
                    end
                    table.insert(samples, stack_frames)
                    table.insert(weights, count)
                    total_weight = total_weight + count
                end
            end
        end
    end

    return json.encode({
        ["$schema"] = "https://www.speedscope.app/file-format-schema.json",
        shared = {frames = frames},
        profiles = {{
            type = "sampled",
            name = profile_name,
            unit = "samples",
            startValue = 0,
            endValue = total_weight,
            samples = samples,
            weights = weights
        }}
    })
end

-- ===== 嵌入式前端文件 =====
local PROFILES_HTML = [===[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>火焰图 — Firegraph</title>
  <link rel="stylesheet" href="/assets/app.css">
</head>
<body>
  <header class="topbar">
    <div class="topbar-inner">
      <h1 class="brand"><a href="/">Firegraph</a></h1>
      <nav class="nav">
        <a href="/" class="nav-link">首页</a>
        <a href="/firegraph" class="nav-link active">火焰图</a>
        <a href="/traces.html" class="nav-link">接口耗时</a>
      </nav>
    </div>
  </header>

  <main class="container">
    <section class="toolbar">
      <div class="toolbar-group">
        <label>service
          <input type="text" id="filter-service" placeholder="如 login" />
        </label>
        <label>node
          <input type="text" id="filter-node" placeholder="如 node1" />
        </label>
        <button id="btn-filter" class="btn btn-primary">查询</button>
        <button id="btn-refresh" class="btn">刷新</button>
      </div>
      <div class="toolbar-hint" id="speedscope-hint" hidden>
        Speedscope 离线包已就绪。
      </div>
    </section>

    <section class="axis-wrap">
      <div class="axis-header">
        <span class="axis-title">采样时间轴（每个点 = 一个采样分组）</span>
        <label class="axis-window">窗口 <input type="number" id="group-window" value="10" min="1" step="1" /> 秒</label>
        <label class="axis-window">最多 <input type="number" id="group-max" value="50" min="1" step="1" /> 组</label>
        <span class="axis-hint" id="group-filter-hint" hidden>已筛选 1 个分组 — <a href="javascript:void(0)" onclick="Firegraph.ProfilesPage.clearGroup()">清除</a></span>
      </div>
      <div id="profile-axis" class="axis-body"><div class="empty">加载中...</div></div>
    </section>

    <section class="table-wrap">
      <table class="data-table">
        <thead>
          <tr>
            <th>ID</th>
            <th>service</th>
            <th>node</th>
            <th>采样时间</th>
            <th>时长</th>
            <th>采样数</th>
            <th>操作</th>
          </tr>
        </thead>
        <tbody id="profile-list">
          <tr><td colspan="7" class="empty">加载中...</td></tr>
        </tbody>
      </table>
    </section>
  </main>

  <script src="/assets/app.js"></script>
  <script>
    Firegraph.ProfilesPage.init();
  </script>
</body>
</html>
]===]

local APP_JS = [===[
// Firegraph 前端逻辑 — 原生 JS，无框架依赖
// 通过页面 <script> 调用对应模块的 init 函数
(function (global) {
  'use strict';

  var Firegraph = {};

  // ---------- 工具函数 ----------
  function formatTime(unixSec) {
    if (!unixSec) return '-';
    var d = new Date(unixSec * 1000);
    function pad(n) { return n < 10 ? '0' + n : '' + n; }
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
      ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }
  function escapeHtml(s) {
    if (s == null) return '';
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function escapeAttr(s) {
    return escapeHtml(s).replace(/`/g, '&#96;');
  }
  async function fetchJSON(url) {
    var res = await fetch(url);
    if (!res.ok) {
      var txt = await res.text();
      throw new Error('HTTP ' + res.status + ': ' + txt);
    }
    return res.json();
  }
  function qs(id) { return document.getElementById(id); }

  // ---------- speedscope 检测 ----------
  var speedscopeChecked = false;
  async function checkSpeedscope() {
    if (speedscopeChecked) return true;
    try {
      var res = await fetch('/assets/vendor/speedscope/index.html', { method: 'HEAD' });
      speedscopeChecked = res.ok;
    } catch (e) {
      speedscopeChecked = false;
    }
    return speedscopeChecked;
  }

  // ---------- Profiles 列表页 ----------
  var profileState = { window: 10, maxGroups: 50, selected: null, items: [], groups: [] };

  Firegraph.ProfilesPage = {
    init: async function () {
      var hint = qs('speedscope-hint');
      var ok = await checkSpeedscope();
      if (!ok && hint) hint.hidden = false;

      qs('btn-filter').addEventListener('click', this.load.bind(this));
      qs('btn-refresh').addEventListener('click', this.load.bind(this));
      qs('filter-service').addEventListener('keydown', function (e) {
        if (e.key === 'Enter') this.load.bind(this)();
      }.bind(this));
      qs('filter-node').addEventListener('keydown', function (e) {
        if (e.key === 'Enter') this.load.bind(this)();
      }.bind(this));
      qs('group-window').addEventListener('change', function () {
        var w = parseInt(qs('group-window').value, 10);
        profileState.window = (w && w > 0) ? w : 10;
        profileState.selected = null;
        this.load();
      }.bind(this));
      qs('group-max').addEventListener('change', function () {
        var m = parseInt(qs('group-max').value, 10);
        profileState.maxGroups = (m && m > 0) ? m : 50;
        profileState.selected = null;
        this.load();
      }.bind(this));
      await this.load();

      // WebSocket 实时推送 — 新 profile 到达时自动刷新列表
      var self = this;
      var wsUrl = 'ws://' + location.host + '/firegraph/ws';
      function wsConnect() {
        var ws = new WebSocket(wsUrl);
        ws.onmessage = function() { self.load(); };
        ws.onclose = function() { setTimeout(wsConnect, 2000); };
        ws.onerror = function() { ws.close(); };
      }
      wsConnect();
    },

    buildQuery: function () {
      var parts = [];
      var s = qs('filter-service').value.trim();
      var n = qs('filter-node').value.trim();
      if (s) parts.push('service=' + encodeURIComponent(s));
      if (n) parts.push('node=' + encodeURIComponent(n));
      parts.push('limit=200');
      return parts.length ? '?' + parts.join('&') : '';
    },

    load: async function () {
      var tbody = qs('profile-list');
      tbody.innerHTML = '<tr><td colspan="7" class="empty">加载中...</td></tr>';
      try {
        var data = await fetchJSON('/api/profiles' + this.buildQuery());
        profileState.items = data.items || [];
        this.render();
        await this.loadGroups();
      } catch (e) {
        tbody.innerHTML = '<tr><td colspan="7" class="empty">加载失败: ' + escapeHtml(e.message) + '</td></tr>';
      }
    },

    render: function () {
      var tbody = qs('profile-list');
      var items = profileState.items || [];
      if (profileState.selected != null) {
        items = items.filter(function (p) {
          return Math.floor(p.sampled_at / profileState.window) * profileState.window === profileState.selected;
        });
      }
      if (!items.length) {
        tbody.innerHTML = '<tr><td colspan="7" class="empty">' + (profileState.selected != null ? '该分组暂无 profile' : '暂无 profile 数据') + '</td></tr>';
        return;
      }
      tbody.innerHTML = items.map(function (p) {
        return '' +
          '<tr>' +
          '<td class="num">' + p.id + '</td>' +
          '<td>' + escapeHtml(p.service_name) + '</td>' +
          '<td>' + escapeHtml(p.node || '-') + '</td>' +
          '<td>' + formatTime(p.sampled_at) + '</td>' +
          '<td class="num">' + p.duration_sec + 's</td>' +
          '<td class="num">' + p.sample_count + '</td>' +
          '<td class="actions">' +
            '<button class="btn btn-primary" onclick="Firegraph.ProfilesPage.viewFlame(' + p.id + ', \'' + escapeAttr(p.service_name) + '\')">查看火焰图</button>' +
            '<a class="btn" href="/api/profiles/' + p.id + '/folded.txt">折叠栈</a>' +
          '</td>' +
          '</tr>';
      }).join('');
    },

    viewFlame: async function (id, service) {
      var url = '/firegraph/view?pid=' + id + '&service=' + encodeURIComponent(service);
      window.open(url, '_blank');
    },

    loadGroups: async function () {
      var el = qs('profile-axis');
      try {
        var parts = ['window=' + profileState.window, 'limit=' + profileState.maxGroups];
        var s = qs('filter-service').value.trim();
        var n = qs('filter-node').value.trim();
        if (s) parts.push('service=' + encodeURIComponent(s));
        if (n) parts.push('node=' + encodeURIComponent(n));
        var data = await fetchJSON('/api/profiles/groups?' + parts.join('&'));
        profileState.groups = data.items || [];
        this.renderAxis();
      } catch (e) {
        el.innerHTML = '<div class="empty">分组轴加载失败</div>';
      }
    },

    renderAxis: function () {
      var el = qs('profile-axis');
      el.innerHTML = renderGroupAxis(profileState.groups || [], {
        onSelect: 'Firegraph.ProfilesPage.selectGroup',
        selectedTs: profileState.selected
      });
      var h = qs('group-filter-hint');
      if (h) h.hidden = !profileState.selected;
    },

    selectGroup: function (ts) {
      profileState.selected = (profileState.selected === ts) ? null : ts;
      this.render();
      this.renderAxis();
    },

    clearGroup: function () {
      profileState.selected = null;
      this.render();
      this.renderAxis();
    }
  };

  // ---------- Traces 页（接口耗时） ----------
  var TRACE_RANGES = {
    3600: { bucket: 60, label: '1h' },
    21600: { bucket: 300, label: '6h' },
    86400: { bucket: 1800, label: '24h' },
    604800: { bucket: 7200, label: '7d' }
  };
  var traceState = { rangeSec: 3600, window: 10, maxGroups: 50, selectedGroup: null, groups: [] };

  Firegraph.TracesPage = {
    init: function () {
      var self = this;
      qs('btn-query').addEventListener('click', function () { self.load(); });
      qs('filter-service').addEventListener('keydown', function (e) {
        if (e.key === 'Enter') self.load();
      });
      qs('filter-cmd').addEventListener('keydown', function (e) {
        if (e.key === 'Enter') self.load();
      });
      qs('group-window').addEventListener('change', function () {
        var w = parseInt(qs('group-window').value, 10);
        traceState.window = (w && w > 0) ? w : 10;
        traceState.selectedGroup = null;
        self.load();
      });
      qs('group-max').addEventListener('change', function () {
        var m = parseInt(qs('group-max').value, 10);
        traceState.maxGroups = (m && m > 0) ? m : 50;
        traceState.selectedGroup = null;
        self.load();
      });
      var btns = document.querySelectorAll('.range-btn');
      for (var i = 0; i < btns.length; i++) {
        btns[i].addEventListener('click', function () {
          for (var j = 0; j < btns.length; j++) btns[j].classList.remove('active');
          this.classList.add('active');
          traceState.rangeSec = parseInt(this.getAttribute('data-range'), 10);
          traceState.selectedGroup = null;
          self.load();
        });
      }
      this.load();
    },

    buildQuery: function (extra) {
      var from, to;
      if (traceState.selectedGroup != null) {
        from = traceState.selectedGroup;
        to = from + traceState.window - 1;
      } else {
        var now = Math.floor(Date.now() / 1000);
        from = now - traceState.rangeSec;
        to = now;
      }
      var parts = ['from=' + from, 'to=' + to];
      var s = qs('filter-service').value.trim();
      var c = qs('filter-cmd').value.trim();
      if (s) parts.push('service=' + encodeURIComponent(s));
      if (c) parts.push('cmd=' + encodeURIComponent(c));
      if (extra) parts.push(extra);
      return '?' + parts.join('&');
    },

    load: async function () {
      var self = this;
      this.loadGroups();
      ['stat-total', 'stat-avg', 'stat-p95', 'stat-p99', 'stat-slow'].forEach(function (id) {
        qs(id).innerHTML = '-';
      });
      qs('stat-list').innerHTML = '<tr><td colspan="9" class="empty">加载中...</td></tr>';
      qs('chart').innerHTML = '<div class="empty">加载中...</div>';
      qs('detail-section').hidden = true;

      try {
        var bucket = TRACE_RANGES[traceState.rangeSec].bucket;
        var statsP = fetchJSON('/api/traces/stats' + this.buildQuery('limit=200'));
        var tsP = fetchJSON('/api/traces/timeseries' + this.buildQuery('bucket_sec=' + bucket));
        var stats = await statsP;
        var ts = await tsP;
        this.renderStats(stats.items || []);
        this.renderChart(ts.items || []);
      } catch (e) {
        qs('stat-list').innerHTML = '<tr><td colspan="9" class="empty">暂无 trace 数据</td></tr>';
        qs('chart').innerHTML = '<div class="empty">暂无时序数据</div>';
      }
    },

    renderStats: function (items) {
      var total = 0, sumCost = 0, maxP95 = 0, maxP99 = 0, slow = 0;
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        total += it.count;
        sumCost += it.avg_ms * it.count;
        if (it.p95_ms > maxP95) maxP95 = it.p95_ms;
        if (it.p99_ms > maxP99) maxP99 = it.p99_ms;
        if (it.p95_ms > 200) slow += Math.floor(it.count * 0.05);
      }
      qs('stat-total').textContent = total.toLocaleString();
      qs('stat-avg').innerHTML = (total > 0 ? Math.round(sumCost / total) : 0) + '<span class="unit">ms</span>';
      qs('stat-p95').innerHTML = maxP95 + '<span class="unit">ms</span>';
      qs('stat-p99').innerHTML = maxP99 + '<span class="unit">ms</span>';
      qs('stat-slow').textContent = slow.toLocaleString();

      var tbody = qs('stat-list');
      if (!items.length) {
        tbody.innerHTML = '<tr><td colspan="9" class="empty">暂无数据</td></tr>';
        return;
      }
      tbody.innerHTML = items.map(function (it) {
        return '<tr>' +
          '<td>' + escapeHtml(it.service) + '</td>' +
          '<td>' + escapeHtml(it.cmd) + '</td>' +
          '<td class="num">' + it.count.toLocaleString() + '</td>' +
          '<td class="num">' + it.p50_ms + '</td>' +
          '<td class="num">' + highlightSlow(it.p95_ms) + '</td>' +
          '<td class="num">' + it.p99_ms + '</td>' +
          '<td class="num">' + it.avg_ms + '</td>' +
          '<td class="num">' + it.max_ms + '</td>' +
          '<td><button class="btn" onclick="Firegraph.TracesPage.showDetail(\'' + escapeAttr(it.service) + '\',\'' + escapeAttr(it.cmd) + '\')">明细</button></td>' +
          '</tr>';
      }).join('');
    },

    renderChart: function (buckets) {
      var el = qs('chart');
      if (!buckets.length) {
        el.innerHTML = '<div class="empty">暂无时序数据</div>';
        return;
      }
      el.innerHTML = renderLineChart(buckets);
    },

    showDetail: async function (service, cmd) {
      var section = qs('detail-section');
      var list = qs('detail-list');
      qs('detail-title').textContent = service + ' / ' + cmd;
      section.hidden = false;
      list.innerHTML = '<tr><td colspan="6" class="empty">加载中...</td></tr>';
      try {
        var data = await fetchJSON('/api/traces' + this.buildQuery('limit=100') + '&service=' + encodeURIComponent(service) + '&cmd=' + encodeURIComponent(cmd));
        var items = data.items || [];
        if (!items.length) {
          list.innerHTML = '<tr><td colspan="6" class="empty">无明细</td></tr>';
          return;
        }
        list.innerHTML = items.map(function (t) {
          return '<tr>' +
            '<td>' + formatTime(t.ts) + '</td>' +
            '<td>' + escapeHtml(t.service) + '</td>' +
            '<td>' + escapeHtml(t.cmd) + '</td>' +
            '<td class="num">' + (t.session > 0 ? t.session : '-') + '</td>' +
            '<td class="num">' + highlightSlow(t.cost_ms) + '</td>' +
            '<td>' + (t.ok ? '<span class="ok">ok</span>' : '<span class="fail">fail</span>') + '</td>' +
            '</tr>';
        }).join('');
      } catch (e) {
        list.innerHTML = '<tr><td colspan="6" class="empty">无明细数据</td></tr>';
      }
    },

    loadGroups: async function () {
      var el = qs('trace-axis');
      try {
        var now = Math.floor(Date.now() / 1000);
        var from = now - traceState.rangeSec;
        var parts = ['window=' + traceState.window, 'limit=' + traceState.maxGroups, 'from=' + from, 'to=' + now];
        var s = qs('filter-service').value.trim();
        var c = qs('filter-cmd').value.trim();
        if (s) parts.push('service=' + encodeURIComponent(s));
        if (c) parts.push('cmd=' + encodeURIComponent(c));
        var data = await fetchJSON('/api/traces/groups?' + parts.join('&'));
        traceState.groups = data.items || [];
        this.renderAxis();
      } catch (e) {
        el.innerHTML = '<div class="empty">分组轴加载失败</div>';
      }
    },

    renderAxis: function () {
      var el = qs('trace-axis');
      el.innerHTML = renderGroupAxis(traceState.groups || [], {
        onSelect: 'Firegraph.TracesPage.selectGroup',
        selectedTs: traceState.selectedGroup
      });
      var h = qs('trace-group-hint');
      if (h) h.hidden = !traceState.selectedGroup;
    },

    selectGroup: function (ts) {
      traceState.selectedGroup = (traceState.selectedGroup === ts) ? null : ts;
      this.renderAxis();
      this.load();
    },

    clearGroup: function () {
      traceState.selectedGroup = null;
      this.renderAxis();
      this.load();
    }
  };

  function highlightSlow(ms) {
    if (ms >= 500) return '<span class="crit">' + ms + '</span>';
    if (ms >= 200) return '<span class="warn">' + ms + '</span>';
    return ms;
  }

  function renderLineChart(buckets) {
    var W = 1100, H = 300, PAD_L = 50, PAD_R = 20, PAD_T = 20, PAD_B = 40;
    var plotW = W - PAD_L - PAD_R, plotH = H - PAD_T - PAD_B;
    var series = buckets.map(function (b) {
      return { ts: b.ts, avg: b.avg_ms, p95: b.p95_ms, p99: Math.round(b.p95_ms * 1.1) };
    });
    var maxV = 0;
    series.forEach(function (s) {
      if (s.avg > maxV) maxV = s.avg;
      if (s.p95 > maxV) maxV = s.p95;
      if (s.p99 > maxV) maxV = s.p99;
    });
    if (maxV === 0) maxV = 1;
    maxV = Math.ceil(maxV * 1.1);
    var n = series.length;
    var xStep = n > 1 ? plotW / (n - 1) : 0;
    function xPos(i) { return PAD_L + (n > 1 ? i * xStep : plotW / 2); }
    function yPos(v) { return PAD_T + plotH - (v / maxV) * plotH; }
    function pathFor(getter) {
      if (n === 0) return '';
      var d = 'M ' + xPos(0) + ' ' + yPos(getter(series[0]));
      for (var i = 1; i < n; i++) d += ' L ' + xPos(i) + ' ' + yPos(getter(series[i]));
      return d;
    }
    var xTicks = '';
    for (var i = 0; i < 5; i++) {
      var idx = Math.floor((n - 1) * i / 4);
      if (idx < 0 || idx >= n) continue;
      xTicks += '<line x1="' + xPos(idx) + '" y1="' + PAD_T + '" x2="' + xPos(idx) + '" y2="' + (PAD_T + plotH) + '" stroke="#f1f5f9" stroke-width="1"/>';
      xTicks += '<text x="' + xPos(idx) + '" y="' + (H - 10) + '" text-anchor="middle" fill="#94a3b8" font-size="11">' + formatShortTime(series[idx].ts) + '</text>';
    }
    var yTicks = '';
    for (var i = 0; i <= 4; i++) {
      var v = Math.round(maxV * i / 4);
      var y = yPos(v);
      yTicks += '<line x1="' + PAD_L + '" y1="' + y + '" x2="' + (W - PAD_R) + '" y2="' + y + '" stroke="#f1f5f9" stroke-width="1"/>';
      yTicks += '<text x="' + (PAD_L - 8) + '" y="' + (y + 4) + '" text-anchor="end" fill="#94a3b8" font-size="11">' + v + '</text>';
    }
    return '<svg viewBox="0 0 ' + W + ' ' + H + '" style="width:100%;height:320px">' +
      xTicks + yTicks +
      '<path d="' + pathFor(function (s) { return s.avg; }) + '" fill="none" stroke="#2563eb" stroke-width="1.5"/>' +
      '<path d="' + pathFor(function (s) { return s.p95; }) + '" fill="none" stroke="#dc2626" stroke-width="1.5"/>' +
      '<path d="' + pathFor(function (s) { return s.p99; }) + '" fill="none" stroke="#9333ea" stroke-width="1.5" stroke-dasharray="4 2"/>' +
      '</svg>';
  }

  function formatShortTime(unixSec) {
    var d = new Date(unixSec * 1000);
    function pad(n) { return n < 10 ? '0' + n : '' + n; }
    return pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  // ---------- 时间分组轴组件（火焰图 / 接口耗时共用）----------
  // groups: [{ts, count}] 升序；opts: {onSelect 函数名, selectedTs}
  function renderGroupAxis(groups, opts) {
    var W = 1100, H = 76, PAD_L = 14, PAD_R = 14, PAD_T = 12, PAD_B = 24;
    var plotW = W - PAD_L - PAD_R;
    var n = groups.length;
    if (!n) return '<div class="empty">暂无分组数据</div>';
    var maxC = 1;
    for (var i = 0; i < n; i++) { if (groups[i].count > maxC) maxC = groups[i].count; }
    var xStep = n > 1 ? plotW / (n - 1) : 0;
    function xPos(i) { return PAD_L + (n > 1 ? i * xStep : plotW / 2); }
    var cy = PAD_T + 16;
    var html = '';
    for (var i = 0; i < n; i++) {
      var x = xPos(i);
      var r = 5 + Math.round((groups[i].count / maxC) * 9);
      var sel = opts.selectedTs === groups[i].ts;
      html += '<g style="cursor:pointer" onclick="' + opts.onSelect + '(' + groups[i].ts + ')">' +
        '<circle cx="' + x + '" cy="' + cy + '" r="' + Math.max(r + 6, 14) + '" fill="transparent"/>' +
        '<circle cx="' + x + '" cy="' + cy + '" r="' + r + '" fill="' + (sel ? '#dc2626' : '#2563eb') + '"' + (sel ? ' stroke="#991b1b" stroke-width="2"' : '') + '/>' +
        '</g>';
    }
    html += '<line x1="' + PAD_L + '" y1="' + cy + '" x2="' + (PAD_L + plotW) + '" y2="' + cy + '" stroke="#dbeafe" stroke-width="1"/>';
    var tick = 5;
    for (var k = 0; k < tick; k++) {
      var idx = Math.round((n - 1) * k / Math.max(tick - 1, 1));
      if (idx < 0) idx = 0;
      if (idx >= n) idx = n - 1;
      html += '<text x="' + xPos(idx) + '" y="' + (H - 8) + '" font-size="10" fill="#94a3b8" text-anchor="middle">' + formatShortTime(groups[idx].ts) + '</text>';
    }
    return '<svg viewBox="0 0 ' + W + ' ' + H + '" width="100%" role="img" aria-label="时间分组轴">' + html + '</svg>';
  }

  global.Firegraph = Firegraph;
})(window);
]===]

-- ===== 首页 =====
local INDEX_HTML = [===[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Firegraph — Skynet 性能监测</title>
  <link rel="stylesheet" href="/assets/app.css">
</head>
<body>
  <header class="topbar">
    <div class="topbar-inner">
      <h1 class="brand">Firegraph</h1>
      <nav class="nav">
        <a href="/" class="nav-link active">首页</a>
        <a href="/firegraph" class="nav-link">火焰图</a>
        <a href="/traces.html" class="nav-link">接口耗时</a>
      </nav>
    </div>
  </header>

  <main class="container">
    <section class="hero">
      <h2>Skynet 游戏服务器性能 &amp; 接口耗时监测</h2>
      <p class="hero-sub">采样式 Lua 火焰图 + dispatch 层无侵入接口埋点，浏览器交互查看。</p>
    </section>

    <section class="cards">
      <a href="/firegraph" class="card">
        <div class="card-icon" aria-hidden="true">&#x1F525;</div>
        <div class="card-title">CPU 火焰图</div>
        <div class="card-desc">查看历史采样 profile，在 speedscope 中交互分析调用栈热点。</div>
      </a>
      <a href="/traces.html" class="card">
        <div class="card-icon" aria-hidden="true">&#x23F1;&#xFE0F;</div>
        <div class="card-title">接口耗时</div>
        <div class="card-desc">P50/P95/P99 分位 + 趋势图，定位慢接口与抖动。</div>
      </a>
      <a href="/healthz" class="card">
        <div class="card-icon" aria-hidden="true">&#x2764;&#xFE0F;</div>
        <div class="card-title">健康检查</div>
        <div class="card-desc">后端服务存活探测。</div>
      </a>
    </section>
  </main>

  <footer class="footer">
    <span>firegraph — <a href="https://github.com/jlfwong/speedscope" target="_blank" rel="noopener">speedscope</a> · <a href="https://github.com/lsg2020/swt" target="_blank" rel="noopener">swt</a></span>
  </footer>
</body>
</html>
]===]

-- ===== 接口耗时页 =====
local TRACES_HTML = [===[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>接口耗时 — Firegraph</title>
  <link rel="stylesheet" href="/assets/app.css">
</head>
<body>
  <header class="topbar">
    <div class="topbar-inner">
      <h1 class="brand"><a href="/">Firegraph</a></h1>
      <nav class="nav">
        <a href="/" class="nav-link">首页</a>
        <a href="/firegraph" class="nav-link">火焰图</a>
        <a href="/traces.html" class="nav-link active">接口耗时</a>
      </nav>
    </div>
  </header>

  <main class="container">
    <section class="toolbar">
      <div class="toolbar-group">
        <label>service
          <input type="text" id="filter-service" placeholder="如 login" />
        </label>
        <label>cmd
          <input type="text" id="filter-cmd" placeholder="如 Login" />
        </label>
        <div class="range-group" role="group" aria-label="时间范围">
          <button class="btn range-btn active" data-range="3600">1h</button>
          <button class="btn range-btn" data-range="21600">6h</button>
          <button class="btn range-btn" data-range="86400">24h</button>
          <button class="btn range-btn" data-range="604800">7d</button>
        </div>
        <button id="btn-query" class="btn btn-primary">查询</button>
      </div>
    </section>

    <section class="axis-wrap">
      <div class="axis-header">
        <span class="axis-title">调用分组轴（每个点 = 一个时间窗内的全部调用）</span>
        <label class="axis-window">窗口 <input type="number" id="group-window" value="10" min="1" step="1" /> 秒</label>
        <label class="axis-window">最多 <input type="number" id="group-max" value="50" min="1" step="1" /> 组</label>
        <span class="axis-hint" id="trace-group-hint" hidden>已筛选 1 个分组 — <a href="javascript:void(0)" onclick="Firegraph.TracesPage.clearGroup()">清除</a></span>
      </div>
      <div id="trace-axis" class="axis-body"><div class="empty">加载中...</div></div>
    </section>

    <section class="stats-grid" id="stats-cards">
      <div class="stat-card"><div class="stat-label">总调用</div><div class="stat-value" id="stat-total">-</div></div>
      <div class="stat-card"><div class="stat-label">平均耗时</div><div class="stat-value" id="stat-avg">-<span class="unit">ms</span></div></div>
      <div class="stat-card"><div class="stat-label">P95</div><div class="stat-value" id="stat-p95">-<span class="unit">ms</span></div></div>
      <div class="stat-card"><div class="stat-label">P99</div><div class="stat-value" id="stat-p99">-<span class="unit">ms</span></div></div>
      <div class="stat-card"><div class="stat-label">慢调用(&gt;200ms)</div><div class="stat-value" id="stat-slow">-</div></div>
    </section>

    <section class="chart-wrap">
      <div class="chart-title">耗时趋势（Avg / P95 / P99，单位 ms）</div>
      <div id="chart"></div>
      <div class="chart-legend">
        <span class="legend-item"><span class="legend-dot" style="background:#2563eb"></span>Avg</span>
        <span class="legend-item"><span class="legend-dot" style="background:#dc2626"></span>P95</span>
        <span class="legend-item"><span class="legend-dot" style="background:#9333ea"></span>P99</span>
      </div>
    </section>

    <section class="table-wrap">
      <table class="data-table">
        <thead>
          <tr>
            <th>service</th>
            <th>cmd</th>
            <th class="num">调用数</th>
            <th class="num">P50</th>
            <th class="num">P95</th>
            <th class="num">P99</th>
            <th class="num">avg</th>
            <th class="num">max</th>
            <th>操作</th>
          </tr>
        </thead>
        <tbody id="stat-list">
          <tr><td colspan="9" class="empty">加载中...</td></tr>
        </tbody>
      </table>
    </section>

    <section id="detail-section" hidden>
      <h3 style="margin:16px 0 8px">明细：<span id="detail-title"></span></h3>
      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>时间</th>
              <th>service</th>
              <th>cmd</th>
              <th class="num">session</th>
              <th class="num">耗时(ms)</th>
              <th>状态</th>
            </tr>
          </thead>
          <tbody id="detail-list"></tbody>
        </table>
      </div>
    </section>
  </main>

  <script src="/assets/app.js"></script>
  <script>
    Firegraph.TracesPage.init();
  </script>
</body>
</html>
]===]

local APP_CSS = [===[
/* Firegraph 前端样式 — 极简、无框架 */
* { box-sizing: border-box; }
html, body {
  margin: 0;
  padding: 0;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "PingFang SC", "Microsoft YaHei", sans-serif;
  color: #1f2937;
  background: #f8fafc;
  font-size: 14px;
  line-height: 1.5;
}
a { color: #2563eb; text-decoration: none; }
a:hover { text-decoration: underline; }

/* topbar */
.topbar {
  background: #0f172a;
  color: #e2e8f0;
  border-bottom: 1px solid #1e293b;
}
.topbar-inner {
  max-width: 1200px;
  margin: 0 auto;
  padding: 0 24px;
  height: 56px;
  display: flex;
  align-items: center;
  gap: 32px;
}
.brand {
  margin: 0;
  font-size: 18px;
  font-weight: 600;
  color: #f8fafc;
}
.brand a { color: inherit; }
.nav { display: flex; gap: 8px; }
.nav-link {
  color: #cbd5e1;
  padding: 6px 12px;
  border-radius: 4px;
  font-size: 14px;
}
.nav-link:hover { background: #1e293b; text-decoration: none; }
.nav-link.active { background: #1d4ed8; color: #fff; }

/* container */
.container {
  max-width: 1200px;
  margin: 0 auto;
  padding: 24px;
}

/* toolbar */
.toolbar {
  display: flex;
  justify-content: space-between;
  align-items: flex-end;
  gap: 16px;
  margin-bottom: 16px;
  flex-wrap: wrap;
}
.toolbar-group {
  display: flex;
  gap: 12px;
  align-items: flex-end;
  flex-wrap: wrap;
}
.toolbar-group label {
  display: flex;
  flex-direction: column;
  font-size: 12px;
  color: #64748b;
  gap: 4px;
}
.toolbar-group input {
  padding: 6px 10px;
  border: 1px solid #cbd5e1;
  border-radius: 4px;
  font-size: 14px;
  min-width: 140px;
}
.toolbar-hint {
  background: #fef3c7;
  border: 1px solid #fcd34d;
  color: #92400e;
  padding: 8px 12px;
  border-radius: 4px;
  font-size: 13px;
}
.toolbar-hint code {
  background: rgba(0,0,0,.06);
  padding: 1px 6px;
  border-radius: 3px;
}

/* buttons */
.btn {
  padding: 6px 14px;
  border: 1px solid #cbd5e1;
  background: #fff;
  border-radius: 4px;
  cursor: pointer;
  font-size: 14px;
  color: #334155;
}
.btn:hover { background: #f1f5f9; }
.btn-primary {
  background: #2563eb;
  border-color: #2563eb;
  color: #fff;
}
.btn-primary:hover { background: #1d4ed8; }

/* table */
.table-wrap {
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  overflow: hidden;
}
.data-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}
.data-table th, .data-table td {
  padding: 10px 12px;
  text-align: left;
  border-bottom: 1px solid #f1f5f9;
}
.data-table th {
  background: #f8fafc;
  font-weight: 600;
  color: #475569;
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: .03em;
}
.data-table tbody tr:hover { background: #f8fafc; }
.data-table .empty { text-align: center; color: #94a3b8; padding: 32px; }
.data-table .num { text-align: right; font-variant-numeric: tabular-nums; }
.data-table .actions { display: flex; gap: 8px; flex-wrap: wrap; }
.data-table .actions .btn { padding: 3px 10px; font-size: 12px; }

/* hero */
.hero { margin-bottom: 32px; }
.hero h2 { margin: 0 0 8px; font-size: 24px; }
.hero-sub { margin: 0; color: #64748b; }

/* cards */
.cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
  gap: 16px;
}
.card {
  display: block;
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  padding: 20px;
  color: inherit;
  transition: box-shadow .15s, border-color .15s;
}
.card:hover {
  border-color: #93c5fd;
  box-shadow: 0 4px 12px rgba(37, 99, 235, .08);
  text-decoration: none;
}
.card-icon { font-size: 28px; margin-bottom: 8px; }
.card-title { font-weight: 600; margin-bottom: 4px; }
.card-desc { color: #64748b; font-size: 13px; }

/* footer */
.footer {
  text-align: center;
  color: #94a3b8;
  padding: 24px;
  font-size: 12px;
}

/* trace page */
.stats-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 12px;
  margin-bottom: 16px;
}
.stat-card {
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  padding: 14px 16px;
}
.stat-label { font-size: 12px; color: #64748b; }
.stat-value { font-size: 22px; font-weight: 600; margin-top: 4px; font-variant-numeric: tabular-nums; }
.chart-wrap {
  background: #fff;
  border: 1px solid #e2e8f0;
  border-radius: 8px;
  padding: 16px;
  margin-bottom: 16px;
}
.chart-title { font-weight: 600; margin-bottom: 8px; }
#chart { width: 100%; height: 320px; }
#chart .empty { text-align: center; color: #94a3b8; padding: 80px 0; }

/* range buttons */
.range-group {
  display: inline-flex;
  gap: 0;
  border: 1px solid #cbd5e1;
  border-radius: 4px;
  overflow: hidden;
}
.range-group .range-btn {
  border: none;
  border-right: 1px solid #cbd5e1;
  border-radius: 0;
  padding: 7px 12px;
  background: #fff;
  font-size: 13px;
}
.range-group .range-btn:last-child { border-right: none; }
.range-group .range-btn.active { background: #2563eb; color: #fff; }
.range-group .range-btn:hover:not(.active) { background: #f1f5f9; }

/* stat unit */
.stat-value .unit { font-size: 12px; color: #94a3b8; margin-left: 4px; font-weight: 400; }

/* chart legend */
.chart-legend {
  display: flex;
  gap: 16px;
  margin-top: 8px;
  font-size: 12px;
  color: #64748b;
}
.legend-item { display: inline-flex; align-items: center; gap: 6px; }
.legend-dot {
  display: inline-block;
  width: 10px;
  height: 10px;
  border-radius: 2px;
}

/* highlight cells */
.data-table .warn { color: #d97706; font-weight: 600; }
.data-table .crit { color: #dc2626; font-weight: 600; }
.data-table .ok { color: #16a34a; }
.data-table .fail { color: #dc2626; }

/* time group axis */
.axis-wrap {
  background: #fff;
  border: 1px solid #e5e7eb;
  border-radius: 8px;
  margin-bottom: 16px;
  padding: 12px 16px;
}
.axis-header {
  display: flex;
  align-items: center;
  gap: 16px;
  margin-bottom: 8px;
}
.axis-title {
  font-weight: 600;
  color: #374151;
}
.axis-window {
  font-size: 13px;
  color: #6b7280;
}
.axis-window input {
  width: 56px;
  padding: 4px 6px;
  border: 1px solid #d1d5db;
  border-radius: 6px;
  font-size: 13px;
}
.axis-hint {
  font-size: 13px;
  color: #dc2626;
}
.axis-hint a { margin-left: 4px; }
.axis-body { min-height: 76px; }
]===]

-- ===== Speedscope 静态文件路径 =====
-- symlink 下 gardenserver 的根目录
local speedscope_root = nil
local function get_speedscope_root()
    if speedscope_root then return speedscope_root end
    -- 尝试找 speedscope 目录
    local cwd = os.getenv("PWD") or ""
    -- 在 WSL 环境中，目录可能是 /mnt/d/MyPoj/gardenserver
    -- 也可能是 /data/home/xxx/ 通过 symlink
    local paths = {
        "/mnt/d/MyPoj/firegraph/web/assets/vendor/speedscope",
        "/mnt/d/MyPoj/gardenserver/vendor/speedscope",
    }
    for _, p in ipairs(paths) do
        local f = io.open(p .. "/index.html", "r")
        if f then
            f:close()
            speedscope_root = p
            return p
        end
    end
    return nil
end

local function serve_static_file(request)
    local root = get_speedscope_root()
    if not root then
        http_helper.response(request.id, 404, "speedscope not found")
        return
    end
    -- router wildcard 捕获的相对路径（不含 /assets/vendor/speedscope/ 前缀）
    local rel = request.path or ""
    if rel == "/assets/vendor/speedscope" or rel == "" then
        rel = "index.html"
    end
    local fpath = root .. "/" .. rel
    local f = io.open(fpath, "rb")
    if not f then
        http_helper.response(request.id, 404, "file not found: " .. rel)
        return
    end
    local content = f:read("*a")
    f:close()

    -- Content-Type 映射
    local ext = rel:match("%.([^.]+)$")
    local ct_map = {
        html = "text/html; charset=utf-8",
        js = "application/javascript; charset=utf-8",
        css = "text/css; charset=utf-8",
        json = "application/json; charset=utf-8",
        txt = "text/plain; charset=utf-8",
        woff2 = "font/woff2",
        png = "image/png",
        ico = "image/x-icon",
    }
    local ct = ct_map[ext] or "application/octet-stream"

    local header = {
        ["Content-Type"] = ct,
        ["Connection"] = "close",
        ["Access-Control-Allow-Origin"] = "*",
    }
    local socket = require "skynet.socket"
    local sockethelper = require "http.sockethelper"
    local httpd = require "http.httpd"
    httpd.write_response(sockethelper.writefunc(request.id), 200, content, header)
    socket.close(request.id)
end

-- ===== Profile 查找辅助 =====
-- 按 id 查找 profile，找不到返回 nil
local function find_profile(id)
    for i = 1, max_cache do
        local idx = ((cache_index - i) % max_cache) + 1
        local p = cache[idx]
        if p and p.id == id then
            return p
        end
    end
    return nil
end

-- 最新一条 profile（缓存为空返回 nil）
local function latest_profile()
    return cache[cache_index]
end

-- ===== API: Profile 列表 =====
local function handle_profile_list(request)
    local query = request.query or {}
    local filter_service = query["service"]
    local filter_node = query["node"]
    local limit = tonumber(query["limit"]) or 200

    local items = {}
    local count = 0
    -- 遍历缓存（从最新到最旧）
    for i = 1, max_cache do
        local idx = ((cache_index - i) % max_cache) + 1
        local p = cache[idx]
        if p then
            -- 筛选
            if filter_service and filter_service ~= "" and p.service ~= filter_service then
                -- skip
            elseif filter_node and filter_node ~= "" and p.node ~= filter_node then
                -- skip
            else
                table.insert(items, {
                    id = p.id,
                    service_name = p.service,
                    node = p.node,
                    sampled_at = p.time,
                    duration_sec = 10,
                    sample_count = p.total,
                })
                count = count + 1
                if count >= limit then break end
            end
        end
    end

    http_helper.response(request.id, 200, {items = json_array(items)})
end

-- ===== API: Profile 时间分组（供时间轴使用）=====
local function handle_profile_groups(request)
    local query = request.query or {}
    local window = tonumber(query["window"]) or 10
    if not window or window < 1 then window = 1 end
    local limit = tonumber(query["limit"]) or 50
    if not limit or limit < 1 then limit = 50 end
    local filter_service = query["service"]
    local filter_node = query["node"]

    local buckets = {}
    for i = 1, max_cache do
        local idx = ((cache_index - i) % max_cache) + 1
        local p = cache[idx]
        if p then
            if (not filter_service or filter_service == "" or p.service == filter_service)
                and (not filter_node or filter_node == "" or p.node == filter_node) then
                local b = math.floor(p.time / window) * window
                local g = buckets[b]
                if not g then
                    g = {ts = b, count = 0}
                    buckets[b] = g
                end
                g.count = g.count + 1
            end
        end
    end

    local keys = {}
    for b in pairs(buckets) do keys[#keys + 1] = b end
    table.sort(keys)

    local items = {}
    local start = math.max(1, #keys - limit + 1)
    for i = start, #keys do
        local b = keys[i]
        items[#items + 1] = {ts = b, count = buckets[b].count}
    end
    http_helper.response(request.id, 200, {items = json_array(items)})
end

-- ===== API: 单个 Profile 详情 =====
local function handle_profile_get(request, id)
    local p = find_profile(id) or latest_profile()
    if p then
        http_helper.response(request.id, 200, {
            id = p.id,
            service_name = p.service,
            node = p.node,
            sampled_at = p.time,
            duration_sec = 10,
            sample_count = p.total,
            folded_text = p.folded,
        })
        return
    end
    http_helper.response(request.id, 404, "not found")
end

-- ===== API: Speedscope JSON =====
local function handle_speedscope(request, id)
    local p = find_profile(id) or latest_profile()
    if p then
        local name = string.format("%s@%s %s",
            p.service, p.node,
            os.date("%Y-%m-%d %H:%M:%S", p.time))
        local ss_json = folded_to_speedscope(p.folded, name)

        local header = {
            ["Content-Type"] = "application/json; charset=utf-8",
            ["Connection"] = "close",
            ["Access-Control-Allow-Origin"] = "*",
        }
        local socket = require "skynet.socket"
        local sockethelper = require "http.sockethelper"
        local httpd = require "http.httpd"
        httpd.write_response(sockethelper.writefunc(request.id), 200, ss_json, header)
        socket.close(request.id)
        return
    end
    http_helper.response(request.id, 404, "not found")
end

-- ===== API: Folded Text =====
local function handle_folded(request, id)
    local p = find_profile(id) or latest_profile()
    if p then
        local header = {
            ["Content-Type"] = "text/plain; charset=utf-8",
            ["Connection"] = "close",
        }
        local socket = require "skynet.socket"
        local sockethelper = require "http.sockethelper"
        local httpd = require "http.httpd"
        httpd.write_response(sockethelper.writefunc(request.id), 200, p.folded, header)
        socket.close(request.id)
        return
    end
    http_helper.response(request.id, 404, "not found")
end

-- ===== 接口耗时 API 辅助 =====
local function trace_within(t, from, to, filter_service, filter_cmd)
    if from and t.ts < from then return false end
    if to and t.ts > to then return false end
    if filter_service and filter_service ~= "" and t.service ~= filter_service then return false end
    if filter_cmd and filter_cmd ~= "" and t.cmd ~= filter_cmd then return false end
    return true
end

local function percentile(sorted, p)
    local n = #sorted
    if n == 0 then return 0 end
    if n == 1 then return sorted[1] end
    local idx = math.ceil(p * n)
    if idx < 1 then idx = 1 end
    if idx > n then idx = n end
    return sorted[idx]
end

-- 解析公共查询参数
local function parse_trace_query(request)
    local query = request.query or {}
    -- 重复 key 会被解析成 table，取最后一个值（script 里追加的参数）
    local function qval(v)
        if type(v) == "table" then
            return v[#v]
        end
        return v
    end
    return {
        from = tonumber(qval(query["from"])),
        to = tonumber(qval(query["to"])),
        service = qval(query["service"]),
        cmd = qval(query["cmd"]),
        limit = tonumber(qval(query["limit"])) or 100,
        bucket_sec = tonumber(qval(query["bucket_sec"])) or 60,
    }
end

-- /api/traces/stats：按 service+cmd 聚合出 count/p50/p95/p99/avg/max
local function handle_traces_stats(request)
    local q = parse_trace_query(request)
    local groups = {}
    local order = {}
    for _, t in ipairs(traces) do
        if trace_within(t, q.from, q.to, q.service, q.cmd) then
            local key = tostring(t.service) .. "\0" .. tostring(t.cmd)
            local g = groups[key]
            if not g then
                g = {service = t.service, cmd = t.cmd, costs = {}}
                groups[key] = g
                order[#order + 1] = g
            end
            g.costs[#g.costs + 1] = t.cost_ms
        end
    end

    local items = {}
    for _, g in ipairs(order) do
        table.sort(g.costs)
        local n = #g.costs
        local sum = 0
        for _, c in ipairs(g.costs) do sum = sum + c end
        items[#items + 1] = {
            service = g.service,
            cmd = g.cmd,
            count = n,
            p50_ms = percentile(g.costs, 0.50),
            p95_ms = percentile(g.costs, 0.95),
            p99_ms = percentile(g.costs, 0.99),
            avg_ms = math.floor(sum / n),
            max_ms = g.costs[n],
        }
    end

    -- 按调用数降序
    table.sort(items, function(a, b) return a.count > b.count end)
    http_helper.response(request.id, 200, {items = json_array(items)})
end

-- /api/traces/timeseries：按 bucket_sec 分桶出 avg/p95/p99
local function handle_traces_timeseries(request)
    local q = parse_trace_query(request)
    local buckets = {}
    for _, t in ipairs(traces) do
        if trace_within(t, q.from, q.to, q.service, q.cmd) then
            local b = math.floor(t.ts / q.bucket_sec) * q.bucket_sec
            local g = buckets[b]
            if not g then
                g = {ts = b, costs = {}}
                buckets[b] = g
            end
            g.costs[#g.costs + 1] = t.cost_ms
        end
    end

    local keys = {}
    for b in pairs(buckets) do keys[#keys + 1] = b end
    table.sort(keys)

    local items = {}
    for _, b in ipairs(keys) do
        local g = buckets[b]
        table.sort(g.costs)
        local n = #g.costs
        local sum = 0
        for _, c in ipairs(g.costs) do sum = sum + c end
        items[#items + 1] = {
            ts = b,
            avg_ms = math.floor(sum / n),
            p95_ms = percentile(g.costs, 0.95),
            p99_ms = percentile(g.costs, 0.99),
        }
    end
    http_helper.response(request.id, 200, {items = json_array(items)})
end

-- /api/traces/groups：按时间窗口统计每组的调用数（供时间轴使用）
local function handle_traces_groups(request)
    local q = parse_trace_query(request)
    local query = request.query or {}
    local window = query["window"]
    if type(window) == "table" then window = window[#window] end
    window = tonumber(window) or 10
    if window < 1 then window = 1 end
    local limit = tonumber(query["limit"]) or 50
    if not limit or limit < 1 then limit = 50 end

    local buckets = {}
    for _, t in ipairs(traces) do
        if trace_within(t, q.from, q.to, q.service, q.cmd) then
            local b = math.floor(t.ts / window) * window
            local g = buckets[b]
            if not g then
                g = {ts = b, count = 0}
                buckets[b] = g
            end
            g.count = g.count + 1
        end
    end

    local keys = {}
    for b in pairs(buckets) do keys[#keys + 1] = b end
    table.sort(keys)

    local items = {}
    local start = math.max(1, #keys - limit + 1)
    for i = start, #keys do
        local b = keys[i]
        items[#items + 1] = {ts = b, count = buckets[b].count}
    end
    http_helper.response(request.id, 200, {items = json_array(items)})
end

-- /api/traces：明细列表（按时间倒序）
local function handle_traces_list(request)
    local q = parse_trace_query(request)
    local matched = {}
    for _, t in ipairs(traces) do
        if trace_within(t, q.from, q.to, q.service, q.cmd) then
            matched[#matched + 1] = t
        end
    end
    table.sort(matched, function(a, b) return a.ts > b.ts end)

    local items = {}
    local cnt = math.min(q.limit, #matched)
    for i = 1, cnt do
        local t = matched[i]
        items[#items + 1] = {
            ts = t.ts,
            service = t.service,
            cmd = t.cmd,
            session = t.session,
            cost_ms = t.cost_ms,
            ok = t.ok == 1,
        }
    end
    http_helper.response(request.id, 200, {items = json_array(items)})
end

-- ===== 实时火焰图查看页 =====
local VIEWER_HTML = [===[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>实时火焰图 — Firegraph</title>
  <link rel="stylesheet" href="/assets/app.css">
  <style>
    body.viewer-page { height: 100vh; display: flex; flex-direction: column; overflow: hidden; }
    body.viewer-page .topbar { flex-shrink: 0; }
    body.viewer-page main { flex: 1; display: flex; flex-direction: column; overflow: hidden; padding: 0; max-width: none; }
    .view-toolbar { display: flex; align-items: center; gap: 12px; padding: 10px 24px; background: #fff; border-bottom: 1px solid #e2e8f0; flex-shrink: 0; flex-wrap: wrap; }
    .view-toolbar .title { font-size: 14px; font-weight: 600; color: #1f2937; margin-right: auto; }
    .view-toolbar .status { font-size: 12px; color: #64748b; display: flex; align-items: center; gap: 4px; }
    .view-toolbar .dot { width: 8px; height: 8px; border-radius: 50%; }
    .dot.live { background: #22c55e; animation: pulse 1.5s infinite; }
    .dot.paused { background: #f59e0b; }
    @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: .4; } }
    .btn-warn.view-btn { background: #f59e0b; border-color: #f59e0b; color: #fff; }
    .btn-warn.view-btn:hover { background: #d97706; }
    .info { font-size: 12px; color: #94a3b8; }
    iframe { flex: 1; border: none; width: 100%; }
  </style>
</head>
<body class="viewer-page">
  <header class="topbar">
    <div class="topbar-inner">
      <h1 class="brand"><a href="/">Firegraph</a></h1>
      <nav class="nav">
        <a href="/" class="nav-link">首页</a>
        <a href="/firegraph" class="nav-link active">火焰图</a>
        <a href="/traces.html" class="nav-link">接口耗时</a>
      </nav>
    </div>
  </header>
  <main>
    <div class="view-toolbar">
      <span class="title" id="title">加载中...</span>
      <button class="btn btn-warn view-btn" id="btn-pause" onclick="togglePause()">暂停</button>
      <button class="btn" id="btn-save" onclick="saveFile()">保存文件</button>
      <span class="status">
        <span class="dot live" id="status-dot"></span>
        <span id="status-text">实时更新中</span>
      </span>
      <span class="info" id="update-time"></span>
    </div>
    <iframe id="frame" src="" allow="clipboard-write"></iframe>
  </main>

  <script>
    var params = new URLSearchParams(location.search);
    var currentPid = params.get('pid') || '';
    var currentService = params.get('service') || '';

    document.title = currentService + ' #' + currentPid + ' — 实时火焰图';
    document.getElementById('title').textContent = currentService + ' #' + currentPid;

    var isPaused = false;
    var lastUpdate = '';
    var currentProfileUrl = '';

    function loadProfile(pid, service) {
      currentPid = pid || currentPid;
      currentService = service || currentService;
      if (!currentPid) return;
      currentProfileUrl = location.origin + '/api/profiles/' + currentPid + '/folded.collapsedstack.txt';
      var label = currentService + ' #' + currentPid;
      var ssUrl = '/assets/vendor/speedscope/index.html#profileURL=' +
        encodeURIComponent(currentProfileUrl) + '&title=' + encodeURIComponent(label);
      document.getElementById('frame').src = ssUrl;
      var now = new Date();
      lastUpdate = now.toLocaleTimeString('zh-CN');
      document.getElementById('update-time').textContent = '最后更新: ' + lastUpdate;
      document.title = label + ' — 实时火焰图';
      document.getElementById('title').textContent = label;
    }

    function togglePause() {
      isPaused = !isPaused;
      var dot = document.getElementById('status-dot');
      var text = document.getElementById('status-text');
      var btn = document.getElementById('btn-pause');
      if (isPaused) {
        dot.className = 'dot paused';
        text.textContent = '已暂停';
        btn.textContent = '继续';
        btn.className = 'btn btn-primary view-btn';
      } else {
        dot.className = 'dot live';
        text.textContent = '实时更新中';
        btn.textContent = '暂停';
        btn.className = 'btn btn-warn view-btn';
      }
    }

    function saveFile() {
      if (!currentProfileUrl) return alert('暂无数据可保存');
      fetch(currentProfileUrl)
        .then(function(r) { return r.blob(); })
        .then(function(blob) {
          var a = document.createElement('a');
          var name = (currentService || 'flamegraph') + '_' + currentPid + '.collapsedstack.txt';
          a.href = URL.createObjectURL(blob);
          a.download = name;
          a.click();
          URL.revokeObjectURL(a.href);
        })
        .catch(function(e) { alert('保存失败: ' + e.message); });
    }

    // 初始加载
    loadProfile(currentPid, currentService);

    // WebSocket 实时推送
    var wsUrl = 'ws://' + location.host + '/firegraph/ws';
    function wsConnect() {
      var ws = new WebSocket(wsUrl);
      ws.onmessage = function(evt) {
        try {
          var data = JSON.parse(evt.data);
          if (data.id && !isPaused) {
            loadProfile('' + data.id, data.service || currentService);
          }
        } catch(e) {}
      };
      ws.onclose = function() { setTimeout(wsConnect, 2000); };
      ws.onerror = function() { ws.close(); };
    }
    wsConnect();
  </script>
</body>
</html>
]===]

-- ===== 路由注册 =====
return function(router, command)
    -- GET / -- 首页
    router:get("/", function(request)
        http_helper.response(request.id, 200, INDEX_HTML)
    end)

    -- GET /traces.html -- 接口耗时
    router:get("/traces.html", function(request)
        http_helper.response(request.id, 200, TRACES_HTML)
    end)

    -- GET /firegraph -- profiles.html
    router:get("/firegraph", function(request)
        http_helper.response(request.id, 200, PROFILES_HTML)
    end)

    -- GET /firegraph/view -- 实时火焰图查看
    router:get("/firegraph/view", function(request)
        http_helper.response(request.id, 200, VIEWER_HTML)
    end)

    -- 健康检查
    router:get("/healthz", function(request)
        http_helper.response(request.id, 200, {ok = true})
    end)

    -- 静态资源
    router:get("/assets/app.js", function(request)
        http_helper.response(request.id, 200, APP_JS)
    end)
    router:get("/assets/app.css", function(request)
        http_helper.response(request.id, 200, APP_CSS)
    end)

    -- Speedscope 离线包（从文件系统读取）
    router:get("/assets/vendor/speedscope/*path", function(request)
        serve_static_file(request)
    end)

    -- API 端点（:pid 而非 :id，避免覆盖 request.id / HTTP fd）
    router:get("/api/profiles", handle_profile_list)
    router:get("/api/profiles/groups", handle_profile_groups)
    router:get("/api/profiles/:pid", function(params)
        handle_profile_get(params, tonumber(params.pid))
    end)
    router:get("/api/profiles/:pid/speedscope.json", function(params)
        handle_speedscope(params, tonumber(params.pid))
    end)
    router:get("/api/profiles/:pid/folded.txt", function(params)
        handle_folded(params, tonumber(params.pid))
    end)
    -- Speedscope 折叠栈格式（.collapsedstack.txt 后缀触发其原始文本导入路径，避免 JSON inflate 陷阱）
    router:get("/api/profiles/:pid/folded.collapsedstack.txt", function(params)
        handle_folded(params, tonumber(params.pid))
    end)

    -- Traces API — 接口耗时数据（内存聚合）
    router:get("/api/traces/stats", handle_traces_stats)
    router:get("/api/traces/timeseries", handle_traces_timeseries)
    router:get("/api/traces/groups", handle_traces_groups)
    router:get("/api/traces", handle_traces_list)

    -- WebSocket /firegraph/ws -- 实时推送（保留兼容）
    local ws_handler = {
        connect = function(id) ws_clients[id] = true end,
        message = function() end,
        close = function(id) ws_clients[id] = nil end,
        error = function(id) ws_clients[id] = nil end,
    }
    router:get("/firegraph/ws", function(request)
        http_helper.upgrade(ws_handler, request)
    end)

    -- skynet 命令：接收来自 monitor 的 profile 数据
    command.fg_profile = function(body_json)
        local ok, data = pcall(json.decode, body_json)
        if ok then
            add_profile(
                data.node or "?",
                data.service or "?",
                data.time or os.time(),
                data.folded or "",
                data.total or 0
            )
        end
    end

    -- skynet 命令：接收来自 tracer 的接口耗时批量数据
    command.fg_traces = function(body_json)
        local ok, data = pcall(json.decode, body_json)
        if ok and type(data) == "table" and type(data.traces) == "table" then
            add_traces(data.traces)
        end
    end
end