# Shadowrocket 修复 - 快速安装指南

## 问题症状
- ✗ 安装时明明运行 Shadowrocket，却识别为 Clash Verge
- ✗ `checkdetail` 显示 `保镖=fail:客户端不一致`
- ✗ Claude 被错误关闭(因为保镖检测不到 verge-mihomo 进程)

## 最快修复方法

### 方法 1: 环境变量 + 重装(推荐)
```bash
# 1. 停止现有服务
pkill -x ClaudeSwitcher
sudo launchctl bootout system/local.claude-bodyguard
sudo launchctl bootout system/local.tz-watchdog

# 2. 强制指定客户端
export CLAUDE_PROXY_CLIENT=shadowrocket

# 3. 重新运行安装器
cd ~/Downloads/claude-switcher  # 您的安装包路径
open installer/安装.command

# 完成！无需手动选择，自动识别为 shadowrocket
```

### 方法 2: 更新核心 + 同步保镖
```bash
# 1. 替换核心脚本
cp ~/Downloads/claude-switcher/core/claude-switch.sh ~/.local/bin/
chmod +x ~/.local/bin/claude-switch.sh

# 2. 切换并同步(需输入密码)
~/.local/bin/claude-switch.sh set-client shadowrocket --sync

# 3. 验证
~/.local/bin/claude-switch.sh checkdetail | grep "保镖"
# 应显示: 保镖=ok:...
```

## 验证成功标志
```bash
~/.local/bin/claude-switch.sh checkdetail
```

**全部通过示例**:
```
代理内核=ok:Shadowrocket 已连接
TUN网卡=ok
出口IP=ok:198.51.100.1/US
...
保镖=ok:待命                          ← 这里不再显示 "客户端不一致"
...
```

## 支持的客户端
- `shadowrocket` - Shadowrocket (VPN 配置)
- `clash-verge` - Clash Verge Rev
- `flclash` - FlClash
- `sing-box` - sing-box
- `clashx` - ClashX
- `surge` - Surge
- `auto` - 自动检测(任一可用)

## 常见问题

### Q: 还是提示 "客户端不一致" ?
```bash
# 检查核心脚本
grep '^PROXY_MODE=' ~/.local/bin/claude-switch.sh

# 检查保镖脚本
sudo grep '^MODE=' "/Library/Application Support/claude-switcher/claude-bodyguard.sh"

# 两者应该相同！如果不同，运行:
~/.local/bin/claude-switch.sh set-client shadowrocket --sync
```

### Q: 我有多个代理客户端怎么办?
安装器会自动提示您选择。或者:
```bash
# 明确指定
export CLAUDE_PROXY_CLIENT=shadowrocket
# 然后运行安装器
```

### Q: 如何回到旧版本?
```bash
# 从 https://github.com/EVA113x/claude-switcher 下载 v1.9.0
# 重新运行其安装器即可
```

---

**需要详细文档?** 查看 `DEPLOYMENT_GUIDE.md`
