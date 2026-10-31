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

echo "==== [diy] OAF 页面注入 client-rates 速率桥接脚本 ===="
# 目的: 仪表盘右上角 WAN 实时速率卡片 + 终端列表上下行速率改用本机 HNAT 采样值。
# 只追加一段 <script>, 不改动 OAF 自身逻辑; 重复执行会跳过(幂等)。
for f in package/OpenAppFilter/luci-app-oaf/luasrc/view/oaf/dashboard.htm \
         package/OpenAppFilter/luci-app-oaf/luasrc/view/oaf/user_status.htm \
         package/OpenAppFilter/luci-app-oaf/luasrc/view/oaf/user_detail.htm; do
  if [ -f "$f" ]; then
    if grep -q 'client-rates/oaf-bridge.js' "$f"; then
      echo "    已存在, 跳过: $f"
    else
      printf '\n<script src="/luci-static/resources/client-rates/oaf-bridge.js?v=6"></script>\n' >> "$f"
      grep -q 'client-rates/oaf-bridge.js' "$f" \
        && echo "    注入成功: $f" || { echo "    [错误] 注入失败: $f"; exit 1; }
    fi
  else
    echo "    [警告] 未找到 $f (OAF 目录结构可能变化)"
  fi
done

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

/* ==== client-rates: 防火墙区块底部留白 (begin) ==== */
/* 区块内最后一行(如「转发」下拉、「流量卸载类型」)原本贴住卡片底边(gap=0),
   与行间 14px 的间距不协调, 统一补 1rem 下内边距。 */
#cbi-firewall-defaults > .cbi-section-node,
#cbi-firewall-zone > .cbi-section-node,
#cbi-firewall-forwarding > .cbi-section-node {
	padding-bottom: 1rem !important;
}
/* ==== client-rates: 防火墙区块底部留白 (end) ==== */
CR_CUSTOM_CSS
      grep -q "$CR_CSS_MARK" "$f" \
        && echo "    追加完成: $f" || { echo "    [错误] 追加失败: $f"; exit 1; }
    fi
  done
else
  echo "    [警告] 未找到 argon cascade.css, 跳过"
fi

echo "==== [diy-part2/24.10] 完成 ===="
