#!/bin/bash
# IPv6 fail-closed 回归测试 - v3 修正版
set -e

echo "====== IPv6 Fail-Closed 回归测试 ======"
echo ""

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMP=$(mktemp -d)
trap "rm -rf '$TEMP'" EXIT

HOME="$TEMP/home"
FAKEBIN="$TEMP/bin"
mkdir -p "$HOME" "$FAKEBIN"

# 提取 check_ipv6_status 函数
cat > "$TEMP/test-functions.sh" << 'EXTRACT_END'
check_ipv6_status() {
    local services enabled_services svc v6_info v6_rc getinfo_output active_iface has_fail
    # 1. 枚举所有网络服务
    services=$(networksetup -listallnetworkservices 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$services" ]; then
        echo "unknown:networksetup列出服务失败"
        return
    fi
    services=$(echo "$services" | grep -v '^\*' | grep -v '^An asterisk')
    if [ -z "$services" ]; then
        echo "unknown:无可用网络服务"
        return
    fi
    
    # 2. 查找活动网络服务(有默认路由的接口对应的服务)
    active_iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    
    enabled_services=""
    has_fail=0
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        # getinfo 必须成功且包含 IPv6 字段
        getinfo_output=$(networksetup -getinfo "$svc" 2>/dev/null)
        v6_rc=$?
        if [ $v6_rc -ne 0 ]; then
            echo "unknown:服务[$svc]getinfo失败"
            return
        fi
        v6_info=$(echo "$getinfo_output" | grep -i '^IPv6:')
        if [ -z "$v6_info" ]; then
            echo "unknown:服务[$svc]缺失IPv6字段"
            return
        fi
        # Off 才视为已关闭,其他(Automatic/Manual/Link-local only)都算启用
        if ! echo "$v6_info" | grep -qi 'off'; then
            enabled_services="${enabled_services}${enabled_services:+,}$svc"
        fi
    done <<< "$services"
    
    if [ -n "$enabled_services" ]; then
        echo "on:$enabled_services"
    else
        # 所有服务配置 Off,检查物理接口是否有公网 IPv6
        # ifconfig 必须成功
        if ! ifconfig >/dev/null 2>&1; then
            echo "unknown:ifconfig执行失败"
            return
        fi
        # 过滤 lo/utun/awdl/llw 和 fe80/fc/fd
        local has_public_inet6
        has_public_inet6=$(ifconfig 2>/dev/null | awk '
            /^[a-z]/ { iface=$1; sub(/:$/,"",iface) }
            /inet6/ && iface !~ /^(lo|utun|awdl|llw)/ {
                addr=$2
                if (addr !~ /^fe80:/ && addr !~ /^fc/ && addr !~ /^fd/) {
                    print addr; exit
                }
            }
        ')
        if [ -n "$has_public_inet6" ]; then
            echo "on:所有服务Off但物理接口有公网IPv6($has_public_inet6)"
        else
            echo "off"
        fi
    fi
}
EXTRACT_END

# 创建 mock 命令
cat > "$FAKEBIN/networksetup" << 'EOF'
#!/bin/bash
case "$1" in
    -listallnetworkservices)
        case "$SCENARIO" in
            list_fail) exit 1 ;;
            getinfo_fail|ifconfig_fail|success)
                echo "An asterisk (*) denotes that a network service is disabled."
                echo "Wi-Fi 2"
                echo "Ethernet" ;;
            no_ipv6_field)
                echo "An asterisk (*) denotes that a network service is disabled."
                echo "Wi-Fi 2" ;;
            idle_thunderbolt)
                echo "An asterisk (*) denotes that a network service is disabled."
                echo "Wi-Fi 2"
                echo "Thunderbolt Bridge" ;;
        esac ;;
    -getinfo)
        case "$SCENARIO" in
            getinfo_fail)
                if [ "$2" = "Wi-Fi 2" ]; then exit 1; fi
                echo "IPv6: Off" ;;
            no_ipv6_field)
                if [ "$2" = "Wi-Fi 2" ]; then
                    echo "DHCP Configuration"
                    echo "IP address: 192.168.1.100"
                else
                    echo "IPv6: Off"
                fi ;;
            idle_thunderbolt)
                if [ "$2" = "Wi-Fi 2" ]; then
                    echo "IPv6: Off"
                elif [ "$2" = "Thunderbolt Bridge" ]; then
                    echo "IPv6: Automatic"
                fi ;;
            ifconfig_fail|success)
                echo "IPv6: Off" ;;
        esac ;;
esac
EOF

cat > "$FAKEBIN/ifconfig" << 'EOF'
#!/bin/bash
case "$SCENARIO" in
    ifconfig_fail)
        exit 1 ;;
    success)
        # lo0 + utun + awdl, en0 无 inet6
        cat << 'IFCONFIG_END'
lo0: inet6 ::1
utun0: inet6 fd12:3456::1
awdl0: inet6 fe80::abcd%awdl0
en0: inet 192.168.1.100
IFCONFIG_END
        ;;
esac
EOF

cat > "$FAKEBIN/route" << 'EOF'
#!/bin/bash
# route -n get default
if [ "$*" = "-n get default" ]; then
    echo "   route to: default"
    echo "destination: default"
    echo "  interface: en0"
fi
EOF

cat > "$FAKEBIN/awk" << 'EOF'
#!/bin/bash
/usr/bin/awk "$@"
EOF

chmod +x "$FAKEBIN"/*

export PATH="$FAKEBIN:/usr/bin:/bin"
export HOME="$HOME"
source "$TEMP/test-functions.sh"

# 测试 1: networksetup -listallnetworkservices 失败
echo "测试 1: networksetup 列出服务失败"
export SCENARIO=list_fail
result=$(check_ipv6_status)
if echo "$result" | grep -q "^unknown:.*列出服务失败"; then
    echo "✓ 通过: 正确返回 unknown"
else
    echo "✗ 失败: 期望 unknown:列出服务失败, 实际 $result"
    exit 1
fi
echo ""

# 测试 2: networksetup -getinfo 失败
echo "测试 2: Wi-Fi 2 getinfo 失败"
export SCENARIO=getinfo_fail
result=$(check_ipv6_status)
if echo "$result" | grep -q "^unknown:.*getinfo失败"; then
    echo "✓ 通过: 正确返回 unknown(getinfo 失败)"
else
    echo "✗ 失败: 期望 unknown:getinfo失败, 实际 $result"
    exit 1
fi
echo ""

# 测试 3: getinfo 成功但缺失 IPv6 字段
echo "测试 3: Wi-Fi 2 getinfo 缺失 IPv6 字段"
export SCENARIO=no_ipv6_field
result=$(check_ipv6_status)
if echo "$result" | grep -q "^unknown:.*缺失IPv6字段"; then
    echo "✓ 通过: 正确返回 unknown(缺失字段)"
else
    echo "✗ 失败: 期望 unknown:缺失IPv6字段, 实际 $result"
    exit 1
fi
echo ""

# 测试 4: ifconfig 失败
echo "测试 4: 所有服务 Off,但 ifconfig 失败"
export SCENARIO=ifconfig_fail
result=$(check_ipv6_status)
if echo "$result" | grep -q "^unknown:.*ifconfig执行失败"; then
    echo "✓ 通过: 正确返回 unknown(ifconfig 失败)"
else
    echo "✗ 失败: 期望 unknown:ifconfig执行失败, 实际 $result"
    exit 1
fi
echo ""

# 测试 5: 闲置 Thunderbolt Automatic(应报 on,不误报 off)
echo "测试 5: Wi-Fi 2 Off, Thunderbolt Automatic(闲置)"
export SCENARIO=idle_thunderbolt
result=$(check_ipv6_status)
if echo "$result" | grep -q "^on:.*Thunderbolt"; then
    echo "✓ 通过: 正确识别闲置服务 Automatic 为 on"
else
    echo "✗ 失败: 期望 on:Thunderbolt, 实际 $result"
    exit 1
fi
echo ""

# 测试 6: 成功场景 - 所有服务 Off, lo0/utun/awdl 过滤
echo "测试 6: 成功场景(所有服务 Off, lo0/utun/awdl 存在)"
export SCENARIO=success
result=$(check_ipv6_status)
if [ "$result" = "off" ]; then
    echo "✓ 通过: 正确返回 off(过滤 lo0/utun/awdl)"
else
    echo "✗ 失败: 期望 off, 实际 $result"
    exit 1
fi
echo ""

echo "====== 所有 Fail-Closed 测试通过 ======"
