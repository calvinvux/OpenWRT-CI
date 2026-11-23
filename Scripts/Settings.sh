#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} +
#修改默认主题
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} +
#修改immortalwrt.lan关联IP
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} +
#添加编译日期标识
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" {} +

#修改默认WIFI账号密码
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
ROUTER_TOOL="./package/emortal/luci-app-router-tool/root/etc/config/router-tool"
for file in "$ROUTER_TOOL" "$WIFI_UC"; do
	[ -f "$file" ] && sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g; s/key '.*'/key '$WRT_WORD'/g" "$file"
done

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "$WRT_WIFI" == "WIFI-NO" ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

# ==============================================================================
# Tinh chỉnh tự động cho Link NN6000 v2 (LAN 192.168.5.0/24 + IPTV + Docker + BBR)
# ==============================================================================

# 1. Ép IP LAN mặc định thành 192.168.5.1 (192.168.5.0/24)
sed -i "s/192\.168\.[0-9]*\.1/192.168.5.1/g" ./package/base-files/files/bin/config_generate

# 2. Cờ Multicast & Docker Cgroups vào kernel config của qualcommax
TARGET_KERNEL_CONFIG=$(find ./target/linux/qualcommax/ -maxdepth 1 -name "config-*" | sort -V | tail -n 1)
if [ -f "$TARGET_KERNEL_CONFIG" ]; then
    echo ">>> Áp dụng cờ Multicast & Docker Cgroups vào $TARGET_KERNEL_CONFIG"
    cat >> "$TARGET_KERNEL_CONFIG" << 'EOF'
CONFIG_IP_MULTICAST=y
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_MROUTE=y
CONFIG_IP_MROUTE_MULTIPLE_TABLES=y
CONFIG_CGROUPS=y
CONFIG_MEMCG=y
CONFIG_CGROUP_SCHED=y
CONFIG_FAIR_GROUP_SCHED=y
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
EOF
fi

# 3. Sysctl: IGMPv2 cho IPTV FPT, tắt rp_filter, BBR trên fq_codel, conntrack 64K
mkdir -p ./package/base-files/files/etc
cat >> ./package/base-files/files/etc/sysctl.conf << 'EOF'
net.ipv4.conf.all.force_igmp_version=2
net.ipv4.conf.default.force_igmp_version=2
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.netfilter.nf_conntrack_max=65536
EOF
