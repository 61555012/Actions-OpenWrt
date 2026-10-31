'use strict';
'require baseclass';
'require rpc';
'require client-rates.brand as brand';

var callStatus = rpc.declare({
	object: 'luci.client_rates',
	method: 'status'
});

var STYLE_ID = 'cr-hosts-style';
var CSS = ''
	+ '.cr-hosts-head{display:flex;flex-wrap:wrap;gap:26px;align-items:baseline;padding:10px 14px;'
	+ 'border-radius:8px;background:rgba(127,127,127,.09);font-size:13px;margin:0 0 10px}'
	+ '.cr-hosts-head .k{opacity:.6;margin-right:6px}'
	+ '.cr-hosts-head .v{font-weight:600;font-variant-numeric:tabular-nums}'
	+ '.cr-hosts-table{display:table;width:100%;font-size:13px;border-collapse:collapse;table-layout:fixed}'
	+ '.cr-hosts-table th{font-weight:600;white-space:nowrap;padding:8px 8px !important;text-align:left;'
	+ 'border-bottom:1px solid rgba(127,127,127,.25);overflow:hidden;text-overflow:ellipsis}'
	+ '.cr-hosts-table td{padding:7px 8px !important;vertical-align:middle;overflow:hidden;white-space:nowrap;'
	+ 'border-bottom:1px solid rgba(127,127,127,.12)}'
	+ '.cr-hosts-table td.num{text-align:right !important;font-variant-numeric:tabular-nums}'
	+ '.cr-hosts-table th.num{text-align:right !important}'
	+ '.cr-hosts-table th.ctr,.cr-hosts-table td.ctr{text-align:center !important}'
	+ '.cr-hosts-table tr{display:table-row}'
	+ '.cr-hosts-table th,.cr-hosts-table td{display:table-cell}'
	+ '.cr-hosts-table tr.off td{opacity:.55}'
	+ '.cr-dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#2ecc71;'
	+ 'box-shadow:0 0 0 2px rgba(46,204,113,.2)}'
	+ '.cr-dot.off{background:#9aa0a6;box-shadow:none}'
	+ '.cr-hostname{display:flex;align-items:center;justify-content:flex-start;min-width:0}'
	+ '.cr-hostname .ic{flex:0 0 auto;margin-right:0;display:flex;align-items:center}'
	+ '.cr-hostname .n{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:0 1 auto;min-width:0;max-width:100%}'
	+ '.cr-hostname .vd{opacity:.55;font-size:88%;margin-left:5px;white-space:nowrap;flex:0 0 auto;'
	+ 'overflow:hidden;text-overflow:ellipsis;max-width:40%}'
	+ '.cr-v6{font-size:11px;opacity:.8;font-family:ui-monospace,Menlo,Consolas,monospace}'
	+ '.cr-mac{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;opacity:.85}'
	+ '.cr-rssi{font-variant-numeric:tabular-nums;font-size:12.5px}'
	+ '.cr-hosts-table td.num{font-size:12.5px}'
	+ '.cr-empty{padding:14px 4px;opacity:.6}';

function fmtRate(v) {
	return String.format('%1024.2mB/s', v || 0);
}

function fmtB(v) {
	return String.format('%1024.2mB', v || 0);
}

function rssiColor(v) {
	if (v >= -60) return '#2ecc71';
	if (v >= -75) return '#e0a72c';
	return '#e05c5c';
}

function ensureStyle() {
	if (document.getElementById(STYLE_ID))
		return;
	var s = document.createElement('style');
	s.id = STYLE_ID;
	s.appendChild(document.createTextNode(CSS));
	document.head.appendChild(s);
}

function keyOf(c) {
	return c.mac || ('ip:' + c.ip);
}

function renderCell(c) {
	var title = c.host || brand.name(c.mac) || '-';
	var vd = (c.host && brand.name(c.mac)) ? brand.name(c.mac) : '';
	var nameEl = E('span', { 'class': 'n', 'title': title }, [title]);
	return {
		dot: E('span', { 'class': 'cr-dot' + (c.online ? '' : ' off') }),
		host: E('div', { 'class': 'cr-hostname' }, [
			E('span', { 'class': 'ic' }, [brand.icon(c.mac, 18)]),
			nameEl,
			vd ? E('span', { 'class': 'vd' }, [vd]) : ''
		]),
		nameEl: nameEl,
		ip: E('span', {}, [c.ip || '-']),
		ip6: E('span', { 'class': 'cr-v6', 'title': c.ip6 || '' }, [c.ip6 || '-']),
		mac: E('span', { 'class': 'cr-mac' }, [c.mac ? c.mac.toUpperCase() : '-']),
		up: E('span', {}, ['-']),
		down: E('span', {}, ['-']),
		rssi: E('span', { 'class': 'cr-rssi' }, ['-']),
		total: E('span', {}, ['-']),
		conn: E('span', {}, ['-'])
	};
}

function newRow(c) {
	var cl = renderCell(c);
	var tr = E('tr', { 'class': 'cr-row', 'data-key': keyOf(c) }, [
		E('td', { 'class': 'ctr' }, [cl.dot]),
		E('td', {}, [cl.host]),
		E('td', {}, [cl.mac]),
		E('td', {}, [cl.ip]),
		E('td', {}, [cl.ip6]),
		E('td', { 'class': 'num' }, [cl.up]),
		E('td', { 'class': 'num' }, [cl.down]),
		E('td', { 'class': 'num' }, [cl.total]),
		E('td', { 'class': 'num' }, [cl.conn]),
		E('td', { 'class': 'num' }, [cl.rssi])
	]);
	tr._cr = cl;
	return tr;
}

function fill(tr, c) {
	var cl = tr._cr;
	cl.dot.className = 'cr-dot' + (c.online ? '' : ' off');
	var title = c.host || brand.name(c.mac) || '-';
	if (cl.nameEl.textContent !== title) {
		cl.nameEl.textContent = title;
		cl.nameEl.title = title;
	}
	cl.ip.textContent = c.ip || '-';
	cl.ip6.textContent = c.ip6 || '-';
	cl.ip6.title = c.ip6 || '';
	cl.mac.textContent = c.mac ? c.mac.toUpperCase() : '-';
	cl.up.textContent = fmtRate(c.up);
	cl.down.textContent = fmtRate(c.down);
	if (c.rssi != null) {
		cl.rssi.textContent = c.rssi + ' dBm';
		cl.rssi.style.color = rssiColor(c.rssi);
	}
	else {
		cl.rssi.textContent = '-';
		cl.rssi.style.color = '';
	}
	cl.total.textContent = fmtB((c.up_today || 0) + (c.down_today || 0));
	cl.conn.textContent = (c.conn != null) ? String(c.conn) : '-';
	tr.className = 'cr-row' + (c.online ? '' : ' off');
}

var timer = null;

function stopTimer() {
	if (timer) {
		clearInterval(timer);
		timer = null;
	}
}

return baseclass.extend({
	title: _('在线主机'),

	load: function () {
		return Promise.all([
			L.resolveDefault(callStatus(), {}),
			brand.load()
		]);
	},

	render: function (res) {
		try {
			return this._render(res);
		}
		catch (e) {
			stopTimer();
			return E('div', { 'class': 'cr-empty' },
				['在线主机组件加载失败: ' + (e && e.message ? e.message : e)]);
		}
	},

	_render: function (res) {
		var data = (res && res[0]) || {};

		if (this.root) {
			try { this.update(data); } catch (e) { }
			return this.root;
		}

		ensureStyle();

		var onlineV = E('span', { 'class': 'v' }, ['0']);
		var upV = E('span', { 'class': 'v', 'style': 'color:#e08b2c' }, ['0 B/s']);
		var downV = E('span', { 'class': 'v', 'style': 'color:#2f7ed8' }, ['0 B/s']);
		var noteV = E('span', { 'class': 'v', 'style': 'font-weight:400;opacity:.6' }, ['']);

		var tbody = E('tbody', {});
		var empty = E('div', { 'class': 'cr-empty' }, [_('暂无在线设备')]);

		var node = E('div', {}, [
			E('div', { 'class': 'cr-hosts-head' }, [
				E('span', {}, [E('span', { 'class': 'k' }, [_('在线用户')]), onlineV]),
				E('span', {}, [E('span', { 'class': 'k' }, [_('上传总带宽')]), upV]),
				E('span', {}, [E('span', { 'class': 'k' }, [_('下载总带宽')]), downV]),
				E('span', {}, [noteV])
			]),
			E('table', { 'class': 'table cr-hosts-table' }, [
				E('colgroup', {}, [
					E('col', { 'style': 'width:6%' }),
					E('col', { 'style': 'width:13%' }),
					E('col', { 'style': 'width:13%' }),
					E('col', { 'style': 'width:10.5%' }),
					E('col', { 'style': 'width:17.5%' }),
					E('col', { 'style': 'width:7.5%' }),
					E('col', { 'style': 'width:7.5%' }),
					E('col', { 'style': 'width:9%' }),
					E('col', { 'style': 'width:6%' }),
					E('col', { 'style': 'width:10%' })
				]),
				E('thead', {}, [E('tr', { 'class': 'cr-row' }, [
					E('th', { 'class': 'ctr' }, [_('状态')]),
					E('th', {}, [_('主机名')]),
					E('th', {}, [_('MAC 地址')]),
					E('th', {}, [_('IPv4 地址')]),
					E('th', {}, [_('IPv6 地址')]),
					E('th', { 'class': 'num' }, [_('上传')]),
					E('th', { 'class': 'num' }, [_('下载')]),
					E('th', { 'class': 'num' }, [_('总流量')]),
					E('th', { 'class': 'num' }, [_('连接数')]),
					E('th', { 'class': 'num' }, [_('信号强度')])
				])]),
				tbody
			]),
			empty
		]);

		this.root = node;
		this.body = tbody;
		this.emptyEl = empty;
		this.rows = {};
		this.onlineEl = onlineV;
		this.upEl = upV;
		this.downEl = downV;
		this.noteEl = noteV;

		this.update = function (d) {
			var wan = d.wan || {};
			onlineV.textContent = String(d.online || 0);
			if (!d.online && d.total) onlineV.textContent = '0';
			upV.textContent = fmtRate(wan.up);
			downV.textContent = fmtRate(wan.down);
			noteV.textContent = d.hnat ? _('硬件加速已校正') : _('仅软件路径');

			var list = d.clients || [];
			var seen = {}, i, c, tr;

			for (i = 0; i < list.length; i++) {
				c = list[i];
				var k = keyOf(c);
				seen[k] = 1;
				tr = this.rows[k];
				if (!tr) {
					tr = newRow(c);
					this.rows[k] = tr;
				}
				fill(tr, c);
				if (this.body.children[i] !== tr)
					this.body.insertBefore(tr, this.body.children[i] || null);
			}

			for (k in this.rows) {
				if (!seen[k]) {
					if (this.rows[k].parentNode)
						this.rows[k].parentNode.removeChild(this.rows[k]);
					delete this.rows[k];
				}
			}

			this.emptyEl.style.display = list.length ? 'none' : '';
		};

		try { this.update(data); } catch (e) { }

		var self = this;
		timer = setInterval(function () {
			if (document.hidden || !self.root || !self.root.parentNode)
				return;
			callStatus().then(function (d) {
				if (!d || !d.wan) return;
				self.update(d);
			}).catch(function () { });
		}, 1000);

		return node;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
