#!/bin/bash
# IPv6 活动网络服务测试 - 真实 Mac 风格
set -e

echo "====== IPv6 活动网络服务测试 ======"
echo ""

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMP=$(mktemp -d)
trap "rm -rf '$TEMP'" EXIT

HOME="$TEMP/home"
FAKEBIN="$TEMP/bin"
mkdir -p "$HOME/.claude-switcher" "$FAKEBIN"

# 提取函数
cat > "$TEMP/test-functions.sh" << 'EXTRACT_END'
check_ipv6_status() {
    local service_order active_services svc svc_iface svc_status v6_info v6_rc getinfo_output enabled_services
    
    # 1. 获取网络服务顺序及接口映射(必须成功)
    service_order=$(networksetup -listnetworkserviceorder 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$service_order" ]; then
        echo "unknown:无法获取网络服务顺序"
        return
    fi
    
    # 2. 解析活动服务(Bash 3.2 兼容)
    active_services=$(echo "$service_order" | awk '
        /^\([0-9]+\)/ {
            gsub(/^\([0-9]+\) /, "")
            svc_name = $0
            getline
            if ($0 ~ /Device: [a-z0-9]+\)/) {
                sub(/.*Device: /, "")
                sub(/\).*/, "")
                iface = $0
                if (iface !~ /^(lo|utun|awdl|llw|bridge|gif|stf|p2p)/) {
                    print svc_name "|" iface
                }
            }
        }
    ')
    
    if [ -z "$active_services" ]; then
        echo "unknown:无法解析活动网络服务"
        return
    fi
    
    # 3. 检查活动物理接口是否有公网 IPv6
    if ! ifconfig >/dev/null 2>&1; then
        echo "unknown:ifconfig执行失败"
        return
    fi
    
    local has_public_inet6_on_active
    has_public_inet6_on_active=$(echo "$active_services" | while IFS='|' read -r svc_name svc_iface; do
        ifconfig "$svc_iface" 2>/dev/null | awk -v iface="$svc_iface" '
            /inet6/ {
                addr=$2
                if (addr !~ /^fe80:/ && addr !~ /^fc/ && addr !~ /^fd/) {
                    print iface ":" addr
                    exit
                }
            }
        '
    done | head -1)
    
    # 4. 检查活动服务的 IPv6 配置
    enabled_services=""
    echo "$active_services" | while IFS='|' read -r svc_name svc_iface; do
        getinfo_output=$(networksetup -getinfo "$svc_name" 2>/dev/null)
        v6_rc=$?
        if [ $v6_rc -ne 0 ]; then
            echo "unknown:服务[$svc_name]getinfo失败"
            return
        fi
        v6_info=$(echo "$getinfo_output" | grep -i '^IPv6:')
        if [ -z "$v6_info" ]; then
            echo "unknown:服务[$svc_name]缺失IPv6字段"
            return
        fi
        if ! echo "$v6_info" | grep -qi 'off'; then
            enabled_services="${enabled_services}${enabled_services:+,}$svc_name"
        fi
    done > "$HOME/.claude-switcher/.ipv6check.tmp" 2>&1
    
    # 5. 读取检查结果
    if [ -f "$HOME/.claude-switcher/.ipv6check.tmp" ]; then
        local check_result
        check_result=$(cat "$HOME/.claude-switcher/.ipv6check.tmp")
        rm -f "$HOME/.claude-switcher/.ipv6check.tmp"
        if echo "$check_result" | grep -q "^unknown:"; then
            echo "$check_result"
            return
        fi
        enabled_services="$check_result"
    fi
    
    # 6. 判断最终状态
    if [ -n "$enabled_services" ]; then
        echo "on:$enabled_services"
    elif [ -n "$has_public_inet6_on_active" ]; then
        echo "on:活动接口有公网IPv6($has_public_inet6_on_active)"
    else
        echo "off"
    fi
}
EXTRACT_END

# 创建 mock - 真实 Mac 格式
cat > "$FAKEBIN/networksetup" << 'EOF'
#!/bin/bash
case "$1" in
    -listnetworkserviceorder)
        case "$SCENARIO" in
            real_mac_wifi2_active)
                # 真实场景: Wi-Fi 2 活动, Thunderbolt/iPhone 闲置
                cat << 'NETORDER'
An asterisk (*) denotes that a network service is disabled.
(1) Wi-Fi 2
(Hardware Port: Wi-Fi, Device: en0)

(2) Thunderbolt Bridge
(Hardware Port: Thunderbolt Bridge, Device: bridge0)

(3) iPhone USB
(Hardware Port: iPhone USB, Device: en7)

(4) Ethernet
(Hardware Port: Ethernet, Device: en1)
NETORDER
                ;;
            list_fail)
                exit 1 ;;
        esac ;;
    -getinfo)
        case "$SCENARIO" in
            real_mac_wifi2_active)
                case "$2" in
                    "Wi-Fi 2")
                        echo "DHCP Configuration"
                        echo "IP address: 192.168.1.100"
                        echo "IPv6: Off" ;;
                    "Thunderbolt Bridge")
                        echo "IPv6: Automatic" ;;
                    "iPhone USB")
                        echo "IPv6: Automatic" ;;
                    "Ethernet")
                        echo "IPv6: Off" ;;
                esac ;;
        esac ;;
esac
EOF

cat > "$FAKEBIN/ifconfig" << 'EOF'
#!/bin/bash
case "$1" in
    "")
        # ifconfig 无参数: 列出所有接口
        case "$SCENARIO" in
            real_mac_wifi2_active)
                cat << 'IFCONFIG'
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000 
	inet6 ::1 prefixlen 128 
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.100 netmask 0xffffff00 broadcast 192.168.1.255
awdl0: flags=8943<UP,BROADCAST,RUNNING,PROMISC,SIMPLEX,MULTICAST> mtu 1484
	inet6 fe80::abcd:ef01:2345:6789%awdl0 prefixlen 64 scopeid 0x8
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet6 fd00:1111:2222:3333::1 prefixlen 64
bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
en7: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
IFCONFIG
                ;;
        esac ;;
    en0|en1|en7|bridge0)
        # ifconfig en0: 单个接口
        case "$SCENARIO" in
            real_mac_wifi2_active)
                case "$1" in
                    en0)
                        echo "en0: flags=8863<UP> mtu 1500"
                        echo "	inet 192.168.1.100" ;;
                    en1)
                        echo "en1: flags=8863<UP> mtu 1500" ;;
                    en7)
                        echo "en7: flags=8822<BROADCAST> mtu 1500" ;;
                    bridge0)
                        echo "bridge0: flags=8863<UP> mtu 1500" ;;
                esac ;;
        esac ;;
esac
EOF

cat > "$FAKEBIN/awk" << 'EOF'
#!/bin/bash
/usr/bin/awk "$@"
EOF

chmod +x "$FAKEBIN"/*

export PATH="$FAKEBIN:/usr/bin:/bin"
export HOME="$HOME"
source "$TEMP/test-functions.sh"

# 测试 1: 真实 Mac 场景 - Wi-Fi 2 活动 Off, Thunderbolt/iPhone 闲置 Automatic
echo "测试 1: 真实 Mac 场景"
echo "  Wi-Fi 2 (en0): active, IPv6 Off"
echo "  Thunderbolt Bridge (bridge0): inactive, IPv6 Automatic"
echo "  iPhone USB (en7): inactive, IPv6 Automatic"
echo "  Ethernet (en1): active, IPv6 Off"
echo "  lo0: inet6 ::1, awdl0: fe80, utun4: fd00 ULA"
export SCENARIO=real_mac_wifi2_active
result=$(check_ipv6_status)
if [ "$result" = "off" ]; then
    echo "✓ 通过: 正确识别活动服务 IPv6 Off,不受闲置服务影响"
else
    echo "✗ 失败: 期望 off, 实际 $result"
    echo "  闲置 Thunderbolt/iPhone Automatic 不应导致 on"
    exit 1
fi
echo ""

# 测试 2: listnetworkserviceorder 失败
echo "测试 2: networksetup -listnetworkserviceorder 失败"
export SCENARIO=list_fail
result=$(check_ipv6_status)
if echo "$result" | grep -q "^unknown:无法获取网络服务顺序"; then
    echo "✓ 通过: 正确返回 unknown"
else
    echo "✗ 失败: 期望 unknown, 实际 $result"
    exit 1
fi
echo ""

echo "====== 活动网络服务测试通过 ======"
