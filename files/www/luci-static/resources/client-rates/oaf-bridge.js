/* client-rates OAF bridge: 把硬件加速校正后的真实速率注入 OAF 仪表盘/终端列表 */
(function () {
	'use strict';
	if (window.__crBridgeLoaded) return;
	window.__crBridgeLoaded = true;

	var timer = null, data = null;

	function sid() {
		try { return (window.L && L.env && L.env.sessionid) || null; } catch (e) { return null; }
	}

	function fmtRate(b) {
		b = b || 0;
		if (b >= 1048576) return (b / 1048576).toFixed(2) + ' MB/s';
		if (b >= 1024) return (b / 1024).toFixed(1) + ' KB/s';
		return b + ' B/s';
	}

	function fmtBytes(b) {
		b = b || 0;
		if (b >= 1073741824) return (b / 1073741824).toFixed(2) + ' GB';
		if (b >= 1048576) return (b / 1048576).toFixed(1) + ' MB';
		if (b >= 1024) return (b / 1024).toFixed(1) + ' KB';
		return b + ' B';
	}

	/* 只在内容真正变化时才写 DOM, 避免每秒无谓重排(表格闪烁/额外行) */
	function setHtml(el, html) {
		if (el && el.__crHtml !== html) { el.__crHtml = html; el.innerHTML = html; }
	}

	function setText(el, txt) {
		if (el && el.textContent !== txt) el.textContent = txt;
	}

	/* 覆写单元格文本, 保留单元格内 <span> 原有的颜色样式 */
	function setCell(row, sel, txt) {
		var cell = row.querySelector(sel);
		if (!cell) return false;
		setText(cell.querySelector('span') || cell, txt);
		return true;
	}

	function call(cb) {
		var s = sid();
		if (!s) return;
		fetch('/ubus', {
			method: 'POST',
			credentials: 'same-origin',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({
				jsonrpc: '2.0', id: 1, method: 'call',
				params: [s, 'luci.client_rates', 'status', {}]
			})
		}).then(function (r) { return r.json(); }).then(function (j) {
			var d = j && j.result && j.result[1];
			if (d && d.wan) { data = d; cb(d); }
		}).catch(function () { });
	}

	/* ---------- 仪表盘 ---------- */
	function patchDashboard(d) {
		var wan = d.wan || {};

		/* OAF 自带的"今日流量"卡片: 直接换成校正后的总流量 */
		var mini = document.getElementById('mini-traffic');
		if (mini) {
			mini.title = '今日总流量（硬件加速校正后）';
			setText(mini, fmtBytes((wan.up_today || 0) + (wan.down_today || 0)));
		}

		/* 在 .top-stats 里追加一张"实时速率"卡片, 沿用它自己的 mini 卡片样式 */
		var stats = document.querySelector('.top-stats');
		if (!stats) {
			var anchor = document.getElementById('wan-realtime-rate');
			if (!anchor || !anchor.parentNode) return;
			stats = anchor.parentNode;
		}
		var box = document.getElementById('cr-wan-rate');
		if (!box) {
			box = document.createElement('div');
			box.className = 'mini';
			box.id = 'cr-wan-rate';
			box.innerHTML = '<div class="stat-head"><span class="stat-label">实时速率</span>' +
				'<span class="stat-icon icon-flow" aria-hidden="true"></span></div>' +
				'<div class="top-stat-value" id="cr-wan-rate-v" style="font-size:16px;line-height:1.5">-</div>';
			stats.appendChild(box);
		}
		var v = document.getElementById('cr-wan-rate-v');
		if (v)
			setHtml(v, '<span style="color:#2f7ed8">↓ ' + fmtRate(wan.down) + '</span>' +
				'<br><span style="color:#e08b2c">↑ ' + fmtRate(wan.up) + '</span>');
	}

	/* ---------- 终端列表 ---------- */
	var MAC_RE = /([0-9a-f]{2}(?::[0-9a-f]{2}){5})/i;
	var DATA_RE = /([0-9a-f]{2}(?:-[0-9a-f]{2}){5})/i;

	function rowsOf() {
		var root = document.getElementById('user_table_wrapper') ||
			document.getElementById('user_status_cards') || document.body;
		return root.querySelectorAll('tr, .user-card, .card-item');
	}

	function patchRows(d) {
		if (!document.getElementById('user_table_wrapper') && !document.getElementById('user_status_cards'))
			return;
		var map = {}, byIp = {};
		(d.clients || []).forEach(function (c) {
			if (c.mac) map[c.mac.toLowerCase()] = c;
			if (c.ip) byIp[c.ip] = c;
		});

		var rows = rowsOf();
		for (var i = 0; i < rows.length; i++) {
			var row = rows[i];
			if (row.querySelector('th')) continue;
			var c = null;
			var m = MAC_RE.exec(row.innerHTML) || DATA_RE.exec(row.innerHTML);
			if (m) {
				var mac = m[1].replace(/-/g, ':').toLowerCase();
				c = map[mac] || null;
			}
			if (!c) {
				var im = /(?:^|[^0-9])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?:[^0-9]|$)/.exec(row.innerText || '');
				if (im) c = byIp[im[1]] || null;
			}

			/* 优先覆写 OAF 自带的上下行速率列: 不新增任何节点, 不改变列宽与行高 */
			var did = false;
			if (c) {
				did = setCell(row, '.user-col-up-rate', fmtRate(c.up)) || did;
				did = setCell(row, '.user-col-down-rate', fmtRate(c.down)) || did;
			}
			if (did) {
				/* 清掉旧版可能残留在操作列的徽标 */
				var stale = row.querySelector('.cr-rate');
				if (stale) stale.parentNode.removeChild(stale);
				continue;
			}

			/* 回退: 表格没有原生速率列时, 才追加一个徽标 */
			var span = row.querySelector('.cr-rate');
			if (!c) { if (span) span.parentNode.removeChild(span); continue; }
			if (!span) {
				span = document.createElement('span');
				span.className = 'cr-rate';
				span.style.cssText = 'display:inline-block;margin-left:8px;font-size:12px;white-space:nowrap';
				var host = row.lastElementChild || row;
				host.appendChild(span);
			}
			setHtml(span, '<span style="color:#2f7ed8">↓' + fmtRate(c.down) + '</span>' +
				'<span style="color:#e08b2c;margin-left:6px">↑' + fmtRate(c.up) + '</span>');
		}
	}

	function tick() {
		if (document.hidden) return;
		call(function (d) {
			data = d;
			watchTable();
			patchDashboard(d);
			patchRows(d);
		});
	}

	/* OAF 每 3 秒会整表重建(先 remove 再 append), 重建后速率会短暂回落成它自己的旧值。
	   监听 tbody 变化, 一重建就立即覆写, 避免数字闪跳。 */
	function watchTable() {
		var tb = document.getElementById('user_status_table');
		if (!tb || tb.__crWatched || !window.MutationObserver) return;
		tb.__crWatched = true;
		new MutationObserver(function () {
			if (data) patchRows(data);
		}).observe(tb, { childList: true });
	}

	function start() {
		if (timer) return;
		timer = setInterval(tick, 1000);
		tick();
	}

	if (document.readyState === 'loading')
		document.addEventListener('DOMContentLoaded', start);
	else
		start();
})();
