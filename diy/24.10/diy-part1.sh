#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File: diy/24.10/diy-part1.sh
# 源码: Yuzhii0718/immortalwrt-mt798x-6.6-padavanonly (openwrt-24.10-6.6)
# 说明: 24.10 使用源码默认 feeds
#         - argon / argon-config 直接来自 luci feed 自带老版本(不额外拉取最新)
#         - wrtbwmon / luci-app-wrtbwmon 来自 packages / luci feed, 无需额外 feed
#       如后续需要追加 feed, 在此 echo 'src-git ...' >>feeds.conf.default 即可。
#

echo "[diy-part1/24.10] 使用源码默认 feeds (argon 采用 luci feed 自带版本)"
