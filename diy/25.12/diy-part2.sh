#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: 自定义插件 (在 feeds update 之后、feeds install 之前执行)
#
# 为什么在这个时机:
#   - 必须在 feeds update -a 之后: 否则 packages feed 会把 golang 目录重新拉回覆盖
#   - 必须在 feeds install -a 之前: 否则删除 OpenAppFilter 会残留 package/feeds 下的旧符号链接
#
set -e

echo "==== [diy-part2] 替换 golang feed 为 sbwml 26.x ===="
rm -rf feeds/packages/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang

echo "==== [diy-part2] 清理源码中已有的 v2ray-geodata / mosdns ===="
find ./ | grep Makefile | grep v2ray-geodata | xargs -r rm -f
find ./ | grep Makefile | grep mosdns | xargs -r rm -f

echo "==== [diy-part2] 删除仓库原有 OpenAppFilter, 重新拉取 destan19 最新版 ===="
find . -type d \( -name "OpenAppFilter" -o -name "luci-app-oaf" -o -name "open-app-filter" \) -exec rm -rf {} +
rm -rf package/feeds/*/luci-app-oaf package/feeds/*/OpenAppFilter
git clone https://github.com/destan19/OpenAppFilter package/OpenAppFilter

echo "==== [diy] OAF 页面注入 client-rates 速率桥接脚本 ===="
# 目的: 仪表盘右上角 WAN 实时速率卡片 + 终端列表上下行速率改用本机 HNAT 采样值。
# 只追加一段 <script>, 不改动 OAF 自身逻辑; 重复执行会跳过(幂等)。
for f in package/OpenAppFilter/luci-app-oaf/luasrc/view/oaf/dashboard.htm \
         package/OpenAppFilter/luci-app-oaf/luasrc/view/oaf/user_status.htm; do
  if [ -f "$f" ]; then
    if grep -q 'client-rates/oaf-bridge.js' "$f"; then
      echo "    已存在, 跳过: $f"
    else
      printf '\n<script src="/luci-static/resources/client-rates/oaf-bridge.js?v=5"></script>\n' >> "$f"
      grep -q 'client-rates/oaf-bridge.js' "$f" \
        && echo "    注入成功: $f" || { echo "    [错误] 注入失败: $f"; exit 1; }
    fi
  else
    echo "    [警告] 未找到 $f (OAF 目录结构可能变化)"
  fi
done

echo "==== [diy-part2] 克隆 luci-app-mosdns (v5) 与 v2ray-geodata ===="
git clone https://github.com/sbwml/luci-app-mosdns -b v5 package/mosdns
git clone https://github.com/sbwml/v2ray-geodata package/v2ray-geodata

echo "==== [diy-part2] 修复 S20P 两个 2.5G 口指示灯 (0x001b -> 0x321b) ===="
LED_DTS="target/linux/mediatek/dts-ext/mt7986a-clx-s20p.dts"
if [ -f "$LED_DTS" ]; then
  sed -i 's/realtek,led-act-select = <0x001b>/realtek,led-act-select = <0x321b>/g' "$LED_DTS"
  if grep -q 'realtek,led-act-select = <0x321b>' "$LED_DTS"; then
    echo "    DTS LED 配置已应用: modeA + 400ms/12.5%/60ms + 10M LPI"
  else
    echo "    [警告] 未匹配到 0x001b, 请确认是否已修复或路径变化"
  fi
else
  echo "    [警告] 未找到 $LED_DTS, 跳过 LED 修复"
fi

echo "==== [diy-part2] 修复 realtek 驱动丢失的 LED 配置调用(根因) ===="
# 内核 6.12 的 733 补丁只定义了 rtl8221b_config_led() 却从未调用它(死代码),
# 导致 realtek,led-act-select 等属性完全不生效、2.5G 灯不亮。
# 6.6 的 790 补丁是在 rtl822xb_config_init 末尾调用, 此处把调用补回去。
LED_PATCH="target/linux/mediatek/patches-6.12/734-net-phy-realtek-call-rtl8221b_config_led.patch"
if [ -d target/linux/mediatek/patches-6.12 ]; then
cat > "$LED_PATCH" <<'EOF'
From: S20P build fix
Subject: net: phy: realtek: call rtl8221b_config_led from rtl822xb_config_init

The 6.12 backport (patch 733) defines rtl8221b_config_led() but never
calls it, so the realtek,led-*-select DT properties have no effect and
the 2.5G port LEDs stay dark (e.g. CLX S20P). Restore the call that
exists in the 6.6 patch (790).
---
--- a/drivers/net/phy/realtek/realtek_main.c
+++ b/drivers/net/phy/realtek/realtek_main.c
@@ -1520,6 +1520,12 @@
 static int rtl822xb_config_init(struct phy_device *phydev)
 {
-	return rtl822x_set_serdes_option_mode(phydev, false);
+	int ret;
+
+	ret = rtl822x_set_serdes_option_mode(phydev, false);
+	if (ret < 0)
+		return ret;
+
+	return rtl8221b_config_led(phydev);
 }
 
 static int rtl822xb_read_status(struct phy_device *phydev)
EOF
  echo "    已生成补丁: $LED_PATCH"
else
  echo "    [警告] 未找到 patches-6.12 目录, 跳过"
fi

echo "==== [diy-part2] 默认管理 IP 改为 192.168.6.1 ===="
CONFIG_GEN="package/base-files/files/bin/config_generate"
if [ -f "$CONFIG_GEN" ]; then
  sed -i 's/192\.168\.1\.1/192.168.6.1/g' "$CONFIG_GEN"
  grep -q '192.168.6.1' "$CONFIG_GEN" && echo "    默认 IP 已改为 192.168.6.1" || echo "    [警告] 替换失败"
else
  echo "    [警告] 未找到 $CONFIG_GEN, 跳过"
fi

echo "==== [diy-part2] argon / argon-config: 保留源码(luci feed)自带老版本 ===="
# 按要求: 已去除 jerrykuku 最新版的拉取动作, 不删除也不覆盖 feeds 自带的 argon。
# 直接使用 luci feed 中随源码一起的 luci-theme-argon / luci-app-argon-config 老版本。
echo "    跳过最新版拉取 -> 沿用源码自带 argon 主题与 argon 配置插件"

echo "==== [diy-part2] argon 主题: 追加 client-rates 自定义样式(防火墙区域表格排版) ===="
# 目的: 修正防火墙「区域」表格的区域徽标排版(徽标被拉成整列宽色条 / 顶到单元格边缘),
#       并在桌面宽度下把区域表还原成真实表格, 避免 LuCI 响应式卡片样式与上下区块不一致。
# 做法: 构建时把样式追加进 argon 主题 cascade.css, 带标记幂等(重复执行会跳过)。
CR_CSS_MARK='client-rates: 防火墙'
CR_THEME_CSS=$(find feeds package -path '*argon*' -name cascade.css -type f 2>/dev/null || true)
if [ -n "$CR_THEME_CSS" ]; then
  for f in $CR_THEME_CSS; do
    if grep -q "$CR_CSS_MARK" "$f"; then
      echo "    已存在, 跳过: $f"
    else
      cat >> "$f" <<'CR_CUSTOM_CSS'

/* ==== client-rates: 防火墙「区域」表格排版修正 (begin) ==== */
/* 1) 区域徽标被主题拉成整列宽的色条、wan 与 ACCEPT 徽标分散到列尾并顶到单元格边缘，
      改为紧凑徽标并左对齐: [lan] ⇒ [wan] / [ACCEPT all others] */
#cbi-firewall-zone .zone-forwards {
	display: flex;
	align-items: center;
	justify-content: flex-start;
	gap: .45rem;
}
#cbi-firewall-zone .zone-forwards > span {
	flex: 0 0 auto;
}
#cbi-firewall-zone .zone-src,
#cbi-firewall-zone .zone-dest {
	display: flex;
	flex-direction: column;
	align-items: flex-start;
	gap: .2rem;
	flex: 0 0 auto;
	min-width: 0;
}
#cbi-firewall-zone .zonebadge {
	display: inline-block;
	width: auto;
	max-width: 100%;
	white-space: nowrap;
	padding: .1rem .55rem;
	border-radius: 6px;
	line-height: 1.5;
	font-size: 90%;
	text-align: center;
}
#cbi-firewall-zone .table > thead > tr > th:first-child {
	text-align: left;
	padding-left: 1.25rem;
}

/* 2) 桌面宽度下区域表恢复成真实表格：主题的 .table{display:block} 会把表格拆成
      独立的 thead / tbody 匿名表格，列宽各算各的；同时在窄窗口下 LuCI 会退化成
      卡片式（每行 250px 高、字段名重复显示），与上方「通用设置」区块风格不一致。 */
@media (min-width: 1100px) {
	#cbi-firewall-zone .table {
		display: table !important;
		width: 100% !important;
	}
	#cbi-firewall-zone .table > thead {
		display: table-header-group !important;
	}
	#cbi-firewall-zone .table > tbody {
		display: table-row-group !important;
	}
	#cbi-firewall-zone .table tr {
		display: table-row !important;
	}
	#cbi-firewall-zone .table th,
	#cbi-firewall-zone .table td {
		display: table-cell !important;
		width: auto !important;
		float: none !important;
	}
	#cbi-firewall-zone .table th::before,
	#cbi-firewall-zone .table td::before {
		content: none !important;
	}
}
/* ==== client-rates: 防火墙「区域」表格排版修正 (end) ==== */
CR_CUSTOM_CSS
      grep -q "$CR_CSS_MARK" "$f" \
        && echo "    追加完成: $f" || { echo "    [错误] 追加失败: $f"; exit 1; }
    fi
  done
else
  echo "    [警告] 未找到 argon cascade.css, 跳过"
fi

echo "==== [diy-part2] 完成 ===="
