#!/bin/bash
# IPv6 网络服务检测回归测试
set -e

echo "====== IPv6 网络服务检测测试 ======"
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
    # 先检查物理接口(en0 等)是否有 inet6 地址
    if ifconfig 2>/dev/null | grep -q 'inet6 '; then
        # 有 IPv6 地址,检查哪些网络服务启用了 IPv6
        local services enabled_services
        services=$(networksetup -listallnetworkservices 2>/dev/null | grep -v '^\*' | grep -v '^An asterisk')
        if [ -z "$services" ]; then
            echo "on:物理接口有 inet6,但无法列出网络服务"
            return
        fi
        enabled_services=""
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            v6_info=$(networksetup -getinfo "$svc" 2>/dev/null | grep -i '^IPv6:')
            if [ -n "$v6_info" ] && ! echo "$v6_info" | grep -qi 'off'; then
                enabled_services="${enabled_services}${enabled_services:+,}$svc"
            fi
        done <<< "$services"
        if [ -n "$enabled_services" ]; then
            echo "on:$enabled_services"
        else
            echo "on:物理接口有 inet6,但网络服务显示 Off(UI 可能不同步)"
        fi
    else
        # 无 inet6 地址,认为已关闭
        echo "off"
    fi
}

get_ipv6_enabled_services() {
    local services svc v6_info result
    services=$(networksetup -listallnetworkservices 2>/dev/null | grep -v '^\*' | grep -v '^An asterisk')
    result=""
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        v6_info=$(networksetup -getinfo "$svc" 2>/dev/null | grep -i '^IPv6:')
        if [ -n "$v6_info" ] && ! echo "$v6_info" | grep -qi 'off'; then
            # 服务名可能含空格,用换行分隔
            result="${result}${svc}"$'\n'
        fi
    done <<< "$services"
    echo "$result"
}
EXTRACT_END

# 创建 mock 命令
cat > "$FAKEBIN/ifconfig" << 'EOF'
#!/bin/bash
case "$SCENARIO" in
    ipv6_enabled|multiple_services)
        echo "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500"
        echo "	inet 192.168.1.100 netmask 0xffffff00 broadcast 192.168.1.255"
        echo "	inet6 fe80::1234:5678:90ab:cdef%en0 prefixlen 64 secured scopeid 0x6"
        echo "	inet6 2001:db8::1 prefixlen 64" ;;
    ipv6_disabled|single_service)
        echo "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500"
        echo "	inet 192.168.1.100 netmask 0xffffff00 broadcast 192.168.1.255" ;;
    *)
        exit 1 ;;
esac
EOF

cat > "$FAKEBIN/networksetup" << 'EOF'
#!/bin/bash
case "$1" in
    -listallnetworkservices)
        case "$SCENARIO" in
            ipv6_enabled|single_service)
                echo "An asterisk (*) denotes that a network service is disabled."
                echo "Wi-Fi 2"
                echo "Ethernet" ;;
            multiple_services)
                echo "An asterisk (*) denotes that a network service is disabled."
                echo "Wi-Fi 2"
                echo "Ethernet"
                echo "Thunderbolt Bridge" ;;
            *)
                echo "Wi-Fi" ;;
        esac ;;
    -getinfo)
        svc="$2"
        case "$SCENARIO:$svc" in
            ipv6_enabled:"Wi-Fi 2")
                echo "DHCP Configuration"
                echo "IP address: 192.168.1.100"
                echo "IPv6: Automatic" ;;
            ipv6_enabled:Ethernet)
                echo "Manual Configuration"
                echo "IPv6: Off" ;;
            single_service:"Wi-Fi 2")
                echo "IPv6: Off" ;;
            multiple_services:"Wi-Fi 2")
                echo "IPv6: Automatic" ;;
            multiple_services:Ethernet)
                echo "IPv6: Off" ;;
            multiple_services:"Thunderbolt Bridge")
                echo "IPv6: Link-local only" ;;
            *)
                echo "IPv6: Off" ;;
        esac ;;
esac
EOF

chmod +x "$FAKEBIN"/*

export PATH="$FAKEBIN:/usr/bin:/bin"
export HOME="$HOME"
source "$TEMP/test-functions.sh"

# 测试 1: IPv6 已禁用
echo "测试 1: IPv6 已禁用(无 inet6 地址)"
export SCENARIO=ipv6_disabled
result=$(check_ipv6_status)
if [ "$result" = "off" ]; then
    echo "✓ 通过: 正确识别 IPv6 已关闭"
else
    echo "✗ 失败: 期望 off, 实际 $result"
    exit 1
fi
echo ""

# 测试 2: IPv6 启用,单个服务
echo "测试 2: IPv6 启用,网络服务 'Wi-Fi 2' 启用 IPv6"
export SCENARIO=ipv6_enabled
result=$(check_ipv6_status)
if echo "$result" | grep -q "^on:.*Wi-Fi 2"; then
    echo "✓ 通过: 正确识别 IPv6 启用,服务名包含空格"
else
    echo "✗ 失败: 期望包含 'Wi-Fi 2', 实际 $result"
    exit 1
fi
echo ""

# 测试 3: 多个服务,部分启用 IPv6
echo "测试 3: 多个网络服务,仅部分启用 IPv6"
export SCENARIO=multiple_services
result=$(check_ipv6_status)
if echo "$result" | grep -q "^on:"; then
    echo "✓ 通过: 识别到 IPv6 启用"
    # 验证不包含 Ethernet(已关闭)
    if echo "$result" | grep -q "Ethernet"; then
        echo "✗ 失败: 不应包含已关闭 IPv6 的服务"
        exit 1
    fi
    echo "  详情: $result"
else
    echo "✗ 失败: 应识别为 on, 实际 $result"
    exit 1
fi
echo ""

# 测试 4: get_ipv6_enabled_services
echo "测试 4: 获取启用 IPv6 的服务列表"
export SCENARIO=multiple_services
services=$(get_ipv6_enabled_services)
if echo "$services" | grep -q "Wi-Fi 2"; then
    echo "✓ 通过: 服务列表包含 'Wi-Fi 2'"
else
    echo "✗ 失败: 服务列表应包含 'Wi-Fi 2'"
    exit 1
fi
if echo "$services" | grep -q "Thunderbolt Bridge"; then
    echo "✓ 通过: 服务列表包含 'Thunderbolt Bridge'"
else
    echo "✗ 失败: 服务列表应包含 'Thunderbolt Bridge'"
    exit 1
fi
if echo "$services" | grep -q "Ethernet"; then
    echo "✗ 失败: 服务列表不应包含已关闭 IPv6 的 Ethernet"
    exit 1
fi
echo ""

echo "====== 所有测试通过 ======"
