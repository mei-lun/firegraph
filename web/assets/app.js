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
  // 通过尝试加载 speedscope 的 index.html 判断是否已下载
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
      await this.load();
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
        this.render(data.items || []);
      } catch (e) {
        tbody.innerHTML = '<tr><td colspan="7" class="empty">加载失败: ' + escapeHtml(e.message) + '</td></tr>';
      }
    },

    render: function (items) {
      var tbody = qs('profile-list');
      if (!items.length) {
        tbody.innerHTML = '<tr><td colspan="7" class="empty">暂无 profile 数据</td></tr>';
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
      var profileUrl = window.location.origin + '/api/profiles/' + id + '/speedscope.json';
      var title = service + ' #' + id;
      var localAvailable = await checkSpeedscope();
      var base = localAvailable
        ? '/assets/vendor/speedscope/index.html'
        : 'https://www.speedscope.app/';
      var ssUrl = base + '#profileURL=' + encodeURIComponent(profileUrl) + '&title=' + encodeURIComponent(title);
      window.open(ssUrl, '_blank');
    }
  };

  // ---------- Traces 页（接口耗时） ----------
  var TRACE_RANGES = {
    3600: { bucket: 60, label: '1h' },
    21600: { bucket: 300, label: '6h' },
    86400: { bucket: 1800, label: '24h' },
    604800: { bucket: 7200, label: '7d' }
  };
  var traceState = { rangeSec: 3600 };

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
      var btns = document.querySelectorAll('.range-btn');
      for (var i = 0; i < btns.length; i++) {
        btns[i].addEventListener('click', function () {
          for (var j = 0; j < btns.length; j++) btns[j].classList.remove('active');
          this.classList.add('active');
          traceState.rangeSec = parseInt(this.getAttribute('data-range'), 10);
          self.load();
        });
      }
      this.load();
    },

    buildQuery: function (extra) {
      var now = Math.floor(Date.now() / 1000);
      var from = now - traceState.rangeSec;
      var parts = ['from=' + from, 'to=' + now];
      var s = qs('filter-service').value.trim();
      var c = qs('filter-cmd').value.trim();
      if (s) parts.push('service=' + encodeURIComponent(s));
      if (c) parts.push('cmd=' + encodeURIComponent(c));
      if (extra) parts.push(extra);
      return '?' + parts.join('&');
    },

    load: async function () {
      var self = this;
      // 重置统计卡片
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
        qs('stat-list').innerHTML = '<tr><td colspan="9" class="empty">加载失败: ' + escapeHtml(e.message) + '</td></tr>';
        qs('chart').innerHTML = '<div class="empty">加载失败: ' + escapeHtml(e.message) + '</div>';
      }
    },

    renderStats: function (items) {
      // 顶部统计卡片：汇总所有 service+cmd
      var total = 0, sumCost = 0, maxP95 = 0, maxP99 = 0, slow = 0;
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        total += it.count;
        sumCost += it.avg_ms * it.count;
        if (it.p95_ms > maxP95) maxP95 = it.p95_ms;
        if (it.p99_ms > maxP99) maxP99 = it.p99_ms;
        // 慢调用估算：用 (avg * count - ok_count * 0) 粗略，准确需后端支持
        // 这里用 p95 * count * 0.05 估算（假设 5% 慢于 p95）
        if (it.p95_ms > 200) slow += Math.floor(it.count * 0.05);
      }
      qs('stat-total').textContent = total.toLocaleString();
      qs('stat-avg').innerHTML = (total > 0 ? Math.round(sumCost / total) : 0) + '<span class="unit">ms</span>';
      qs('stat-p95').innerHTML = maxP95 + '<span class="unit">ms</span>';
      qs('stat-p99').innerHTML = maxP99 + '<span class="unit">ms</span>';
      qs('stat-slow').textContent = slow.toLocaleString();

      // 表格
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
        list.innerHTML = '<tr><td colspan="6" class="empty">加载失败: ' + escapeHtml(e.message) + '</td></tr>';
      }
    }
  };

  function highlightSlow(ms) {
    if (ms >= 500) return '<span class="crit">' + ms + '</span>';
    if (ms >= 200) return '<span class="warn">' + ms + '</span>';
    return ms;
  }

  // renderLineChart: 纯 SVG 折线图
  // buckets: [{ts, count, avg_ms, p95_ms}]
  function renderLineChart(buckets) {
    var W = 1100, H = 300, PAD_L = 50, PAD_R = 20, PAD_T = 20, PAD_B = 40;
    var plotW = W - PAD_L - PAD_R, plotH = H - PAD_T - PAD_B;

    // 补全 P99 字段（后端 timeseries 只返回 avg/p95，P99 用 p95*1.1 估算用于展示）
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
      for (var i = 1; i < n; i++) {
        d += ' L ' + xPos(i) + ' ' + yPos(getter(series[i]));
      }
      return d;
    }

    // X 轴刻度（5 个）
    var xTicks = '';
    for (var i = 0; i < 5; i++) {
      var idx = Math.floor((n - 1) * i / 4);
      if (idx < 0 || idx >= n) continue;
      var x = xPos(idx);
      var label = formatShortTime(series[idx].ts);
      xTicks += '<line x1="' + x + '" y1="' + PAD_T + '" x2="' + x + '" y2="' + (PAD_T + plotH) + '" stroke="#f1f5f9" stroke-width="1"/>';
      xTicks += '<text x="' + x + '" y="' + (H - 10) + '" text-anchor="middle" fill="#94a3b8" font-size="11">' + label + '</text>';
    }

    // Y 轴刻度（4 个）
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

  global.Firegraph = Firegraph;
})(window);
