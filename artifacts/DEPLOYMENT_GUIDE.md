# Shadowrocket 安装优先级与保镖同步修复 - 部署指南

## 问题概述

### 根本原因
1. **安装器检测逻辑缺陷**:
   - 旧版本优先检查配置目录存在性，而非实际运行状态
   - 即使用户只运行 Shadowrocket，只要旧 Clash Verge 配置目录存在就误识别为 `clash-verge`
   - 用户场景: 曾安装试用 Clash Verge 后卸载，但配置目录 `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev` 残留

2. **保镖同步机制缺失**:
   - 核心脚本 `PROXY_MODE` 在 `~/.local/bin/claude-switch.sh` (用户可写)
   - 保镖脚本 `MODE` 在 `/Library/Application Support/claude-switcher/claude-bodyguard.sh` (root 拥有)
   - `set-client` 命令只更新用户脚本，无法同步 root 保镖
   - 导致保镖按错误客户端检测，可能误杀或漏杀 Claude 进程

### 影响
- 安装时识别为 clash-verge，实际运行 Shadowrocket
- 保镖检测 `verge-mihomo` 进程(不存在) → 误判代理离线 → 错误关闭 Claude
- 用户虽能手动 `set-client shadowrocket` 但保镖不同步，`checkdetail` 持续报错

## 修复方案

### 1. 安装器改进 (`installer/安装.command`)

#### 新增三级检测优先级
```bash
优先级 1: 环境变量 CLAUDE_PROXY_CLIENT 强制指定
优先级 2: 检测运行中的代理进程(pgrep/scutil)
优先级 3: 检测配置目录存在
优先级 4: 手动选择
```

#### 具体逻辑
- **Shadowrocket**: `scutil --nc list | grep 'com.liguangming.Shadowrocket' | grep '(Connected)'`
- **Clash Verge**: `pgrep -f 'verge-mihomo'`
- **FlClash**: `pgrep -f 'FlClashCore' || pgrep -x 'FlClash'`
- 其他客户端类似

#### 多客户端场景
- 检测到多个运行中客户端时，明确列表提示用户选择
- 避免静默选错专线

### 2. set-client 增强 (`core/claude-switch.sh`)

#### 新增 --sync 选项
```bash
# 只更新核心脚本(旧行为)
claude-switch.sh set-client shadowrocket

# 同时同步 root 保镖(新功能)
claude-switch.sh set-client shadowrocket --sync
```

#### 实现细节
- 读取现有保镖脚本，只替换 `MODE` 行
- 通过 `sudo` 执行: 拷贝 → chown root:wheel → 重启 launchd
- 失败自动回滚，保持现有配置
- 不带 `--sync` 时明确提示同步方法

### 3. 测试覆盖

#### 新增测试
1. `tests/test_installer_shadowrocket_priority.sh`: 
   - 模拟各种配置目录与进程运行组合
   - 验证优先级逻辑正确
   
2. `tests/test_set_client_sync.sh`:
   - 验证 `--sync` 同步保镖功能
   - 确保不破坏保镖其他配置

3. `tests/test_installer_client_detection.py`:
   - Python unittest 框架覆盖
   - 边界条件测试

#### 运行测试
```bash
# 在 Linux 开发环境(模拟测试)
cd /workspace
bash tests/test_installer_shadowrocket_priority.sh
bash tests/test_set_client_sync.sh  # 需 macOS 或适配环境

# Python 单元测试(需 macOS)
python3 -m unittest tests.test_installer_client_detection
python3 -m unittest tests.test_set_client
```

## 部署说明

### 前置条件
- macOS (Apple Silicon 或 Intel)
- 已有 v1.9.0 或更早版本安装
- 用户有管理员权限(安装/同步保镖时需要 sudo)

### 部署选项 A: 重新运行安装器(推荐)

#### 步骤
1. **备份现有账号数据**(可选但推荐):
   ```bash
   cp -R ~/.claude-switcher ~/.claude-switcher.backup
   ```

2. **清理旧安装**(可选):
   ```bash
   # 退出 App 和保镖
   pkill -x ClaudeSwitcher
   sudo launchctl bootout system/local.claude-bodyguard
   sudo launchctl bootout system/local.tz-watchdog
   
   # 删除旧核心和守护脚本
   rm -f ~/.local/bin/claude-switch.sh
   sudo rm -rf "/Library/Application Support/claude-switcher"
   ```

3. **解压部署包**:
   ```bash
   cd ~/Downloads
   tar -xzf shadowrocket-fix-deployment.tar.gz
   cd claude-switcher  # 如果解压到子目录
   ```

4. **设置环境变量强制指定客户端**(推荐):
   ```bash
   export CLAUDE_PROXY_CLIENT=shadowrocket
   # 或其他: flclash, clash-verge, sing-box, clashx, surge, auto
   ```

5. **运行安装器**:
   ```bash
   chmod +x installer/安装.command
   open installer/安装.command
   # 或终端: bash installer/安装.command
   ```

6. **验证安装**:
   ```bash
   ~/.local/bin/claude-switch.sh checkdetail
   ```
   
   **预期输出**:
   - `代理内核=ok:Shadowrocket 已连接` (或对应客户端)
   - `保镖=ok:...` (不应有 "客户端不一致" 错误)

### 部署选项 B: 使用 set-client --sync

#### 适用场景
- 已安装 v1.9.0，只需修正客户端配置
- 不想重新运行完整安装器

#### 步骤
1. **替换核心脚本**:
   ```bash
   # 备份旧版本
   cp ~/.local/bin/claude-switch.sh ~/.local/bin/claude-switch.sh.v1.9.0
   
   # 解压新版本
   tar -xzf shadowrocket-fix-deployment.tar.gz
   cp claude-switcher/core/claude-switch.sh ~/.local/bin/
   chmod +x ~/.local/bin/claude-switch.sh
   ```

2. **校验安装**:
   ```bash
   grep -A 5 "^PROXY_MODE=" ~/.local/bin/claude-switch.sh
   # 应显示当前配置(可能仍是旧的 clash-verge)
   ```

3. **切换并同步客户端**:
   ```bash
   ~/.local/bin/claude-switch.sh set-client shadowrocket --sync
   ```
   
   **提示输入密码**: 这是同步 root 保镖脚本必须的
   
   **预期输出**:
   ```
   OK:代理客户端已设为 shadowrocket
   正在同步保镖守护脚本(需要管理员权限)...
   OK:保镖守护脚本已同步并重启
   ```

4. **验证**:
   ```bash
   ~/.local/bin/claude-switch.sh checkdetail | grep "保镖"
   # 应显示: 保镖=ok:... (不应有 "客户端不一致")
   ```

### 部署选项 C: 手动同步(仅调试用)

```bash
# 1. 更新核心脚本 PROXY_MODE
sed -i '' 's/^PROXY_MODE=".*"/PROXY_MODE="shadowrocket"/' ~/.local/bin/claude-switch.sh

# 2. 更新保镖脚本 MODE
sudo sed -i '' 's/^MODE=".*"/MODE="shadowrocket"/' \
  "/Library/Application Support/claude-switcher/claude-bodyguard.sh"

# 3. 重启保镖
sudo launchctl bootout system/local.claude-bodyguard
sudo launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist
```

## 验证清单

### 安装后必检项
- [ ] `~/.local/bin/claude-switch.sh checkdetail` 无 FAIL
- [ ] `grep '^PROXY_MODE=' ~/.local/bin/claude-switch.sh` 显示正确客户端
- [ ] `sudo grep '^MODE=' "/Library/Application Support/claude-switcher/claude-bodyguard.sh"` 与核心一致
- [ ] 保镖服务运行: `launchctl print system/local.claude-bodyguard`
- [ ] 双击桌面「Claude切换器」App 能正常打开

### 功能回归测试
1. **启动 Claude**: 确认不被保镖误杀
2. **关闭代理客户端**: 保镖应 10 秒内自动关闭 Claude
3. **切换账号**: `claude-switch.sh switch B` 正常工作
4. **环境变量覆盖**: 
   ```bash
   export CLAUDE_PROXY_CLIENT=auto
   # 重新运行安装器应识别为 auto
   ```

## 回滚路径

### 如果新版本出现问题

#### 回滚到 v1.9.0
```bash
# 1. 恢复备份的核心脚本
cp ~/.local/bin/claude-switch.sh.v1.9.0 ~/.local/bin/claude-switch.sh

# 2. 恢复账号数据(如有备份)
rm -rf ~/.claude-switcher
cp -R ~/.claude-switcher.backup ~/.claude-switcher

# 3. 重新运行 v1.9.0 安装器
# 从 https://github.com/EVA113x/claude-switcher 下载 v1.9.0
```

#### 保留新版本但恢复旧行为
```bash
# 不使用 --sync，手动运行安装器同步保镖(旧流程)
claude-switch.sh set-client shadowrocket
# (不带 --sync，只警告不同步)

# 然后重新运行完整安装器
open installer/安装.command
```

## 注意事项

### 安全边界
1. **不要跳过安全检查**: 修复不改变硬性安全项行为
2. **保留 sudo 交互**: `--sync` 需要密码是正常的，不是 bug
3. **不移除 quarantine**: 使用正常 macOS 授权流程
4. **root 权限边界**: 保镖脚本必须 root 拥有，防提权

### 兼容性
- **向后兼容**: 旧的 `set-client` 调用方式不受影响
- **环境变量**: `CLAUDE_PROXY_CLIENT` 是新增的可选功能
- **auto 模式**: 保留支持，允许混合多客户端环境

### 已知限制
1. **macOS 专用**: Linux 版本在 `linux/` 目录，不适用本修复
2. **Windows 不涉及**: Windows 版本独立实现，不受此问题影响
3. **Clash 配置目录**: 不会被删除或移动，只是不再误判优先级

## 文件清单

### 部署包内容
```
shadowrocket-fix-deployment.tar.gz
├── core/
│   └── claude-switch.sh          # 增强的核心脚本
├── installer/
│   └── 安装.command              # 改进的安装器
├── daemons/                       # 守护脚本模板(未变更)
│   ├── claude-bodyguard.sh
│   ├── tz-watchdog.sh
│   └── *.plist
├── assets/                        # 图标资源(未变更)
└── SHA256SUMS                     # 工件校验清单
```

### 校验和
```
部署包 SHA256: eab60a65cd3d5bd7c0eaa5fa1d69c4748cfa730811086c35b3125ae0a981aa59
```

## 技术细节

### 修改的文件
1. **installer/安装.command** (第 143-226 行):
   - 重写客户端检测逻辑
   - 新增 `CLAUDE_PROXY_CLIENT` 环境变量支持
   - 多阶段检测: 环境变量 → 进程 → 目录 → 手动

2. **core/claude-switch.sh** (第 1706-1775 行):
   - `set_client()` 新增 `--sync` 参数
   - 自动生成 sudo 命令同步保镖
   - 智能检测保镖状态并给出操作建议

3. **SHA256SUMS**: 
   - 更新 `core/claude-switch.sh` 和 `installer/安装.command` 校验和
   - 供自动更新机制验证完整性

### 测试覆盖
- 安装器优先级: 5 个场景测试
- set-client 同步: 5 个功能测试
- 保镖检测: 11 个单元测试(已有，确保未破坏)

## 联系与支持

### 问题反馈
- GitHub Issue: https://github.com/EVA113x/claude-switcher/issues
- 此次修复对应分支: `cursor/fix-shadowrocket-install-bodyguard-a85d`

### 日志收集
如遇问题，请提供:
```bash
# 1. checkdetail 完整输出
~/.local/bin/claude-switch.sh checkdetail

# 2. 保镖日志(最近 20 行)
tail -20 ~/Library/Logs/claude-bodyguard.log

# 3. 配置确认
grep '^PROXY_MODE=' ~/.local/bin/claude-switch.sh
sudo grep '^MODE=' "/Library/Application Support/claude-switcher/claude-bodyguard.sh"

# 4. launchd 状态
launchctl print system/local.claude-bodyguard | grep -A 5 "state"
```

---

**版本**: 修复分支 cursor/fix-shadowrocket-install-bodyguard-a85d  
**日期**: 2026-11-07  
**适用范围**: macOS (v1.9.0 及更早版本升级)
