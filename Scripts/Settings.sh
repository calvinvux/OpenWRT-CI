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
# Tinh chỉnh tự động cho Link NN6000 v2 (IPTV + Docker + BBR + AdGuardHome + NSS)
# ==============================================================================

# 1. Cờ Multicast & Docker Cgroups vào kernel config của qualcommax
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
net.core.netdev_max_backlog=4096
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.netfilter.nf_conntrack_tcp_timeout_established=3600
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

# 4. Tích hợp AdGuardHome bản Stable chính chủ mới nhất (linux_arm64)
echo ">>> Tải AdGuardHome bản Stable mới nhất (linux_arm64)..."
rm -rf /tmp/agh_dl && mkdir -p /tmp/agh_dl ./package/base-files/files/usr/bin ./package/base-files/files/etc/init.d
curl -fsSL "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_arm64.tar.gz" -o /tmp/agh_dl/agh.tar.gz
tar -xzf /tmp/agh_dl/agh.tar.gz -C /tmp/agh_dl
AGH_SRC=$(find /tmp/agh_dl -type f -name "AdGuardHome" | head -n 1)
if [ -z "$AGH_SRC" ]; then
    echo "ERROR: Không tìm thấy binary AdGuardHome trong gói tải về!" >&2
    exit 1
fi
cp -f "$AGH_SRC" ./package/base-files/files/usr/bin/AdGuardHome
chmod 755 ./package/base-files/files/usr/bin/AdGuardHome
rm -rf /tmp/agh_dl

cat > ./package/base-files/files/etc/init.d/AdGuardHome << 'EOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

start_service() {
    local AGH_BIN="/usr/bin/AdGuardHome"
    local WORK_DIR="/etc/AdGuardHome"

    if [ -x /opt/AdGuardHome/AdGuardHome ]; then
        AGH_BIN="/opt/AdGuardHome/AdGuardHome"
    fi
    if [ -d /opt ] || [ -L /opt ]; then
        WORK_DIR="/opt/AdGuardHome"
    fi
    mkdir -p "$WORK_DIR"

    procd_open_instance
    procd_set_param command "$AGH_BIN" --work-dir "$WORK_DIR" --no-check-update
    procd_set_param env TZ=Asia/Ho_Chi_Minh
    procd_set_param respawn "${respawn_threshold:-3600}" "${respawn_timeout:-5}" "${respawn_retry:-5}"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod 755 ./package/base-files/files/etc/init.d/AdGuardHome

# 5. Cấu hình mặc định khi flash mới (uci-defaults)
mkdir -p ./package/base-files/files/etc/uci-defaults
cat > ./package/base-files/files/etc/uci-defaults/99-nn6000-defaults << 'EOF'
#!/bin/sh
uci -q set system.@system[0].zonename='Asia/Ho_Chi_Minh'
uci -q set system.@system[0].timezone='<+07>-7'
uci -q commit system

if [ -x /usr/bin/nss_freq ]; then
    uci -q set nss_freq.settings=nss_freq
    uci -q set nss_freq.settings.level='high'
    uci -q commit nss_freq
fi

/etc/init.d/AdGuardHome enable 2>/dev/null || true
exit 0
EOF
chmod 755 ./package/base-files/files/etc/uci-defaults/99-nn6000-defaults
