#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# 说明: 本机型(chasey-dev 25.12 / S20P)无需额外 feed,
#       插件(mosdns / OpenAppFilter)全部在 diy-part2.sh 中以源码克隆方式加入。
#       如需额外 feed, 在此追加 src-git 行即可。
#

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
