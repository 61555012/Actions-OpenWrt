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
    echo "    LED 已修复: modeA + 400ms/12.5%/60ms + 10M LPI"
  else
    echo "    [警告] 未匹配到 0x001b, 请确认是否已修复或路径变化"
  fi
else
  echo "    [警告] 未找到 $LED_DTS, 跳过 LED 修复"
fi

echo "==== [diy-part2] 完成 ===="
