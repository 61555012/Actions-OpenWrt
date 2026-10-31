#!/usr/bin/ucode
// client-rates sampler — 硬件加速(HNAT)下的逐设备流量统计
//
// 数据源:
//   /proc/net/nf_conntrack           软件路径计数(流被硬件卸载后冻结)
//   /sys/kernel/debug/hnat/all_entry PPE 快通道计数, 每条目单向:
//        SIP=客户端 -> dir=up ;  NDIP=客户端 -> dir=down
//
// 思路: 两个源互补不相交(卸载前归 conntrack, 卸载后归 HNAT), 故逐"源条目"求增量再求和。
// 每条基线以源内唯一 id 绑定(h:<槽位>:<5元组> / c:<5元组>), 首次见到只建基线不计数,
// 避免 HNAT 槽位回收导致同一累计值被反复计入。
'use strict';

const fs = require('fs');
const uci = require('uci');

const HNAT_PATH   = '/sys/kernel/debug/hnat/all_entry';
const CT_PATH     = '/proc/net/nf_conntrack';
const ARP_PATH    = '/proc/net/arp';
const LEASE_PATH  = '/tmp/dhcp.leases';
const OUT_PATH    = '/tmp/client-rates.json';
const STATE_DIR   = '/etc/client-rates';
const STATE_PATH  = STATE_DIR + '/state.json';
const INTERVAL    = 1;
const SAVE_EVERY  = 30;
const ONLINE_WIN  = 120;
const RATE_ALPHA  = 0.55;
const NEIGH_EVERY = 5;      // 每 5 个 tick 取一次 IPv6 邻居表
const RSSI_EVERY  = 10;     // 每 10 个 tick 取一次无线信号强度
const V6_TTL      = 86400;  // v6 地址池条目保留时长(秒)
const KEEP_BASE   = 180;    // 源条目基线保留时长(秒)
const KEEP_DAYS   = 7;

function now() { return time(); }

function daykey(t) {
	let tm = localtime(t);
	return sprintf('%04d-%02d-%02d', tm.year, tm.mon, tm.mday);
}

function hour_of(t) { return localtime(t).hour; }

function lan_cfg() {
	let ip = '192.168.6.1', mask = '255.255.255.0';
	try {
		let ctx = uci.cursor();
		ip = ctx.get('network', 'lan', 'ipaddr') || ip;
		mask = ctx.get('network', 'lan', 'netmask') || mask;
	} catch (e) { }
	let sl = index(ip, '/');        // ipaddr 可能带 CIDR 后缀
	if (sl != null) ip = substr(ip, 0, sl);
	let n = 0;
	for (let i = 0; i < length(ip); i++) if (ip[i] == '.') n++;
	if (n != 3 || !match(ip, /^[0-9.]+$/)) ip = '192.168.6.1';
	return { ip: ip, mask: mask };
}

function lan_prefix_of(ip, mask) {
	let o = split(ip, '.'), m = split(mask, '.');
	if (length(o) != 4 || length(m) != 4) return '192.168.6.';
	if (m[1] != '255') return o[0] + '.';
	if (m[2] != '255') return o[0] + '.' + o[1] + '.';
	return o[0] + '.' + o[1] + '.' + o[2] + '.';
}

const LC = lan_cfg();
const LAN = lan_prefix_of(LC.ip, LC.mask);
const ROUTER_IP = LC.ip;

function iface_mac(name) {
	let m = null;
	try { m = fs.readfile('/sys/class/net/' + name + '/address'); } catch (e) { return null; }
	return (m != null) ? lc(trim(m)) : null;
}
const LAN_MAC1 = iface_mac('br-lan');
const LAN_MAC2 = iface_mac('eth0');
function is_lan(ip) { return (ip != null) && (index(ip, LAN) == 0); }

function field(parts, name) {
	let pfx = name + '=';
	for (let i = 0; i < length(parts); i++)
		if (index(parts[i], pfx) == 0) return substr(parts[i], length(pfx));
	return null;
}

function read_arp() {
	let map = {};
	let txt = null;
	try { txt = fs.readfile(ARP_PATH); } catch (e) { return map; }
	if (txt == null) return map;
	let lines = split(txt, '\n');
	for (let i = 1; i < length(lines); i++) {
		let f = split(trim(lines[i]), ' ');
		let out = [];
		for (let j = 0; j < length(f); j++) if (length(f[j])) push(out, f[j]);
		if (length(out) < 4) continue;
		if (out[2] != '0x2') continue;
		if (out[3] == '00:00:00:00:00:00') continue;
		if (length(out) >= 6 && index(out[5], 'br-lan') != 0) continue;  // 排除 WAN 侧邻居
		map[out[0]] = lc(out[3]);
	}
	return map;
}

/* ---------- 无线信号强度 ----------
 * iwinfo <dev> assoclist 输出:  AA:BB:CC:DD:EE:FF  -55 dBm / -95 dBm (SNR 40)  ...
 * 一次 shell 汇总所有 AP 接口, 同一 MAC 多接口关联取较强者。
 */
const RSSI_CMD = 'for d in /sys/class/net/ra* /sys/class/net/wlan*; do [ -e "$d" ] || continue;'
	+ ' iwinfo "${d##*/}" assoclist 2>/dev/null; done';
const RE_ASSOC = /^([0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+)[ \t]+(-?[0-9]+)[ \t]*dBm/;
let rssi = {};          // mac -> dBm

function read_rssi() {
	let map = {};
	let txt = null;
	try {
		let p = fs.popen(RSSI_CMD);
		if (p == null) return map;
		txt = p.read('all');
		p.close();
	} catch (e) { return map; }
	if (txt == null || !length(txt)) return map;
	let lines = split(txt, '\n');
	for (let i = 0; i < length(lines); i++) {
		let m = match(lines[i], RE_ASSOC);
		if (m == null) continue;
		let mac = lc(m[1]), dbm = +m[2];
		if (!match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/)) continue;
		let old = map[mac];
		if (old == null || dbm > old) map[mac] = dbm;
	}
	return map;
}

function read_leases() {
	let map = {};
	let txt = null;
	try { txt = fs.readfile(LEASE_PATH); } catch (e) { return map; }
	if (txt == null) return map;
	let lines = split(txt, '\n');
	for (let i = 0; i < length(lines); i++) {
		if (!length(lines[i])) continue;
		let f = split(trim(lines[i]), ' ');
		if (length(f) >= 4) map[lc(f[1])] = { ip: f[2], host: (f[3] != '*') ? f[3] : null };
	}
	return map;
}

/* ---------- IPv6 地址池 ----------
 * 一台设备常有 3~5 个 v6(隐私地址轮换 + ULA + 公网 + 链路本地),
 * 这里把三个来源合并成"地址池", 每个地址记最近活跃时间, 对外只暴露最新的一条。
 *   邻居表            -> 无状态(SLAAC)地址, 带 REACHABLE/STALE 状态
 *   DHCPv6 租约       -> 有状态地址, 打 stateful 标记
 *   conntrack ipv6 行 -> 真正在收发流量的地址, 用来刷新活跃时间
 */
let v6pool = {};        // 归一化地址 -> { disp, mac, t, rank, stateful }

const RE_V6CH = /[0-9a-fA-F:]/;

function v6_rank(a) {
	let g = lc(split(a, ':')[0]);
	if (length(g) == 0) return 0;
	if (index(g, 'fe8') == 0 || index(g, 'fe9') == 0 || index(g, 'fea') == 0 || index(g, 'feb') == 0) return 1;
	if (index(g, 'fd') == 0 || index(g, 'fc') == 0) return 2;
	return 3;
}

/* 任意写法(::压缩 / 前导零 / 大写)统一成 8 段小写无前导零, 便于跨源比对 */
function expand6(s) {
	if (s == null || type(s) != 'string') return null;
	let a = lc(trim(s));
	if (!length(a)) return null;
	let pct = index(a, '%');
	if (pct >= 0) a = substr(a, 0, pct);
	if (!match(a, /^[0-9a-f:]+$/)) return null;
	let g = [];
	let dbl = index(a, '::');
	if (dbl >= 0) {
		let h = substr(a, 0, dbl), tl = substr(a, dbl + 2);
		let hp = length(h) ? split(h, ':') : [];
		let tp = length(tl) ? split(tl, ':') : [];
		let fill = 8 - length(hp) - length(tp);
		if (fill < 0) return null;
		for (let i = 0; i < length(hp); i++) push(g, hp[i]);
		for (let i = 0; i < fill; i++) push(g, '0');
		for (let i = 0; i < length(tp); i++) push(g, tp[i]);
	} else {
		g = split(a, ':');
	}
	if (length(g) != 8) return null;
	let out = [];
	for (let i = 0; i < 8; i++) {
		let seg = g[i];
		if (!length(seg)) seg = '0';
		let j = 0;
		while (j < length(seg) - 1 && substr(seg, j, 1) == '0') j++;
		push(out, substr(seg, j));
	}
	return join(':', out);
}

/* 递归收集 JSON 里所有 v6 形态的字符串/键 */
function scan_v6(node, set, depth) {
	if (depth > 8) return;
	let ty = type(node);
	if (ty == 'object') {
		for (let k in node) {
			let nk = expand6(k);
			if (nk != null) set[nk] = true;
			scan_v6(node[k], set, depth + 1);
		}
	} else if (ty == 'array') {
		for (let i = 0; i < length(node); i++) scan_v6(node[i], set, depth + 1);
	} else if (ty == 'string') {
		let nv = expand6(node);
		if (nv != null) set[nv] = true;
	}
}

/* 有状态(DHCPv6)地址集合; 未开 DHCPv6 时返回空表 */
function read_dhcpv6() {
	let set = {};
	let txt = null;
	try {
		let p = fs.popen('ubus -S call dhcp ipv6leases 2>/dev/null');
		if (p != null) { txt = p.read('all'); p.close(); }
	} catch (e) { }
	if (txt != null && length(txt) > 8) {
		try { scan_v6(json(txt), set, 0); } catch (e) { }
	}
	return set;
}

/* 邻居表刷新: 无状态地址入库; 非 STALE(刚确认可达)才推进活跃时间 */
function read_neigh6(t, dhcp6) {
	let txt = null;
	try {
		let p = fs.popen('/sbin/ip -6 neigh show dev br-lan 2>/dev/null');
		if (p == null) return;
		txt = p.read('all');
		p.close();
	} catch (e) { return; }
	if (txt == null || !length(txt)) return;
	let lines = split(txt, '\n');
	for (let i = 0; i < length(lines); i++) {
		let f = split(trim(lines[i]), ' ');
		let out = [];
		for (let j = 0; j < length(f); j++) if (length(f[j])) push(out, f[j]);
		if (length(out) < 3) continue;
		let addr = out[0], mac = null, st = null;
		for (let j = 1; j < length(out); j++) {
			if (out[j] == 'lladdr' && j + 1 < length(out)) { mac = lc(out[j + 1]); j++; continue; }
			if (out[j] == 'REACHABLE' || out[j] == 'STALE' || out[j] == 'DELAY' ||
			    out[j] == 'PROBE' || out[j] == 'FAILED' || out[j] == 'NOARP')
				st = out[j];
		}
		if (st == 'FAILED' || st == 'NOARP') continue;
		if (mac == null || !match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/)) continue;
		let a = expand6(addr);
		if (a == null) continue;
		let rk = v6_rank(a);
		if (rk < 2) continue;                       // 丢弃 fe80 链路本地
		let e = v6pool[a];
		if (e == null) {
			v6pool[a] = { disp: addr, mac: mac, t: t, rank: rk, stateful: (dhcp6[a] == true) ? 1 : 0 };
		} else {
			e.mac = mac; e.disp = addr; e.rank = rk;
			if (dhcp6[a] == true) e.stateful = 1;
			if (st != 'STALE') e.t = t;
		}
	}
}

/* conntrack 里出现 = 真正在用, 刷新活跃时间 */
function touch_v6(line, t) {
	let pos = 0;
	for (let n = 0; n < 4; n++) {
		let i = index(substr(line, pos), 'src=');
		if (i < 0) break;
		let s = pos + i + 4, e = s;
		while (e < length(line) && match(substr(line, e, 1), RE_V6CH)) e++;
		let a = expand6(substr(line, s, e - s));
		if (a != null) { let en = v6pool[a]; if (en != null) en.t = t; }
		pos = e;
	}
}

/* 取该设备"最新"的一条 v6: 活跃时间 > 公网/ULA 优先 > 有状态优先 */
function pick6(mac) {
	if (mac == null) return null;
	let best = null;
	for (let a in v6pool) {
		let e = v6pool[a];
		if (e.mac != mac) continue;
		if (best == null) { best = e; continue; }
		if (e.t != best.t) { if (e.t > best.t) best = e; continue; }
		if (e.rank != best.rank) { if (e.rank > best.rank) best = e; continue; }
		if (e.stateful > best.stateful) best = e;
	}
	return (best != null) ? best.disp : null;
}

let base = {};           // 源条目基线: id -> {u,d,b,at}
let clients = {};        // mac 或 ip:addr -> record
let wan_hours = {};      // 全 WAN 每小时流量: hour -> [up, down]
let day = daykey(now());
let tick = 0;
let prev_ts = now();
let hnat_ok = true;

function flow_id(proto, cip, cport, rip, rport) {
	return proto + '|' + cip + '|' + cport + '|' + rip + '|' + rport;
}

const RE_CT = /^\s*ipv4\s+\d+\s+(\w+)\s+\d+\s+\d+\s+\w+\s+src=([0-9.]+) dst=([0-9.]+) sport=(\d+) dport=(\d+) packets=\d+ bytes=(\d+).*src=([0-9.]+) dst=([0-9.]+) sport=(\d+) dport=(\d+) packets=\d+ bytes=(\d+)/;
const PROTO_MAP = { tcp: '6', udp: '17', icmp: '1', sctp: '132' };

/* cur: flowkey -> {up,down,ip,mac}   本次 tick 的增量汇总 */
function sample_ct(cur, seen, t) {
	let txt = null;
	try { txt = fs.readfile(CT_PATH); } catch (e) { return; }
	if (txt == null) return;
	let lines = split(txt, '\n');
	for (let i = 0; i < length(lines); i++) {
		if (index(lines[i], 'ipv6') == 0) { touch_v6(lines[i], t); continue; }
		let m = match(lines[i], RE_CT);
		if (m == null) continue;
		let proto = PROTO_MAP[m[1]];
		if (proto == null) continue;
		let s1 = m[2], d1 = m[3], sp1 = m[4], dp1 = m[5], b1 = +m[6];
		let b2 = +m[11];
		let k = null, cip = null, up = b1, dn = b2;
		if (is_lan(s1)) { k = flow_id(proto, s1, sp1, d1, dp1); cip = s1; }
		else if (is_lan(d1)) { k = flow_id(proto, d1, dp1, s1, sp1); cip = d1; up = b2; dn = b1; }
		if (k == null) continue;
		seen[k] = { ip: cip, mac: null };
		let id = 'c' + k;
		let p = base[id];
		let du = 0, dd = 0;
		if (p != null) {
			du = (up > p.u) ? up - p.u : 0;
			dd = (dn > p.d) ? dn - p.d : 0;
		}
		base[id] = { u: up, d: dn, at: t };
		if (du == 0 && dd == 0) continue;
		let f = cur[k];
		if (f == null) { f = { up: 0, down: 0, ip: cip, mac: null }; cur[k] = f; }
		f.up += du; f.down += dd;
	}
}

const RE_TUPLE = /SIP=([0-9.]+)\(sp=([0-9]+)\)->DIP=([0-9.]+)\(dp=([0-9]+)\)=>NSIP=([0-9.]+)\(sp=([0-9]+)\)->NDIP=([0-9.]+)\(dp=([0-9]+)\)/;
const RE_MAC = /^([0-9a-fA-F:]+)->([0-9a-fA-F:]+)$/;

function sample_hnat(cur, seen, t) {
	let txt = null;
	try { txt = fs.readfile(HNAT_PATH); hnat_ok = true; }
	catch (e) { hnat_ok = false; return; }
	if (txt == null) { hnat_ok = false; return; }

	let lines = split(txt, '\n');
	for (let i = 0; i < length(lines); i++) {
		let line = lines[i];
		if (!length(line) || index(line, 'IPV4_') < 0) continue;
		let b = match(line, /^bytes=([0-9]+)/);
		if (b == null) continue;
		let bytes = +b[1];
		let p = split(line, '|');
		let proto = field(p, 'prot');
		let idx = field(p, 'index');
		let tpl = match(line, RE_TUPLE);
		if (tpl == null || proto == null) continue;
		let sip = tpl[1], sp = tpl[2], dip = tpl[3], dp = tpl[4], ndip = tpl[7], ndp = tpl[8];
		let smac = null, dmac = null;
		let macf = field(p, 'smac');
		if (macf != null) {
			let mm = match(macf, RE_MAC);
			if (mm != null) { smac = lc(mm[1]); dmac = lc(mm[2]); }
		}
		let k = null, dir = null, cip = null, cmac = null;
		if (is_lan(sip)) { k = flow_id(proto, sip, sp, dip, dp); dir = 'up'; cip = sip; cmac = smac; }
		else if (is_lan(ndip)) { k = flow_id(proto, ndip, ndp, sip, sp); dir = 'down'; cip = ndip; cmac = dmac; }
		if (k == null) continue;

		if (seen[k] == null) seen[k] = { ip: cip, mac: cmac };
		else if (seen[k].mac == null) seen[k].mac = cmac;

		/* 槽位号参与 id: 同一流可能同时存在多个快通道条目, 各自独立计数 */
		let id = 'h' + (idx != null ? idx : '?') + '|' + k;
		let pr = base[id];
		let d = 0;
		if (pr != null) d = (bytes > pr.b) ? bytes - pr.b : 0;
		base[id] = { b: bytes, at: t };
		if (d == 0) continue;
		let f = cur[k];
		if (f == null) { f = { up: 0, down: 0, ip: cip, mac: cmac }; cur[k] = f; }
		if (dir == 'up') f.up += d; else f.down += d;
		if (cmac != null && f.mac == null) f.mac = cmac;
	}
}

function load_state() {
	let st = null;
	try { st = json(fs.readfile(STATE_PATH)); } catch (e) { return; }
	if (st == null || type(st) != 'object') return;
	if (st.day != day || type(st.clients) != 'object') return;
	if (type(st.wan_hours) == 'object') wan_hours = st.wan_hours;
	for (let k in st.clients) {
		let c = st.clients[k];
		if (c.mac == null && c.ip == ROUTER_IP) continue;   // 路由器自身不入账
		clients[k] = {
			mac: c.mac, ip: c.ip, host: c.host, ip6: c.ip6,
			up_today: +c.up_today || 0, down_today: +c.down_today || 0,
			hours: (type(c.hours) == 'object') ? c.hours : {},
			first_seen: +c.first_seen || now(), last_seen: 0,
			up_rate: 0, down_rate: 0, conn: 0, rssi: null
		};
	}
}

function save_state() {
	let out = { day: day, saved: now(), wan_hours: wan_hours, clients: {} };
	let cut = now() - KEEP_DAYS * 86400;
	for (let k in clients) {
		let c = clients[k];
		if (c.last_seen > 0 && c.last_seen < cut) continue;
		out.clients[k] = { mac: c.mac, ip: c.ip, host: c.host, ip6: c.ip6,
			up_today: c.up_today, down_today: c.down_today,
			hours: c.hours, first_seen: c.first_seen };
	}
	try { fs.mkdir(STATE_DIR, 0755); } catch (e) { }
	try {
		fs.writefile(STATE_PATH + '.tmp', sprintf('%J', out));
		fs.rename(STATE_PATH + '.tmp', STATE_PATH);
	} catch (e) { }
}

function client_key(mac, ip) {
	return (mac != null && mac != '') ? mac : ('ip:' + ip);
}

/* 每小时流量桶: bucket["7"] = [up, down] */
function add_hour(bucket, h, up, down) {
	let k = sprintf('%d', h);
	let e = bucket[k];
	if (e == null) { e = [0, 0]; bucket[k] = e; }
	e[0] += up;
	e[1] += down;
}

function client_for(mac, ip, leases) {
	let key = client_key(mac, ip);
	let c = clients[key];

	if (c == null && mac != null) {
		let old = clients['ip:' + ip];
		if (old != null) {
			clients[key] = old;
			old.mac = mac;
			delete clients['ip:' + ip];
			c = old;
		}
	}

	if (c == null) {
		c = { mac: mac, ip: ip, host: null, ip6: null, up_today: 0, down_today: 0,
		      hours: {}, first_seen: now(), last_seen: 0,
		      up_rate: 0, down_rate: 0, conn: 0, rssi: null };
		clients[key] = c;
	}
	if (ip != null) c.ip = ip;
	if (mac != null) {
		c.mac = mac;
		let v6 = pick6(mac);
		if (v6 != null) c.ip6 = v6;
	}
	if (c.mac != null && leases[c.mac] != null && leases[c.mac].host != null)
		c.host = leases[c.mac].host;
	return { key: key, c: c };
}

function run() {
	let arp = read_arp();
	let leases = read_leases();
	let t = now(), dt = t - prev_ts;
	if (dt <= 0) dt = 1;

	if (tick % NEIGH_EVERY == 0) {
		read_neigh6(t, read_dhcpv6());
		for (let a in v6pool)
			if ((t - v6pool[a].t) > V6_TTL) delete v6pool[a];
	}
	if (tick % RSSI_EVERY == 0) rssi = read_rssi();

	let cur = {}, seen = {};
	sample_ct(cur, seen, t);
	sample_hnat(cur, seen, t);

	/* 连接数: 本 tick 出现过的流(两源并集)归到设备 */
	let fcount = {};
	for (let k in seen) {
		let s = seen[k];
		let mac = (arp[s.ip] != null) ? arp[s.ip] : s.mac;
		if (mac != null && (mac == LAN_MAC1 || mac == LAN_MAC2)) mac = null;
		if (mac == null && s.ip == ROUTER_IP) continue;
		let rec = client_for(mac, s.ip, leases);
		let n = fcount[rec.key];
		fcount[rec.key] = (n != null) ? n + 1 : 1;
	}

	/* 流量增量归到设备 */
	let hh = hour_of(t);
	let seen_bw = {};
	for (let k in cur) {
		let f = cur[k];
		let mac = (arp[f.ip] != null) ? arp[f.ip] : f.mac;
		if (mac != null && (mac == LAN_MAC1 || mac == LAN_MAC2)) mac = null;
		if (mac == null && f.ip == ROUTER_IP) continue;
		let rec = client_for(mac, f.ip, leases);
		let c = rec.c;
		c.up_today += f.up;
		c.down_today += f.down;
		add_hour(c.hours, hh, f.up, f.down);
		add_hour(wan_hours, hh, f.up, f.down);
		c.last_seen = t;
		if (seen_bw[rec.key] == null) seen_bw[rec.key] = [0, 0];
		seen_bw[rec.key][0] += f.up;
		seen_bw[rec.key][1] += f.down;
	}

	/* ARP 在册说明近期有 L2 活动: 没流量的设备也建记录(0 速率), 已存在的续期 */
	for (let ip in arp) {
		if (ip == ROUTER_IP) continue;
		let mac = arp[ip];
		if (mac == LAN_MAC1 || mac == LAN_MAC2) continue;
		let key = client_key(mac, ip);
		let c = clients[key];
		if (c == null) {
			c = client_for(mac, ip, leases).c;
			c.last_seen = t;
			continue;
		}
		if ((t - c.last_seen) <= 600) c.last_seen = t;
	}

	let tick_up = 0, tick_dn = 0;
	for (let k in seen_bw) { tick_up += seen_bw[k][0]; tick_dn += seen_bw[k][1]; }

	/* v6 只留最新一条 + 无线信号强度, 与设备记录对齐 */
	for (let k in clients) {
		let c = clients[k];
		if (c.mac == null) { c.rssi = null; continue; }
		let v6 = pick6(c.mac);
		if (v6 != null) c.ip6 = v6;
		c.rssi = (rssi[c.mac] != null) ? rssi[c.mac] : null;
	}

	let tot_up = 0, tot_dn = 0;
	let list = [], online = 0;
	for (let k in clients) {
		let c = clients[k];
		let s = seen_bw[k] || [0, 0];
		c.up_rate = c.up_rate * (1 - RATE_ALPHA) + (s[0] / dt) * RATE_ALPHA;
		c.down_rate = c.down_rate * (1 - RATE_ALPHA) + (s[1] / dt) * RATE_ALPHA;
		if (c.up_rate < 1) c.up_rate = 0;
		if (c.down_rate < 1) c.down_rate = 0;
		c.conn = fcount[k] || 0;
		tot_up += c.up_rate; tot_dn += c.down_rate;
		let on = ((t - c.last_seen) <= ONLINE_WIN);
		if (on) online++;
		push(list, {
			mac: c.mac, ip: c.ip, ip6: c.ip6, host: c.host,
			up: int(c.up_rate), down: int(c.down_rate),
			up_today: int(c.up_today), down_today: int(c.down_today),
			hours: ((t - c.last_seen) <= 43200) ? c.hours : {},
			conn: c.conn, rssi: c.rssi,
			last_seen: int(c.last_seen), first_seen: int(c.first_seen),
			online: on
		});
	}
	sort(list, function(a, b) {
		if (a.online != b.online) return a.online ? -1 : 1;
		return (b.up + b.down) - (a.up + a.down);
	});

	let up_today = 0, down_today = 0;
	for (let k in clients) { up_today += clients[k].up_today; down_today += clients[k].down_today; }

	let out = {
		ts: t, day: day, interval: dt, hnat: hnat_ok, lan: LAN,
		wan: { up: int(tot_up), down: int(tot_dn), up_today: int(up_today),
		       down_today: int(down_today), hours: wan_hours },
		sec: { up: int(tick_up), down: int(tick_dn) },
		online: online, total: length(list),
		clients: slice(list, 0, 128)
	};
	try {
		fs.writefile(OUT_PATH + '.tmp', sprintf('%J', out));
		fs.rename(OUT_PATH + '.tmp', OUT_PATH);
	} catch (e) { warn('write failed: ' + e); }

	/* 基线清理 */
	for (let k in base)
		if (base[k].at > 0 && (t - base[k].at) > KEEP_BASE) delete base[k];

	prev_ts = t;
	tick++;

	if (day != daykey(t)) {
		day = daykey(t);
		wan_hours = {};
		for (let k in clients) { clients[k].up_today = 0; clients[k].down_today = 0; clients[k].hours = {}; }
	}
	if (tick % SAVE_EVERY == 0) save_state();
}

load_state();
prev_ts = now();
warn('client-rates: started, lan=' + LAN + ' router=' + ROUTER_IP);

/* 注意: 本固件的 ucode sleep(n) 单位是「毫秒」而非秒,
   写成 sleep(INTERVAL) 会变成 sleep(1ms) -> 空转跑满一个核。 */
const TICK_MS = INTERVAL * 1000;

/* clock(true) 返回 [秒, 纳秒], 转成毫秒 */
function clock_ms() {
	let c = clock(true);
	return c[0] * 1000 + int(c[1] / 1000000);
}

while (true) {
	let t0 = clock_ms();
	try { run(); } catch (e) { warn('client-rates tick error: ' + e); }
	/* 扣掉本轮计算耗时, 让上报周期稳定为 INTERVAL 秒 */
	let wait = TICK_MS - (clock_ms() - t0);
	if (wait < TICK_MS / 4) wait = TICK_MS / 4;
	sleep(wait);
}
