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

echo "==== [diy-part2] 拉取 jerrykuku 最新版 argon 主题与配置插件 ===="
# 删除 feeds 中自带的旧版, 避免冲突
rm -rf feeds/luci/themes/argon feeds/luci/applications/luci-app-argon-config
rm -rf package/feeds/luci/argon package/feeds/luci/luci-app-argon-config
git clone --depth=1 https://github.com/jerrykuku/luci-theme-argon package/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-app-argon-config package/luci-app-argon-config
[ -f package/luci-theme-argon/Makefile ] && echo "    luci-theme-argon (jerrykuku 最新) OK"
[ -f package/luci-app-argon-config/Makefile ] && echo "    luci-app-argon-config (jerrykuku 最新) OK"

echo "==== [diy-part2] 完成 ===="
