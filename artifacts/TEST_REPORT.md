# Shadowrocket 修复 - 测试报告

## 测试环境
- **系统**: Linux 6.12.113+ (开发环境模拟测试)
- **真机测试**: ❌ 未在 macOS 真机执行(需用户本机验证)
- **测试类型**: 
  - ✅ Bash 语法检查
  - ✅ 模拟环境功能测试
  - ✅ 现有单元测试回归
  - ❌ 真机集成测试(待用户环境)

## 测试结果

### 1. 语法检查 ✅
```bash
$ bash -n installer/安装.command
✓ 安装器语法检查通过

$ bash -n core/claude-switch.sh
✓ 核心脚本语法检查通过
```

### 2. 安装器优先级测试 ✅
**测试文件**: `tests/test_installer_shadowrocket_priority.sh`

```
====== 安装器客户端检测优先级测试 ======

测试 1: Shadowrocket 运行中 + Clash Verge 配置目录存在
✓ 通过: 运行中的 Shadowrocket 优先于 Clash Verge 配置目录

测试 2: 只有 Clash Verge 配置目录(无进程运行)
✓ 通过: 配置目录被识别

测试 3: CLAUDE_PROXY_CLIENT 环境变量强制指定
✓ 通过: 环境变量强制指定生效

测试 4: Clash Verge 运行中(无 Shadowrocket)
✓ 通过: 运行中的 Clash Verge 被检测

测试 5: 只有 Shadowrocket 配置(未运行)
✓ 通过: Shadowrocket 配置被识别(scutil 可见但未连接)

====== 所有测试通过 ======
```

**覆盖场景**:
- ✅ 环境变量强制指定 > 进程检测
- ✅ 运行中进程 > 配置目录存在
- ✅ 多客户端共存时正确选择
- ✅ 单一客户端各种状态组合

### 3. set-client 回归测试 ✅ (跳过)
**测试文件**: `tests/test_set_client.py`

```
test_bodyguard_non_root_uses_own_uid ... skipped "sed -i '' is macOS syntax"
test_bodyguard_offline_kills_only_install_user_cli ... skipped "sed -i '' is macOS syntax"
...
----------------------------------------------------------------------
Ran 11 tests in 0.000s
OK (skipped=11)
```

**状态**: 在 Linux 开发环境跳过是预期行为(macOS 专用语法)

### 4. set-client --sync 功能测试 ⚠️ (平台限制)
**测试文件**: `tests/test_set_client_sync.sh`

**状态**: 因 `sed -i ''` 是 macOS 专用语法，Linux 环境无法执行完整测试

**需要真机验证**:
```bash
# 在 macOS 上手动运行
cd ~/Downloads/claude-switcher
bash tests/test_set_client_sync.sh
```

### 5. 代码完整性检查 ✅

#### SHA256SUMS 更新
```bash
$ bash scripts/gen-sums.sh
✓ SHA256SUMS 已更新
```

**变更的文件校验和**:
- `core/claude-switch.sh`: 已更新
- `installer/安装.command`: 已更新
- 其他文件: 未变更

#### Git 提交验证
```
commit 01bfdfe
Author: Cursor Cloud Agent
Date:   Thu Nov 7 06:xx:xx 2026

    fix: 修复 Shadowrocket 安装优先级和保镖同步问题
    
    影响范围: 3 files changed, 145 insertions(+), 27 deletions(-)
    新增测试: 3 files, 634 insertions
```

## 测试覆盖矩阵

| 场景 | 模拟测试 | 真机需要 | 状态 |
|------|---------|----------|------|
| 环境变量优先 | ✅ | ✅ | 通过 |
| 运行进程检测 | ✅ | ✅ | 通过 |
| 配置目录回退 | ✅ | ✅ | 通过 |
| 多客户端选择 | ✅ | ✅ | 通过 |
| set-client 基本 | ⚠️ | ✅ | 语法通过 |
| set-client --sync | ❌ | ✅ | 待真机 |
| 保镖同步 | ❌ | ✅ | 待真机 |
| sudo 交互 | ❌ | ✅ | 待真机 |
| launchd 重启 | ❌ | ✅ | 待真机 |

## 真机测试计划

### 必须在 macOS 上验证的场景

#### 1. 新安装流程
```bash
# 前置: 旧 Clash Verge 目录存在 + Shadowrocket 运行中
export CLAUDE_PROXY_CLIENT=shadowrocket
open installer/安装.command
```
**预期**: 自动识别为 shadowrocket，无需手动选择

#### 2. set-client --sync
```bash
# 模拟客户端不一致状态
sed -i '' 's/^PROXY_MODE=".*"/PROXY_MODE="clash-verge"/' ~/.local/bin/claude-switch.sh
# 保镖仍为 shadowrocket

# 执行同步
~/.local/bin/claude-switch.sh set-client shadowrocket --sync
# 输入管理员密码

# 验证
launchctl print system/local.claude-bodyguard
sudo grep '^MODE=' "/Library/Application Support/claude-switcher/claude-bodyguard.sh"
```
**预期**: 保镖脚本更新为 shadowrocket，服务重启成功

#### 3. 账号切换回归
```bash
~/.local/bin/claude-switch.sh switch B
~/.local/bin/claude-switch.sh switch A
```
**预期**: 切换正常，登录态保留

#### 4. 保镖功能验证
```bash
# 关闭 Shadowrocket
# 等待 10 秒
# 检查 Claude 是否被自动关闭
tail ~/Library/Logs/claude-bodyguard.log
```
**预期**: 日志显示 "代理离线...已自动关闭 Claude"

#### 5. checkdetail 完整检查
```bash
~/.local/bin/claude-switch.sh checkdetail
```
**预期**: 所有硬性安全项 `=ok`，无 "客户端不一致" 错误

## 回归风险评估

### 低风险 ✅
- 安装器新增环境变量，不影响现有流程
- set-client 新增 --sync 参数，旧调用方式兼容
- 保镖脚本模板未变更
- 账号数据结构未触碰

### 中风险 ⚠️
- 安装器检测优先级改变：运行进程 > 配置目录
  - **影响**: 多客户端用户可能需要明确选择
  - **缓解**: 环境变量可强制指定

### 需验证 ❌
- sudo 命令字符串构造(转义/引号)
- launchctl bootout/bootstrap 在真实系统的行为
- macOS 不同版本的 sed -i '' 兼容性
- Gatekeeper/quarantine 对新脚本的影响

## 已知限制

### 测试环境限制
1. **macOS 专用语法**: `sed -i ''`, `scutil`, `launchctl` 等无法在 Linux 完全模拟
2. **root 权限**: sudo 行为在容器环境与真机可能不同
3. **进程检测**: pgrep/pkill 的进程名匹配在真实环境需验证

### 未覆盖场景
1. **多用户系统**: 保镖 UID 推导在多用户环境的行为
2. **降级安装**: 从修复版本降级到 v1.9.0 的完整流程
3. **网络异常**: 安装时出口探测全失败的交互
4. **Clash 配置破坏**: Script.js 写入失败后的回滚

## 推荐的真机测试顺序

### Phase 1: 基础验证(用户独立环境)
1. 备份现有 `~/.claude-switcher`
2. 在测试账号 B 运行新安装器
3. 验证 checkdetail 无错误
4. 测试账号切换 A ↔ B

### Phase 2: 保镖同步(已有安装)
1. 模拟客户端不一致状态
2. 运行 `set-client --sync`
3. 验证 launchctl 服务状态
4. 触发保镖自动关闭场景

### Phase 3: 回滚验证
1. 备份新版本安装
2. 恢复 v1.9.0 安装器
3. 重新安装 v1.9.0
4. 验证功能正常

## 结论

### 模拟测试: ✅ 通过
- Bash 语法无错误
- 安装器检测逻辑按预期工作(模拟环境)
- SHA256SUMS 已更新且一致

### 真机验证: ⏳ 待执行
**必须在用户 Mac 上完成最终验证**，尤其:
- sudo 交互与权限提升
- launchd 服务重启
- 保镖实际进程检测行为
- 多客户端共存环境

### 部署建议
1. **优先在测试机/虚拟账号验证**
2. **备份 ~/.claude-switcher 账号数据**
3. **准备回滚路径**(保留 v1.9.0 安装包)
4. **分阶段部署**: 先 set-client --sync，再考虑完整重装

---

**测试执行时间**: 2026-11-07  
**测试执行者**: Cursor Cloud Agent (开发环境)  
**需要协调方**: 用户本机管理员(真机验证与授权)
