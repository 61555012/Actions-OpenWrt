/* client-rates OAF bridge v6
 *
 * 目的: 让 OAF 各处的「速率 / 流量」显示使用硬件加速(HNAT)下的真实统计值。
 *   - 仪表盘: 今日流量卡片、实时速率卡片、流量统计图(今日 24h)、用户流量排行
 *   - 终端列表: 上行/下行速率、今日流量
 *   - 用户详情: 今日上行/下行、24 小时流量图
 *
 * 做法分两层:
 *   1) 数据层 hook: 包裹 OAF 自己的渲染函数, 渲染前把数据换成我们的值 —— 无闪烁、无竞态;
 *   2) DOM 兜底: MutationObserver + requestAnimationFrame, 在 OAF 自己写回旧值的同一帧内纠正。
 */
(function () {
	'use strict';
	if (window.__crBridgeLoaded) return;
	window.__crBridgeLoaded = true;

	var DATA = null, byMac = {}, byIp = {};
	var VER = '6';

	/* ---------------- 品牌识别 (复用主页 oui 资源) ---------------- */
	var VENDORS = null;
	var ICON_BASE = '/luci-static/resources/oui/';

	function loadVendors() {
		if (VENDORS) return;
		var files = ['vendors-d337209f8c00.json'];
		var tryNext = function (i) {
			if (i >= files.length) return;
			fetch('/luci-static/resources/oui/' + files[i], { credentials: 'same-origin', cache: 'force-cache' })
				.then(function (r) { return r.ok ? r.json() : null; })
				.then(function (d) {
					if (d && Array.isArray(d.vendors) && d.prefixes) { VENDORS = d; hookIcon(); }
					else tryNext(i + 1);
				})
				.catch(function () { tryNext(i + 1); });
		};
		tryNext(0);
	}

	function brandFor(mac) {
		if (!VENDORS || !mac) return null;
		var n = normMac(mac).toUpperCase();
		if (n.length !== 12) return null;
		var lens = [9, 7, 6];
		for (var i = 0; i < lens.length; i++) {
			var p = n.slice(0, lens[i]);
			if (Object.prototype.hasOwnProperty.call(VENDORS.prefixes, p)) {
				var idx = VENDORS.prefixes[p];
				if (idx == null) return null;
				return VENDORS.vendors[idx] || null;
			}
		}
		return null;
	}

	function isPrivateMac(mac) {
		var n = normMac(mac);
		if (n.length !== 12) return false;
		return (parseInt(n.slice(0, 2), 16) & 2) !== 0;
	}


	/* ---------------- 工具 ---------------- */
	function normMac(m) { return m ? String(m).replace(/[-:\s]/g, '').toLowerCase() : ''; }

	function fmtRate(b) {
		b = Number(b) || 0;
		if (b >= 1048576) return (b / 1048576).toFixed(2) + ' MB/s';
		if (b >= 1024) return (b / 1024).toFixed(1) + ' KB/s';
		return Math.floor(b) + ' B/s';
	}

	function fmtBytes(b) {
		b = Number(b) || 0;
		if (b >= 1073741824) return (b / 1073741824).toFixed(2) + ' GB';
		if (b >= 1048576) return (b / 1048576).toFixed(1) + ' MB';
		if (b >= 1024) return (b / 1024).toFixed(1) + ' KB';
		return Math.floor(b) + ' B';
	}

	function setText(el, txt) {
		if (el && el.textContent !== txt) el.textContent = txt;
	}

	function setHtml(el, html) {
		if (el && el.__crHtml !== html) { el.__crHtml = html; el.innerHTML = html; }
	}

	/* ---------------- 数据 ---------------- */
	function sid() {
		try { return (window.L && L.env && L.env.sessionid) || null; } catch (e) { return null; }
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
			if (!d || !d.wan) return;
			DATA = d;
			byMac = {}; byIp = {};
			(d.clients || []).forEach(function (c) {
				if (c.mac) byMac[normMac(c.mac)] = c;
				if (c.ip) byIp[c.ip] = c;
			});
			if (cb) cb(d);
			schedule();
		}).catch(function () { });
	}

	function findUser(u) {
		if (!u) return null;
		var m = normMac(u.mac);
		if (m && byMac[m]) return byMac[m];
		if (u.ip && byIp[u.ip]) return byIp[u.ip];
		return null;
	}

	function hourSeries(bucket) {
		var out = [];
		for (var i = 0; i < 24; i++) {
			var e = bucket ? (bucket[i] || bucket[String(i)]) : null;
			out.push({ hour: i, traffic: { up_bytes: e ? e[0] : 0, down_bytes: e ? e[1] : 0 } });
		}
		return out;
	}

	function pageMac() {
		var m = /[?&]mac=([^&]+)/.exec(location.search);
		if (m) return decodeURIComponent(m[1]);
		var p = location.pathname.split('/');
		var i = p.indexOf('detail');
		if (i >= 0 && p[i + 1]) return decodeURIComponent(p[i + 1]);
		return null;
	}

	/* ---------------- 仪表盘: 顶栏卡片 ---------------- */
	function cardKey(el) {
		if (!el || el.nodeType !== 1) return null;
		if (el.id === 'cr-wan-rate') return 'rate';
		if (el.querySelector('#mini-online')) return 'user';
		if (el.querySelector('#app-count')) return 'app';
		if (el.querySelector('#mini-traffic')) return 'traffic';
		if (el.querySelector('#mini-rule-count')) return 'rule';
		return null;
	}

	function buildRateCard() {
		var box = document.createElement('div');
		box.className = 'mini';
		box.id = 'cr-wan-rate';
		box.innerHTML = '<div class="stat-head"><span class="stat-label">实时速率</span>' +
			'<span class="stat-icon icon-flow" aria-hidden="true"></span></div>' +
			'<div class="top-stat-value" id="cr-wan-rate-v" style="font-size:15px;line-height:1.5">-</div>';
		return box;
	}

	var WANT_ORDER = ['user', 'app', 'rate', 'traffic'];

	function patchTopStats() {
		var stats = document.querySelector('.top-stats');
		if (!stats) return;

		/* 1) 去掉「过滤规则」卡片 */
		var kids = Array.prototype.slice.call(stats.children);
		kids.forEach(function (k) {
			if (cardKey(k) === 'rule' && k.parentNode) k.parentNode.removeChild(k);
		});

		/* 2) 补上实时速率卡片 */
		var rate = document.getElementById('cr-wan-rate');
		if (!rate) {
			rate = buildRateCard();
			stats.appendChild(rate);
		}

		/* 3) 按 在线用户 → 在线应用 → 实时速率 → 今日流量 排序 */
		var cur = Array.prototype.slice.call(stats.children).map(cardKey);
		var want = WANT_ORDER.slice(0, cur.length);
		var same = cur.length === want.length && cur.every(function (v, i) { return v === want[i]; });
		if (!same) {
			var map = {};
			Array.prototype.slice.call(stats.children).forEach(function (k) {
				var key = cardKey(k);
				if (key) map[key] = k;
			});
			WANT_ORDER.forEach(function (key) {
				if (map[key]) stats.appendChild(map[key]);
			});
		}

		/* 4) 实时速率数值 */
		var wan = (DATA && DATA.wan) || {};
		var v = document.getElementById('cr-wan-rate-v');
		if (v) {
			setHtml(v, '<span style="color:#2f7ed8">↓ ' + fmtRate(wan.down) + '</span>' +
				'<br><span style="color:#e08b2c">↑ ' + fmtRate(wan.up) + '</span>');
		}

		/* 5) 今日流量 */
		var mt = document.getElementById('mini-traffic');
		if (mt) {
			mt.title = '今日总流量（硬件加速校正后）';
			setText(mt, fmtBytes((wan.up_today || 0) + (wan.down_today || 0)));
		}
	}

	/* ---------------- 数据层 hook ---------------- */
	function hook(name, before) {
		var orig = window[name];
		if (typeof orig !== 'function' || orig.__crHook) return false;
		var wrapped = function () {
			try { before.apply(null, arguments); } catch (e) { }
			return orig.apply(this, arguments);
		};
		wrapped.__crHook = true;
		window[name] = wrapped;
		return true;
	}

	function fixUserStats(u) {
		var c = findUser(u);
		if (!c) return;
		/* 速率(bytes/s) */
		u.up_rate = c.up;
		u.down_rate = c.down;
		/* 今日流量(bytes) —— 少数接口用带 _bytes 后缀的字段 */
		u.today_up_bytes = c.up_today;
		u.today_down_bytes = c.down_today;
	}

	function hookOaf() {
		/* 终端列表 */
		hook('render_user_list', function (data) {
			if (data && data.list) data.list.forEach(fixUserStats);
		});

		/* 用户详情: 基础信息里的今日上行/下行 */
		hook('render_user_basic_info', function (user) {
			fixUserStats(user);
		});

		/* 用户详情: 24 小时流量图 */
		hook('renderHourlyTrafficChart', function (stats) {
			if (!Array.isArray(stats)) return;
			var mac = pageMac();
			var c = mac ? byMac[normMac(mac)] : null;
			var series = hourSeries(c ? c.hours : null);
			stats.length = 0;
			series.forEach(function (s) { stats.push(s); });
		});

		/* 仪表盘: 用户流量排行(今日上/下行按设备) */
		hook('updateUserTrafficChart', function (data) {
			if (!data || !Array.isArray(data.users)) return;
			data.users.forEach(function (u) {
				var c = findUser(u);
				if (!c) return;
				u.up_bytes = c.up_today;
				u.down_bytes = c.down_today;
				u.total_bytes = c.up_today + c.down_today;
			});
		});

		/* 仪表盘: 流量统计图(今日 24 小时) */
		hook('updateHistoryTrafficChart', function (data, type) {
			if (!data || (type && type !== 'today')) return;
			var wan = (DATA && DATA.wan) || {};
			data.hourly_traffic = hourSeries(wan.hours);
		});

		/* 设备头像: 品牌图标(与主页「在线主机」一致) */
		hookIcon();
	}

	/* ---------------- 详情页数字兜底 ---------------- */
	function patchDetailNums() {
		var up = document.getElementById('basic_info_up_bytes');
		var dn = document.getElementById('basic_info_down_bytes');
		if (!up && !dn) return;
		var mac = pageMac();
		var c = mac ? byMac[normMac(mac)] : null;
		if (!c) return;
		if (up) setText(up, fmtBytes(c.up_today));
		if (dn) setText(dn, fmtBytes(c.down_today));
	}

	/* ---------------- 列表单元格兜底(极少数 OAF 直接写 DOM 的路径) ---------------- */
	function patchListCells() {
		var table = document.getElementById('user_status_table');
		if (!table) return;
		var rows = table.querySelectorAll('tr');
		for (var i = 0; i < rows.length; i++) {
			var row = rows[i];
			if (row.querySelector('th')) continue;
			var c = null;
			var dm = /([0-9a-f]{2}(?:[:-][0-9a-f]{2}){5})/i.exec(row.innerHTML || '');
			if (dm) c = byMac[normMac(dm[1])];
			if (!c) {
				var im = /(?:^|[^0-9])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?:[^0-9]|$)/.exec(row.textContent || '');
				if (im) c = byIp[im[1]];
			}
			if (!c) continue;

			var up = row.querySelector('.user-col-up-rate span');
			var dn = row.querySelector('.user-col-down-rate span');
			if (up) setText(up, fmtRate(c.up));
			if (dn) setText(dn, fmtRate(c.down));

			var tf = row.querySelector('.user-col-traffic span');
			if (tf) {
				var total = (c.up_today || 0) + (c.down_today || 0);
				setText(tf, fmtBytes(total));
				var tip = "showTrafficTooltip(event, '" + fmtBytes(c.up_today) + "', '" + fmtBytes(c.down_today) + "')";
				if (tf.getAttribute('onmouseenter') !== tip) {
					tf.setAttribute('onmouseenter', tip);
					tf.setAttribute('onmouseleave', 'hideTrafficTooltip(event)');
				}
			}
		}
	}

	/* ---------------- 列表设备头像: 品牌图标 ---------------- */
	function brandIconHtml(mac, cls) {
		var v = brandFor(mac);
		var src, title;
		if (v) { src = ICON_BASE + v[0] + '.svg'; title = v[1]; }
		else if (isPrivateMac(mac)) { src = ICON_BASE + 'phone.svg'; title = '随机 MAC / 私有地址'; }
		else return null;
		return '<span class="user-device-icon' + (cls ? ' ' + cls : '') + '" style="padding:0">' +
			'<img src="' + src + '" alt="" title="' + title + '" ' +
			'style="width:26px;height:26px;object-fit:contain;display:block;background:#fff;' +
			'border-radius:6px;padding:2px;box-sizing:border-box"></span>';
	}

	function hookIcon() {
		if (typeof window.buildDeviceIconHtml !== 'function' || window.buildDeviceIconHtml.__crHook) return;
		if (!VENDORS) return;
		var orig = window.buildDeviceIconHtml;
		window.buildDeviceIconHtml = function (name, mac) {
			var html = brandIconHtml(mac, 'cr-brand');
			if (html) return html;
			return orig.apply(this, arguments);
		};
		window.buildDeviceIconHtml.__crHook = true;
	}

	function patchListIcons() {
		var icons = document.querySelectorAll('.user-device-icon');
		for (var i = 0; i < icons.length; i++) {
			var el = icons[i];
			var row = el.closest('tr, .user-card, .card-item') || el.parentNode;
			if (!row) continue;
			var m = /([0-9a-f]{2}(?:[:-][0-9a-f]{2}){5})/i.exec(row.textContent || '');
			var mac = m ? m[1] : null;
			if (!mac) continue;

			var v = brandFor(mac);
			var src, title, bg;
			if (v) {
				src = ICON_BASE + v[0] + '.svg';
				title = v[1];
				bg = '#fff';
			} else if (isPrivateMac(mac)) {
				src = ICON_BASE + 'phone.svg';
				title = '随机 MAC / 私有地址';
				bg = '#fff';
			} else {
				continue;   /* 未知品牌: 保留 OAF 的字母头像 */
			}

			if (el.__crSrc === src) continue;
			var shown = el.querySelector('img');
			if (shown && shown.getAttribute('src') === src) { el.__crSrc = src; continue; }
			el.__crSrc = src;
			el.style.removeProperty('background');
			el.style.padding = '0';
			el.innerHTML = '';
			var img = document.createElement('img');
			img.src = src;
			img.alt = '';
			img.title = title;
			img.style.cssText = 'width:26px;height:26px;object-fit:contain;display:block;background:' + bg +
				';border-radius:6px;padding:2px;box-sizing:border-box';
			img.onerror = function () { this.style.visibility = 'hidden'; };
			el.appendChild(img);
		}
	}

	/* ---------------- 统一入口 ---------------- */
	function applyDom() {
		if (!DATA) return;
		patchTopStats();
		patchDetailNums();
		patchListCells();
		patchListIcons();
	}

	var pending = false;
	function schedule() {
		if (pending) return;
		pending = true;
		var run = function () { pending = false; applyDom(); };
		if (window.requestAnimationFrame) requestAnimationFrame(run);
		else setTimeout(run, 16);
	}

	/* ---------------- 启动 ---------------- */
	var timer = null;

	function tick() {
		if (document.hidden) return;
		hookOaf();                 /* 函数可能被 OAF 重新定义, 每轮确认一次 */
		call(null);
	}

	function start() {
		if (timer) return;
		loadVendors();
		hookOaf();
		timer = setInterval(tick, 1000);
		call(function (d) {
			/* 首次数据到手后立即重绘一次「流量统计」图, 避免等 OAF 下一个 3 秒周期。
			   用户流量排行不动它: 条目集合由 OAF 决定, 我们只替换数值, 否则会出现条数跳动。 */
			try {
				if (document.getElementById('history-traffic-chart') && typeof window.updateHistoryTrafficChart === 'function')
					window.updateHistoryTrafficChart({ hourly_traffic: hourSeries(d.wan.hours) }, 'today');
			} catch (e) { }
		});

		/* DOM 兜底: OAF 每 3 秒会重写自己那份数据, 变化后在渲染前一帧内纠正 */
		if (window.MutationObserver) {
			var obs = new MutationObserver(function () { schedule(); });
			obs.observe(document.body, { childList: true, subtree: true, characterData: true });
		}
	}

	if (document.readyState === 'loading')
		document.addEventListener('DOMContentLoaded', start);
	else
		start();
})();
