#!/bin/bash
# Bidirectional Test: check_ipv6_status() 正负场景覆盖
# Bash 3.2 Compatible

set -euo pipefail

# 提取待测函数(仅函数定义,不执行脚本逻辑)
eval "$(sed -n '/^check_ipv6_status()/,/^}/p' core/claude-switch.sh)"

echo "=== IPv6 Bidirectional Test ==="
echo

# Test 1: Active service Auto without inet6 -> on
echo "Test 1: Active 'Wi-Fi 2' Auto, no inet6 -> on:Wi-Fi 2"
networksetup() {
    if [ "$1" = "-listnetworkserviceorder" ]; then
        cat <<'EOMOCK'
(1) Wi-Fi 2
(Hardware Port: Wi-Fi, Device: en0)
(2) Thunderbolt Bridge
(Hardware Port: Thunderbolt Bridge, Device: bridge0)
EOMOCK
    elif [ "$1" = "-getinfo" ] && [ "$2" = "Wi-Fi 2" ]; then
        cat <<'EOMOCK'
DHCP Configuration
IP address: 192.168.1.100
Subnet mask: 255.255.255.0
Router: 192.168.1.1
IPv6: Automatic
EOMOCK
    else
        command networksetup "$@"
    fi
}
ifconfig() {
    if [ $# -eq 0 ]; then
        echo "lo0: flags=..."
        return 0
    elif [ "$1" = "en0" ]; then
        cat <<'EOMOCK'
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.168.1.100 netmask 0xffffff00 broadcast 192.168.1.255
EOMOCK
    else
        command ifconfig "$@" 2>/dev/null || true
    fi
}
export -f networksetup ifconfig
result=$(check_ipv6_status)
rc=$?
echo "Result: $result (rc=$rc)"
if [[ "$result" == on:*"Wi-Fi 2"* ]]; then
    echo "✓ PASS"
else
    echo "✗ FAIL: Expected 'on:Wi-Fi 2', got '$result'"
    exit 1
fi
echo

# Test 2: Active service Off without inet6 -> off
echo "Test 2: Active 'Wi-Fi' Off, no inet6 -> off"
networksetup() {
    if [ "$1" = "-listnetworkserviceorder" ]; then
        cat <<'EOMOCK'
(1) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)
EOMOCK
    elif [ "$1" = "-getinfo" ] && [ "$2" = "Wi-Fi" ]; then
        cat <<'EOMOCK'
DHCP Configuration
IP address: 192.168.1.100
IPv6: Off
EOMOCK
    else
        command networksetup "$@"
    fi
}
ifconfig() {
    if [ $# -eq 0 ]; then
        echo "lo0: ..."
        return 0
    elif [ "$1" = "en0" ]; then
        cat <<'EOMOCK'
en0: flags=8863<UP,BROADCAST,SMART,RUNNING> mtu 1500
	inet 192.168.1.100 netmask 0xffffff00
EOMOCK
    else
        command ifconfig "$@" 2>/dev/null || true
    fi
}
export -f networksetup ifconfig
result=$(check_ipv6_status)
echo "Result: $result"
if [ "$result" = "off" ]; then
    echo "✓ PASS"
else
    echo "✗ FAIL: Expected 'off', got '$result'"
    exit 1
fi
echo

# Test 3: Active Off but has public inet6 -> on (安全阻断)
echo "Test 3: Active Off but inet6 2001:db8::1 -> on (leak block)"
networksetup() {
    if [ "$1" = "-listnetworkserviceorder" ]; then
        cat <<'EOMOCK'
(1) Ethernet
(Hardware Port: Ethernet, Device: en1)
EOMOCK
    elif [ "$1" = "-getinfo" ] && [ "$2" = "Ethernet" ]; then
        cat <<'EOMOCK'
IP address: 10.0.0.5
IPv6: Off
EOMOCK
    else
        command networksetup "$@"
    fi
}
ifconfig() {
    if [ $# -eq 0 ]; then
        return 0
    elif [ "$1" = "en1" ]; then
        cat <<'EOMOCK'
en1: flags=8863<UP,RUNNING> mtu 1500
	inet 10.0.0.5
	inet6 2001:db8::1 prefixlen 64
EOMOCK
    else
        command ifconfig "$@" 2>/dev/null || true
    fi
}
export -f networksetup ifconfig
result=$(check_ipv6_status)
echo "Result: $result"
if [[ "$result" == on:* ]]; then
    echo "✓ PASS"
else
    echo "✗ FAIL: Expected 'on:...' for leak, got '$result'"
    exit 1
fi
echo

# Test 4: Inactive service Auto -> excluded, active Off -> off
echo "Test 4: Inactive 'Thunderbolt Bridge' Auto + Active 'Wi-Fi' Off -> off"
networksetup() {
    if [ "$1" = "-listnetworkserviceorder" ]; then
        cat <<'EOMOCK'
(1) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)
(2) Thunderbolt Bridge
(Hardware Port: Thunderbolt Bridge, Device: bridge0)
EOMOCK
    elif [ "$1" = "-getinfo" ]; then
        if [ "$2" = "Wi-Fi" ]; then
            echo "IP address: 192.168.1.100"
            echo "IPv6: Off"
        elif [ "$2" = "Thunderbolt Bridge" ]; then
            echo "IPv6: Automatic"
        fi
    else
        command networksetup "$@"
    fi
}
ifconfig() {
    if [ $# -eq 0 ]; then
        return 0
    elif [ "$1" = "en0" ]; then
        echo "inet 192.168.1.100"
    elif [ "$1" = "bridge0" ]; then
        echo "bridge0: flags=8822<BROADCAST,SMART> mtu 1500"
        # 无 inet,不活动
    else
        command ifconfig "$@" 2>/dev/null || true
    fi
}
export -f networksetup ifconfig
result=$(check_ipv6_status)
echo "Result: $result"
if [ "$result" = "off" ]; then
    echo "✓ PASS"
else
    echo "✗ FAIL: Expected 'off', got '$result'"
    exit 1
fi
echo

# Test 5: getinfo 失败 -> unknown
echo "Test 5: getinfo fails -> unknown"
networksetup() {
    if [ "$1" = "-listnetworkserviceorder" ]; then
        cat <<'EOMOCK'
(1) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)
EOMOCK
    elif [ "$1" = "-getinfo" ]; then
        return 1
    else
        command networksetup "$@"
    fi
}
ifconfig() {
    if [ $# -eq 0 ]; then
        return 0
    elif [ "$1" = "en0" ]; then
        echo "inet 192.168.1.100"
    else
        command ifconfig "$@" 2>/dev/null || true
    fi
}
export -f networksetup ifconfig
result=$(check_ipv6_status)
echo "Result: $result"
if [[ "$result" == unknown:* ]]; then
    echo "✓ PASS"
else
    echo "✗ FAIL: Expected 'unknown:...', got '$result'"
    exit 1
fi
echo

# Test 6: Multiple active, one Auto -> on
echo "Test 6: 'Wi-Fi' Off + 'Ethernet' Auto -> on:Ethernet"
networksetup() {
    if [ "$1" = "-listnetworkserviceorder" ]; then
        cat <<'EOMOCK'
(1) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)
(2) Ethernet
(Hardware Port: Ethernet, Device: en1)
EOMOCK
    elif [ "$1" = "-getinfo" ]; then
        if [ "$2" = "Wi-Fi" ]; then
            echo "IP address: 192.168.1.100"
            echo "IPv6: Off"
        elif [ "$2" = "Ethernet" ]; then
            echo "IP address: 10.0.0.5"
            echo "IPv6: Automatic"
        fi
    else
        command networksetup "$@"
    fi
}
ifconfig() {
    if [ $# -eq 0 ]; then
        return 0
    elif [ "$1" = "en0" ]; then
        echo "inet 192.168.1.100"
    elif [ "$1" = "en1" ]; then
        echo "inet 10.0.0.5"
    else
        command ifconfig "$@" 2>/dev/null || true
    fi
}
export -f networksetup ifconfig
result=$(check_ipv6_status)
echo "Result: $result"
if [[ "$result" == on:*"Ethernet"* ]]; then
    echo "✓ PASS"
else
    echo "✗ FAIL: Expected 'on:...Ethernet', got '$result'"
    exit 1
fi
echo

# Test 7: Service name with space (quoted correctly)
echo "Test 7: Service name 'USB 10/100/1000 LAN' with space"
networksetup() {
    if [ "$1" = "-listnetworkserviceorder" ]; then
        cat <<'EOMOCK'
(1) USB 10/100/1000 LAN
(Hardware Port: USB Ethernet, Device: en5)
EOMOCK
    elif [ "$1" = "-getinfo" ] && [ "$2" = "USB 10/100/1000 LAN" ]; then
        echo "IP address: 172.16.0.10"
        echo "IPv6: Automatic"
    else
        command networksetup "$@"
    fi
}
ifconfig() {
    if [ $# -eq 0 ]; then
        return 0
    elif [ "$1" = "en5" ]; then
        echo "inet 172.16.0.10"
    else
        command ifconfig "$@" 2>/dev/null || true
    fi
}
export -f networksetup ifconfig
result=$(check_ipv6_status)
echo "Result: $result"
if [[ "$result" == on:*"USB 10/100/1000 LAN"* ]]; then
    echo "✓ PASS"
else
    echo "✗ FAIL: Expected 'on:USB 10/100/1000 LAN', got '$result'"
    exit 1
fi
echo

echo "=== All Tests Passed ==="
