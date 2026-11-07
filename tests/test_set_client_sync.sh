#!/bin/bash
# set-client --sync 功能测试 - 模拟环境
set -e

echo "====== set-client --sync 功能测试 ======"
echo ""

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMP=$(mktemp -d)
trap "rm -rf '$TEMP'" EXIT

HOME="$TEMP/home"
FAKEBIN="$TEMP/bin"
SYSDIR="$TEMP/system"
mkdir -p "$HOME/.local/bin" "$HOME/Library/Logs" "$FAKEBIN" "$SYSDIR/claude-switcher"

# 创建核心脚本副本
cp "$REPO/core/claude-switch.sh" "$HOME/.local/bin/"

# 创建假的保镖脚本(模拟 root 安装的)
cat > "$SYSDIR/claude-switcher/claude-bodyguard.sh" <<'EOF'
#!/bin/bash
LOG="$HOME/Library/Logs/claude-bodyguard.log"
MODE="clash-verge"
HOME_DIR="$HOME"
# ... 其余保镖逻辑 ...
EOF
chmod 755 "$SYSDIR/claude-switcher/claude-bodyguard.sh"

# 替换核心脚本中的系统路径
sed -i.bak "s|/Library/Application Support/claude-switcher|$SYSDIR/claude-switcher|g" \
    "$HOME/.local/bin/claude-switch.sh"

# 创建假命令
cat > "$FAKEBIN/launchctl" <<'EOF'
#!/bin/bash
# 模拟 launchctl 命令
case "$*" in
    "print system/local.claude-bodyguard")
        exit 0 ;;
    "bootout"*)
        echo "Unloaded bodyguard" >&2
        exit 0 ;;
    "bootstrap"*)
        echo "Loaded bodyguard" >&2
        exit 0 ;;
    *)
        exit 0 ;;
esac
EOF

cat > "$FAKEBIN/sudo" <<'EOF'
#!/bin/bash
# 模拟 sudo - 直接执行命令(测试环境)
shift  # 跳过 bash
shift  # 跳过 -c
eval "$@"
EOF

chmod +x "$FAKEBIN"/*

export HOME="$HOME"
export PATH="$FAKEBIN:/usr/bin:/bin"
export CLAUDE_SWITCHER_CORE="$HOME/.local/bin/claude-switch.sh"

# 测试 1: 基本 set-client(不同步)
echo "测试 1: 基本 set-client shadowrocket(不带 --sync)"
result=$("$HOME/.local/bin/claude-switch.sh" set-client shadowrocket 2>&1)
if echo "$result" | grep -q "OK:代理客户端已设为 shadowrocket"; then
    echo "✓ 核心脚本更新成功"
else
    echo "✗ 失败: 核心脚本未更新"
    echo "$result"
    exit 1
fi

if echo "$result" | grep -q "WARN:保镖"; then
    echo "✓ 警告保镖不一致(预期)"
else
    echo "✗ 失败: 应该警告保镖不一致"
    echo "$result"
    exit 1
fi

# 验证保镖脚本未改变
guard_mode=$(grep '^MODE=' "$SYSDIR/claude-switcher/claude-bodyguard.sh" | cut -d'"' -f2)
if [ "$guard_mode" = "clash-verge" ]; then
    echo "✓ 保镖脚本未改变(预期)"
else
    echo "✗ 失败: 保镖脚本不应改变,实际为 $guard_mode"
    exit 1
fi
echo ""

# 测试 2: set-client --sync(同步保镖)
echo "测试 2: set-client shadowrocket --sync"
result=$("$HOME/.local/bin/claude-switch.sh" set-client shadowrocket --sync 2>&1)
if echo "$result" | grep -q "OK:保镖守护脚本已同步并重启"; then
    echo "✓ 保镖同步成功"
else
    echo "✗ 失败: 保镖同步失败"
    echo "$result"
    exit 1
fi

# 验证保镖脚本已更新
guard_mode=$(grep '^MODE=' "$SYSDIR/claude-switcher/claude-bodyguard.sh" | cut -d'"' -f2)
if [ "$guard_mode" = "shadowrocket" ]; then
    echo "✓ 保镖脚本已更新为 shadowrocket"
else
    echo "✗ 失败: 保镖脚本应为 shadowrocket,实际为 $guard_mode"
    exit 1
fi
echo ""

# 测试 3: 再次 set-client 相同模式(应无警告)
echo "测试 3: 再次 set-client shadowrocket(模式已一致)"
result=$("$HOME/.local/bin/claude-switch.sh" set-client shadowrocket 2>&1)
if echo "$result" | grep -q "OK:保镖已同步"; then
    echo "✓ 检测到保镖已同步,无警告"
else
    echo "✗ 失败: 应该检测到保镖已同步"
    echo "$result"
    exit 1
fi
echo ""

# 测试 4: 切换到另一个模式并同步
echo "测试 4: 切换到 flclash --sync"
result=$("$HOME/.local/bin/claude-switch.sh" set-client flclash --sync 2>&1)
if echo "$result" | grep -q "OK:保镖守护脚本已同步并重启"; then
    echo "✓ 切换到 flclash 并同步成功"
else
    echo "✗ 失败"
    echo "$result"
    exit 1
fi

guard_mode=$(grep '^MODE=' "$SYSDIR/claude-switcher/claude-bodyguard.sh" | cut -d'"' -f2)
if [ "$guard_mode" = "flclash" ]; then
    echo "✓ 保镖脚本已更新为 flclash"
else
    echo "✗ 失败: 保镖脚本应为 flclash,实际为 $guard_mode"
    exit 1
fi
echo ""

# 测试 5: 验证保镖脚本其他部分未被破坏
echo "测试 5: 验证保镖脚本内容完整性"
if grep -q 'LOG="\$HOME/Library/Logs/claude-bodyguard.log"' "$SYSDIR/claude-switcher/claude-bodyguard.sh"; then
    echo "✓ 保镖脚本其他配置未被破坏"
else
    echo "✗ 失败: 保镖脚本内容被破坏"
    exit 1
fi
echo ""

echo "====== 所有测试通过 ======"
