#!/bin/bash
# 安装器 Shadowrocket 优先级测试 - 模拟环境测试
set -e

echo "====== 安装器客户端检测优先级测试 ======"
echo ""

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMP=$(mktemp -d)
trap "rm -rf '$TEMP'" EXIT

HOME="$TEMP/home"
FAKEBIN="$TEMP/bin"
mkdir -p "$HOME" "$FAKEBIN"

# 创建假命令
cat > "$FAKEBIN/python3" <<'EOF'
#!/bin/bash
echo "Python 3.9.0"
EOF

cat > "$FAKEBIN/swiftc" <<'EOF'
#!/bin/bash
echo "Swift version 5.9"
EOF

cat > "$FAKEBIN/pgrep" <<'EOF'
#!/bin/bash
# 根据测试场景返回不同结果
case "$SCENARIO" in
    shadowrocket-running)
        exit 1 ;;  # 无 Clash 进程
    clash-running)
        case "$*" in *verge-mihomo*) exit 0 ;; *) exit 1 ;; esac ;;
    both-running)
        case "$*" in *verge-mihomo*|*Shadowrocket*) exit 0 ;; *) exit 1 ;; esac ;;
    *)
        exit 1 ;;
esac
EOF

cat > "$FAKEBIN/scutil" <<'EOF'
#!/bin/bash
case "$SCENARIO" in
    shadowrocket-running|shadowrocket-config|both-running)
        echo "  (Connected)      com.liguangming.Shadowrocket" ;;
    *)
        exit 1 ;;
esac
EOF

cat > "$FAKEBIN/launchctl" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$FAKEBIN/curl" <<'EOF'
#!/bin/bash
case "$*" in
    *ipinfo.io*)
        echo '{"country":"US","timezone":"America/New_York"}' ;;
    *cdn-cgi/trace*)
        echo "ip=198.51.100.1"
        echo "loc=US" ;;
esac
EOF

chmod +x "$FAKEBIN"/*

# 创建 Claude.app
mkdir -p "$HOME/Applications/Claude.app/Contents/MacOS"
touch "$HOME/Applications/Claude.app/Contents/MacOS/Claude"

# 创建测试用安装器(只运行检测部分)
create_test_installer() {
    cat "$REPO/installer/安装.command" | awk '
        /^echo "✓ 代理客户端: \$MODE"$/ {
            print $0
            print "echo \"DETECTED_MODE=$MODE\""
            print "exit 0"
            exit
        }
        { print }
    ' > "$TEMP/test-installer.sh"
}

run_detection() {
    local scenario="$1"
    export HOME="$HOME"
    export PATH="$FAKEBIN:/usr/bin:/bin"
    export DRYRUN=1
    export SCENARIO="$scenario"
    
    create_test_installer
    result=$(bash "$TEMP/test-installer.sh" 2>&1 | grep "DETECTED_MODE=" | cut -d= -f2)
    echo "$result"
}

# 测试 1: Shadowrocket 运行中 + Clash 配置目录存在
echo "测试 1: Shadowrocket 运行中 + Clash Verge 配置目录存在"
mkdir -p "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
result=$(run_detection "shadowrocket-running")
if [ "$result" = "shadowrocket" ]; then
    echo "✓ 通过: 运行中的 Shadowrocket 优先于 Clash Verge 配置目录"
else
    echo "✗ 失败: 期望 shadowrocket, 实际 $result"
    exit 1
fi
echo ""

# 测试 2: 只有 Clash 配置目录(无进程运行)
echo "测试 2: 只有 Clash Verge 配置目录(无进程运行)"
rm -rf "$HOME/Library/Application Support"
mkdir -p "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
result=$(run_detection "none-running")
if [ "$result" = "clash-verge" ]; then
    echo "✓ 通过: 配置目录被识别"
else
    echo "✗ 失败: 期望 clash-verge, 实际 $result"
    exit 1
fi
echo ""

# 测试 3: 环境变量强制指定
echo "测试 3: CLAUDE_PROXY_CLIENT 环境变量强制指定"
mkdir -p "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
export CLAUDE_PROXY_CLIENT="shadowrocket"
result=$(run_detection "clash-running")
if [ "$result" = "shadowrocket" ]; then
    echo "✓ 通过: 环境变量强制指定生效"
else
    echo "✗ 失败: 期望 shadowrocket, 实际 $result"
    exit 1
fi
unset CLAUDE_PROXY_CLIENT
echo ""

# 测试 4: Clash 运行中
echo "测试 4: Clash Verge 运行中(无 Shadowrocket)"
rm -rf "$HOME/Library/Application Support"
result=$(run_detection "clash-running")
if [ "$result" = "clash-verge" ]; then
    echo "✓ 通过: 运行中的 Clash Verge 被检测"
else
    echo "✗ 失败: 期望 clash-verge, 实际 $result"
    exit 1
fi
echo ""

# 测试 5: 只有 Shadowrocket 配置(未运行)
echo "测试 5: 只有 Shadowrocket 配置(未运行)"
result=$(run_detection "shadowrocket-config")
if [ "$result" = "shadowrocket" ]; then
    echo "✓ 通过: Shadowrocket 配置被识别(scutil 可见但未连接)"
else
    echo "✗ 失败: 期望 shadowrocket, 实际 $result"
    exit 1
fi
echo ""

echo "====== 所有测试通过 ======"
