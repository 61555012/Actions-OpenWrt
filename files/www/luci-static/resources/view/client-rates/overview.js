'use strict';
'require view';
'require rpc';
'require client-rates.brand as brand';

var callStatus = rpc.declare({
	object: 'luci.client_rates',
	method: 'status'
});

function fmtRate(v) { return String.format('%1024.2mB/s', v || 0); }
function fmtB(v) { return String.format('%1024.2mB', v || 0); }

function stat(label, color) {
	var val = E('div', { 'style': 'font-size:170%;font-weight:600;line-height:1.25' + (color ? ';color:' + color : '') }, ['-']);
	var box = E('div', {
		'style': 'flex:1 1 150px;min-width:140px;padding:12px 14px;border:1px solid rgba(128,128,128,.22);border-radius:10px;background:rgba(128,128,128,.04)'
	}, [
		E('div', { 'style': 'font-size:85%;opacity:.65;margin-bottom:4px' }, [label]),
		val
	]);
	return { box: box, val: val };
}

return view.extend({
	load: function () {
		return Promise.all([L.resolveDefault(callStatus(), {}), brand.load()]);
	},

	render: function (res) {
		var data = res[0] || {};
		var rows = {};
		var order = [];

		var sDown = stat(_('实时下行'), '#2f7ed8');
		var sUp = stat(_('实时上行'), '#e08b2c');
		var sToday = stat(_('今日总流量'));
		var sOnline = stat(_('在线设备'));

		var tbody = E('tbody', {});
		var hint = E('div', { 'style': 'font-size:85%;opacity:.6;margin:6px 0 10px' },
			[data.hnat ? _('数据源：conntrack + HNAT 硬件流表双源采样，硬件加速下同样计入')
			           : _('未检测到 HNAT 硬件流表，当前仅统计软件路径')]);

		function cell(text, style) {
			return E('td', { 'class': 'td left', 'style': style || '' }, [text]);
		}

		function rowFor(c) {
			var key = c.mac || ('ip:' + c.ip);
			var r = rows[key];
			if (r) return r;
			var nameEl = E('span', { 'style': 'font-weight:600' }, ['-']);
			var subEl = E('span', { 'style': 'font-size:85%;opacity:.6;margin-left:6px' }, ['']);
			var ipEl = E('span', {}, ['-']);
			var macEl = E('span', { 'style': 'font-size:85%;opacity:.7' }, ['-']);
			var downEl = E('span', { 'style': 'color:#2f7ed8;font-weight:600' }, ['-']);
			var upEl = E('span', { 'style': 'color:#e08b2c;font-weight:600' }, ['-']);
			var tDown = E('span', {}, ['-']);
			var tUp = E('span', {}, ['-']);
			var statEl = E('span', { 'class': 'ifacebadge' }, ['-']);
			var iconWrap = E('span', { 'style': 'vertical-align:middle' });

			var tr = E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'style': 'white-space:nowrap' }, [iconWrap, nameEl, subEl]),
				cell(ipEl),
				cell(macEl),
				E('td', { 'class': 'td right' }, [downEl]),
				E('td', { 'class': 'td right' }, [upEl]),
				E('td', { 'class': 'td right' }, [tDown]),
				E('td', { 'class': 'td right' }, [tUp]),
				E('td', { 'class': 'td left' }, [statEl])
			]);
			r = { tr: tr, iconWrap: iconWrap, nameEl: nameEl, subEl: subEl, ipEl: ipEl, macEl: macEl,
			      downEl: downEl, upEl: upEl, tDown: tDown, tUp: tUp, statEl: statEl, iconKey: null };
			rows[key] = r;
			tbody.appendChild(tr);
			return r;
		}

		function update(d) {
			var wan = (d && d.wan) || {};
			sDown.val.textContent = fmtRate(wan.down);
			sUp.val.textContent = fmtRate(wan.up);
			sToday.val.textContent = '↓ ' + fmtB(wan.down_today) + '  ↑ ' + fmtB(wan.up_today);
			sOnline.val.textContent = String((d && d.online) || 0);

			var list = ((d && d.clients) || []).slice();
			list.sort(function (a, b) { return (b.up + b.down) - (a.up + a.down); });

			var keys = [];
			list.forEach(function (c) {
				var key = c.mac || ('ip:' + c.ip);
				keys.push(key);
				var r = rowFor(c);
				var title = c.host || brand.name(c.mac) || c.ip || c.mac || '?';
				var vname = brand.name(c.mac);
				r.nameEl.textContent = title;
				r.subEl.textContent = (c.host && vname) ? vname : '';
				r.ipEl.textContent = c.ip || '-';
				r.macEl.textContent = c.mac || '-';
				r.downEl.textContent = fmtRate(c.down);
				r.upEl.textContent = fmtRate(c.up);
				r.tDown.textContent = fmtB(c.down_today);
				r.tUp.textContent = fmtB(c.up_today);
				r.statEl.textContent = c.online ? _('在线') : _('离线');
				r.statEl.className = 'label ' + (c.online ? 'success' : 'notice');
				var ik = (c.mac || '') + '|' + (c.online ? '1' : '0');
				if (r.iconKey !== ik) {
					r.iconKey = ik;
					while (r.iconWrap.firstChild) r.iconWrap.removeChild(r.iconWrap.firstChild);
					r.iconWrap.appendChild(brand.icon(c.mac, 22));
				}
			});

			/* 移除已消失的设备 */
			Object.keys(rows).forEach(function (k) {
				if (keys.indexOf(k) < 0) {
					var r = rows[k];
					if (r.tr.parentNode) r.tr.parentNode.removeChild(r.tr);
					delete rows[k];
				}
			});

			/* 仅当顺序变化时重排，避免每秒抖动 */
			if (order.join(',') !== keys.join(',')) {
				order = keys;
				keys.forEach(function (k) { tbody.appendChild(rows[k].tr); });
			}

			if (!keys.length) {
				if (!tbody.querySelector('.empty-hint'))
					tbody.appendChild(E('tr', { 'class': 'tr empty-hint' }, [
						E('td', { 'class': 'td left', 'colspan': 8, 'style': 'opacity:.6' }, [_('暂无活动设备')])
					]));
			}
			else {
				var eh = tbody.querySelector('.empty-hint');
				if (eh) eh.parentNode.removeChild(eh);
			}
		}

		var table = E('table', { 'class': 'table' }, [
			E('thead', {}, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, [_('设备')]),
					E('th', { 'class': 'th' }, [_('IP 地址')]),
					E('th', { 'class': 'th' }, [_('MAC')]),
					E('th', { 'class': 'th', 'style': 'text-align:right' }, [_('下行')]),
					E('th', { 'class': 'th', 'style': 'text-align:right' }, [_('上行')]),
					E('th', { 'class': 'th', 'style': 'text-align:right' }, [_('今日下行')]),
					E('th', { 'class': 'th', 'style': 'text-align:right' }, [_('今日上行')]),
					E('th', { 'class': 'th' }, [_('状态')])
				])
			]),
			tbody
		]);

		var container = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [_('设备流量')]),
			hint,
			E('div', { 'style': 'display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px' },
				[sDown.box, sUp.box, sToday.box, sOnline.box]),
			table
		]);

		update(data);

		var timer = setInterval(function () {
			if (document.hidden) return;
			callStatus().then(update).catch(function () {});
		}, 1000);

		this._timer = timer;
		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
