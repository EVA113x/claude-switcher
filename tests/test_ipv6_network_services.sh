#!/bin/bash
# IPv6 网络服务检测回归测试 - 修正版
set -e

echo "====== IPv6 网络服务检测测试(修正版) ======"
echo ""

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMP=$(mktemp -d)
trap "rm -rf '$TEMP'" EXIT

HOME="$TEMP/home"
FAKEBIN="$TEMP/bin"
mkdir -p "$HOME" "$FAKEBIN"

# 提取相关函数到测试脚本
cat > "$TEMP/test-functions.sh" << 'EXTRACT_END'
check_ipv6_status() {
    local services enabled_services svc v6_info has_public_inet6
    # 枚举所有网络服务的 IPv6 配置状态
    services=$(networksetup -listallnetworkservices 2>/dev/null | grep -v '^\*' | grep -v '^An asterisk')
    if [ -z "$services" ]; then
        echo "unknown:无法列出网络服务"
        return
    fi
    enabled_services=""
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        v6_info=$(networksetup -getinfo "$svc" 2>/dev/null | grep -i '^IPv6:')
        # 服务配置为 Off 才视为已关闭,其他(Automatic/Manual/Link-local)都算启用
        if [ -n "$v6_info" ] && ! echo "$v6_info" | grep -qi 'off'; then
            enabled_services="${enabled_services}${enabled_services:+,}$svc"
        fi
    done <<< "$services"
    
    if [ -n "$enabled_services" ]; then
        echo "on:$enabled_services"
    else
        # 所有网络服务配置都是 Off,但仍需检查是否有非回环/非隧道的 inet6
        # 过滤掉 lo0(::1)、utun(ULA)、awdl(link-local fe80)
        has_public_inet6=$(ifconfig 2>/dev/null | awk '
            /^[a-z]/ { iface=$1; sub(/:$/,"",iface) }
            /inet6/ && iface !~ /^(lo|utun|awdl|llw)/ {
                addr=$2
                # 排除 link-local(fe80::) 和 ULA(fc00::/7, fd00::/8)
                if (addr !~ /^fe80:/ && addr !~ /^fc/ && addr !~ /^fd/) {
                    print addr
                    exit
                }
            }
        ')
        if [ -n "$has_public_inet6" ]; then
            echo "on:所有服务显示 Off,但物理接口仍有公网 IPv6($has_public_inet6)"
        else
            echo "off"
        fi
    fi
}

get_ipv6_enabled_services() {
    local services svc v6_info
    services=$(networksetup -listallnetworkservices 2>/dev/null | grep -v '^\*' | grep -v '^An asterisk')
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        v6_info=$(networksetup -getinfo "$svc" 2>/dev/null | grep -i '^IPv6:')
        if [ -n "$v6_info" ] && ! echo "$v6_info" | grep -qi 'off'; then
            # 用 NUL 分隔服务名,避免空格/引号问题
            printf '%s\0' "$svc"
        fi
    done <<< "$services"
}
EXTRACT_END

# 创建 mock 命令
cat > "$FAKEBIN/ifconfig" << 'EOF'
#!/bin/bash
# 模拟真实 macOS ifconfig 输出
case "$SCENARIO" in
    real_wifi2_off)
        # 真实场景: lo0 ::1, utun ULA, awdl link-local, en0 无 inet6
        cat << 'IFCONFIG_END'
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
	inet6 ::1 prefixlen 128
utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet6 fd12:3456:789a::1 prefixlen 64
utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
	inet6 fd00:1111:2222:3333::1 prefixlen 64
awdl0: flags=8943<UP,BROADCAST,RUNNING,PROMISC,SIMPLEX,MULTICAST> mtu 1484
	inet6 fe80::abcd:ef01:2345:6789%awdl0 prefixlen 64 scopeid 0x8
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.100 netmask 0xffffff00 broadcast 192.168.1.255
IFCONFIG_END
        ;;
    service_on_but_filtered)
        # 服务启用,但只有 link-local/ULA
        cat << 'IFCONFIG_END'
lo0: inet6 ::1 prefixlen 128
utun0: inet6 fd12:3456::1 prefixlen 64
awdl0: inet6 fe80::1%awdl0 prefixlen 64
en0: flags=8863<UP> mtu 1500
	inet 192.168.1.100
	inet6 fe80::1234:5678%en0 prefixlen 64 secured scopeid 0x6
IFCONFIG_END
        ;;
    service_on_with_public)
        # 服务启用,且有公网 IPv6
        cat << 'IFCONFIG_END'
lo0: inet6 ::1 prefixlen 128
utun0: inet6 fd12:3456::1 prefixlen 64
en0: flags=8863<UP> mtu 1500
	inet 192.168.1.100
	inet6 2001:db8:abcd::1 prefixlen 64
IFCONFIG_END
        ;;
    no_inet6)
        # 完全无 inet6
        cat << 'IFCONFIG_END'
lo0: flags=8049<UP,LOOPBACK> mtu 16384
	inet 127.0.0.1
en0: flags=8863<UP> mtu 1500
	inet 192.168.1.100
IFCONFIG_END
        ;;
esac
EOF

cat > "$FAKEBIN/networksetup" << 'EOF'
#!/bin/bash
case "$1" in
    -listallnetworkservices)
        case "$SCENARIO" in
            real_wifi2_off|service_on_but_filtered|service_on_with_public|no_inet6)
                echo "An asterisk (*) denotes that a network service is disabled."
                echo "Wi-Fi 2"
                echo "Ethernet"
                echo "Thunderbolt Bridge" ;;
            no_services)
                exit 1 ;;
        esac ;;
    -getinfo)
        svc="$2"
        case "$SCENARIO:$svc" in
            real_wifi2_off:"Wi-Fi 2"|real_wifi2_off:Ethernet|real_wifi2_off:"Thunderbolt Bridge")
                echo "IPv6: Off" ;;
            service_on_but_filtered:"Wi-Fi 2")
                echo "IPv6: Automatic" ;;
            service_on_but_filtered:Ethernet|service_on_but_filtered:"Thunderbolt Bridge")
                echo "IPv6: Off" ;;
            service_on_with_public:"Wi-Fi 2")
                echo "IPv6: Automatic" ;;
            service_on_with_public:*)
                echo "IPv6: Off" ;;
            no_inet6:*)
                echo "IPv6: Off" ;;
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

# 测试 1: 真实场景 - Wi-Fi 2 IPv6 Off, lo0/utun/awdl 有 inet6
echo "测试 1: 真实场景(Wi-Fi 2 Off, lo0/utun/awdl 有 inet6)"
export SCENARIO=real_wifi2_off
result=$(check_ipv6_status)
if [ "$result" = "off" ]; then
    echo "✓ 通过: 正确识别 IPv6 已关闭(忽略 lo0/utun/awdl)"
else
    echo "✗ 失败: 期望 off, 实际 $result"
    exit 1
fi
echo ""

# 测试 2: 服务启用但只有 link-local/ULA
echo "测试 2: 服务启用 Automatic,但只有 link-local/ULA"
export SCENARIO=service_on_but_filtered
result=$(check_ipv6_status)
if echo "$result" | grep -q "^on:.*Wi-Fi 2"; then
    echo "✓ 通过: 正确识别服务启用(即使只有 link-local)"
else
    echo "✗ 失败: 期望 on:Wi-Fi 2, 实际 $result"
    exit 1
fi
echo ""

# 测试 3: 服务启用且有公网 IPv6
echo "测试 3: 服务启用 Automatic,有公网 IPv6"
export SCENARIO=service_on_with_public
result=$(check_ipv6_status)
if echo "$result" | grep -q "^on:.*Wi-Fi 2"; then
    echo "✓ 通过: 正确识别服务启用(有公网 IPv6)"
else
    echo "✗ 失败: 期望 on:Wi-Fi 2, 实际 $result"
    exit 1
fi
echo ""

# 测试 4: 完全无 inet6
echo "测试 4: 所有服务 Off,完全无 inet6"
export SCENARIO=no_inet6
result=$(check_ipv6_status)
if [ "$result" = "off" ]; then
    echo "✓ 通过: 正确识别 IPv6 已关闭"
else
    echo "✗ 失败: 期望 off, 实际 $result"
    exit 1
fi
echo ""

# 测试 5: 无法列出网络服务
echo "测试 5: networksetup 失败,返回 unknown"
export SCENARIO=no_services
result=$(check_ipv6_status)
if echo "$result" | grep -q "^unknown:"; then
    echo "✓ 通过: 正确返回 unknown"
else
    echo "✗ 失败: 期望 unknown:, 实际 $result"
    exit 1
fi
echo ""

# 测试 6: get_ipv6_enabled_services NUL 分隔
echo "测试 6: get_ipv6_enabled_services 安全处理空格"
export SCENARIO=service_on_but_filtered
count=0
while IFS= read -r -d '' svc; do
    if [ "$svc" = "Wi-Fi 2" ]; then
        echo "✓ 通过: 服务名 'Wi-Fi 2' 完整保留(含空格)"
        count=$((count+1))
    fi
done < <(get_ipv6_enabled_services)
if [ "$count" -eq 0 ]; then
    echo "✗ 失败: 未找到 'Wi-Fi 2'"
    exit 1
fi
echo ""

echo "====== 所有测试通过 ======"
