'use strict';
'require baseclass';

var VENDOR_URL = L.resource('oui/vendors-d337209f8c00.json');
var ICON_BASE = L.resource('oui') + '/';

var _db = null, _pending = null, _byMac = {};

function normalize(mac, allowLocal) {
	if (typeof mac !== 'string')
		return null;
	if (!/^(?:[\da-f]{12}|(?:[\da-f]{2}:){5}[\da-f]{2}|(?:[\da-f]{2}-){5}[\da-f]{2})$/i.test(mac))
		return null;
	mac = mac.replace(/[:-]/g, '').toUpperCase();
	var flags = parseInt(mac.slice(0, 2), 16);
	if (flags & 1)
		return null;
	if (!allowLocal && (flags & 2))
		return null;
	return mac;
}

function load() {
	if (!_pending) {
		_pending = fetch(VENDOR_URL, { credentials: 'same-origin', cache: 'force-cache' })
			.then(function (r) { return r.ok ? r.json() : null; })
			.then(function (d) {
				if (d && Array.isArray(d.vendors) && d.prefixes) {
					_db = d;
					return d;
				}
				return null;
			})
			.catch(function () { return null; });
	}
	return _pending;
}

function vendorOf(mac) {
	if (!_db || !mac)
		return null;
	if (_byMac[mac])
		return _byMac[mac];
	var lens = [9, 7, 6];
	for (var i = 0; i < lens.length; i++) {
		var p = mac.slice(0, lens[i]);
		if (Object.prototype.hasOwnProperty.call(_db.prefixes, p)) {
			var idx = _db.prefixes[p];
			if (idx == null)
				break;
			var v = _db.vendors[idx];
			if (v) {
				_byMac[mac] = v;
				return v;
			}
		}
	}
	return null;
}

function icon(mac, size) {
	size = size || 20;
	var n = normalize(mac, true);
	var img = E('img', {
		'width': size,
		'height': size,
		'alt': '',
		'style': 'width:' + size + 'px;height:' + size + 'px;object-fit:contain;vertical-align:middle;' +
		         'margin-right:6px;background:#fff;border-radius:4px;padding:2px;box-sizing:content-box'
	});
	var fallback = ICON_BASE + (n && (parseInt(n.slice(0, 2), 16) & 2) ? 'phone.svg' : 'computer.svg');
	img.setAttribute('src', fallback);
	img.addEventListener('error', function () { this.src = ICON_BASE + 'computer.svg'; });

	if (n && (parseInt(n.slice(0, 2), 16) & 2)) {
		img.title = _('随机 MAC / 私有地址');
		return img;
	}
	var v = vendorOf(n);
	if (v) {
		img.title = v[1];
		img.setAttribute('src', ICON_BASE + v[0] + '.svg');
	}
	else {
		img.title = _('未知品牌');
	}
	return img;
}

function nameOf(mac) {
	var n = normalize(mac, true);
	var v = vendorOf(n);
	return v ? v[1] : null;
}

return baseclass.extend({
	load: load,
	vendorOf: vendorOf,
	icon: icon,
	name: nameOf,
	normalize: normalize
});
