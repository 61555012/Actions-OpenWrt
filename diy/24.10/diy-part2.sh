#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File: diy/24.10/diy-part2.sh
# 源码: Yuzhii0718/immortalwrt-mt798x-6.6-padavanonly (openwrt-24.10-6.6)
# 执行时机: feeds update -a 之后 / feeds install -a 之前
#
# 与 25.12 保持一致的插件: mosdns(sbwml v5) + v2ray-geodata + OpenAppFilter(destan19)
# 24.10 额外: wrtbwmon (feeds 自带, 这里做可用性兜底)
# argon / argon-config: 不拉取最新版, 使用源码自带老版本
#
set -e

echo "==== [diy-part2/24.10] 替换 golang feed 为 sbwml 26.x (与 25.12 一致) ===="
rm -rf feeds/packages/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang

echo "==== [diy-part2/24.10] 清理源码已有的 v2ray-geodata / mosdns ===="
find ./ | grep Makefile | grep v2ray-geodata | xargs -r rm -f
find ./ | grep Makefile | grep mosdns | xargs -r rm -f

echo "==== [diy-part2/24.10] 删除源码自带 OpenAppFilter, 重拉 destan19 最新版 ===="
find . -type d \( -name "OpenAppFilter" -o -name "luci-app-oaf" -o -name "open-app-filter" \) -exec rm -rf {} +
rm -rf package/feeds/*/luci-app-oaf package/feeds/*/OpenAppFilter
git clone https://github.com/destan19/OpenAppFilter package/OpenAppFilter

echo "==== [diy-part2/24.10] 克隆 luci-app-mosdns(v5) 与 v2ray-geodata ===="
git clone https://github.com/sbwml/luci-app-mosdns -b v5 package/mosdns
git clone https://github.com/sbwml/v2ray-geodata package/v2ray-geodata

echo "==== [diy-part2/24.10] 关键包可用性检查 (源码自带, 无需外部 feed) ===="
# 源码已自带: package/mtk/applications/{wrtbwmon,luci-app-wrtbwmon,mtwifi-cfg,
#             luci-app-mtwifi-cfg,luci-app-turboacc-mtk,mii_mgr,regs,switch,datconf}
for d in package/mtk/applications/wrtbwmon \
         package/mtk/applications/luci-app-wrtbwmon \
         package/mtk/applications/mtwifi-cfg \
         package/mtk/applications/luci-app-mtwifi-cfg \
         package/mtk/applications/luci-app-turboacc-mtk \
         package/mtk/drivers/mt_wifi \
         package/mtk/drivers/warp; do
  if [ -d "$d" ]; then
    echo "    OK   $d"
  else
    echo "    [警告] 缺少 $d (源码结构可能已变更)"
  fi
done
# 注意: 不要从上游再拉一份 luci-app-wrtbwmon, 会与源码自带的同名包冲突

echo "==== [diy-part2/24.10] argon / argon-config: 保留源码(luci feed)自带老版本 ===="
# 按要求: 去除 jerrykuku 最新版拉取动作, 直接使用源码自带 argon 主题与配置插件。
echo "    跳过最新版拉取 -> 沿用源码自带 luci-theme-argon / luci-app-argon-config"

echo "==== [diy-part2/24.10] 默认管理 IP 改为 192.168.6.1 ===="
CONFIG_GEN="package/base-files/files/bin/config_generate"
if [ -f "$CONFIG_GEN" ]; then
  sed -i 's/192\.168\.1\.1/192.168.6.1/g' "$CONFIG_GEN"
  grep -q '192.168.6.1' "$CONFIG_GEN" && echo "    默认 IP 已改为 192.168.6.1" || echo "    [警告] 替换失败"
else
  echo "    [警告] 未找到 $CONFIG_GEN, 跳过"
fi

echo "==== [diy-part2/24.10] 完成 ===="
