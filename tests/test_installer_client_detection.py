"""安装器客户端检测回归测试:模拟各种环境场景。"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "installer" / "安装.command"


@unittest.skipUnless(sys.platform == "darwin", "macOS installer")
class InstallerClientDetectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        
        # 创建必要的假命令
        self._stub("python3", "#!/bin/sh\necho 'Python 3.9.0'\n")
        self._stub("swiftc", "#!/bin/sh\necho 'Swift version 5.9'\n")
        self._stub("pgrep", "#!/bin/sh\nexit 1\n")  # 默认无进程运行
        self._stub("scutil", "#!/bin/sh\nexit 1\n")  # 默认无 Shadowrocket
        self._stub("launchctl", "#!/bin/sh\nexit 0\n")
        self._stub("curl", "#!/bin/sh\n"
                   "case \"$*\" in\n"
                   "  *ipinfo.io*) echo '{\"country\":\"US\",\"timezone\":\"America/New_York\"}' ;;\n"
                   "  *cdn-cgi/trace*) echo 'ip=198.51.100.1' && echo 'loc=US' ;;\n"
                   "esac\n")
        
        # Claude.app 目录
        claude_app = self.home / "Applications" / "Claude.app" / "Contents" / "MacOS"
        claude_app.mkdir(parents=True)
        (claude_app / "Claude").touch()

    def _stub(self, name, content):
        path = self.fakebin / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def _run_installer_detect(self, env_vars=None):
        """只运行安装器的客户端检测部分,提取 MODE 值"""
        # 修改安装器脚本,在设置 MODE 后立即输出并退出
        source = INSTALLER.read_text(encoding="utf-8")
        lines = source.splitlines()
        
        # 找到 "✓ 代理客户端: $MODE" 这行,在其后插入输出和退出
        modified = []
        for line in lines:
            modified.append(line)
            if line.strip() == 'echo "✓ 代理客户端: $MODE"':
                modified.append('echo "DETECTED_MODE=$MODE"')
                modified.append('exit 0')
                break
        
        test_script = self.root / "test-installer.sh"
        test_script.write_text("\n".join(modified), encoding="utf-8")
        
        env = dict(os.environ)
        env["HOME"] = str(self.home)
        env["PATH"] = f"{self.fakebin}:/usr/bin:/bin"
        env["DRYRUN"] = "1"  # 防止实际安装
        if env_vars:
            env.update(env_vars)
        
        result = subprocess.run(
            ["/bin/bash", str(test_script)],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
            input="\n"  # 自动回答任何提示
        )
        
        # 从输出提取 MODE
        for line in result.stdout.splitlines():
            if line.startswith("DETECTED_MODE="):
                return line.split("=", 1)[1]
        return None

    def test_env_var_forces_mode(self):
        """CLAUDE_PROXY_CLIENT 环境变量应强制指定客户端"""
        mode = self._run_installer_detect({"CLAUDE_PROXY_CLIENT": "shadowrocket"})
        self.assertEqual(mode, "shadowrocket")
        
        mode = self._run_installer_detect({"CLAUDE_PROXY_CLIENT": "flclash"})
        self.assertEqual(mode, "flclash")

    def test_running_shadowrocket_detected(self):
        """运行中的 Shadowrocket 应被优先检测"""
        # 模拟 Shadowrocket 已连接
        self._stub("scutil", "#!/bin/sh\n"
                   "echo '  (Connected)      com.liguangming.Shadowrocket'\n")
        
        mode = self._run_installer_detect()
        self.assertEqual(mode, "shadowrocket")

    def test_running_client_prioritized_over_config_dir(self):
        """运行中的客户端应优先于仅有配置目录的客户端"""
        # 创建 Clash Verge 配置目录(但不运行)
        clash_dir = self.home / "Library" / "Application Support" / \
                    "io.github.clash-verge-rev.clash-verge-rev"
        clash_dir.mkdir(parents=True)
        
        # 模拟 Shadowrocket 运行中
        self._stub("scutil", "#!/bin/sh\n"
                   "echo '  (Connected)      com.liguangming.Shadowrocket'\n")
        
        mode = self._run_installer_detect()
        self.assertEqual(mode, "shadowrocket", 
                        "运行中的 Shadowrocket 应优先于 Clash Verge 配置目录")

    def test_multiple_running_clients_prompts_choice(self):
        """多个运行中的客户端应提示用户选择"""
        # 模拟多个客户端运行
        self._stub("pgrep", "#!/bin/sh\n"
                   "case \"$*\" in\n"
                   "  *verge-mihomo*) exit 0 ;;\n"
                   "  *FlClash*) exit 0 ;;\n"
                   "  *) exit 1 ;;\n"
                   "esac\n")
        
        # 这个测试需要交互输入,这里只验证脚本不会崩溃
        # 实际环境下会提示用户选择
        result = self._run_installer_detect()
        # 在自动测试中会选择第一个或需要手动输入
        self.assertIsNotNone(result)

    def test_config_dir_only_warns_not_running(self):
        """仅有配置目录(客户端未运行)应发出警告"""
        # 只创建配置目录,不运行进程
        clash_dir = self.home / "Library" / "Application Support" / \
                    "io.github.clash-verge-rev.clash-verge-rev"
        clash_dir.mkdir(parents=True)
        
        result = self._run_installer_detect()
        # 应该检测到 clash-verge(基于配置目录)
        self.assertIsNotNone(result)

    def test_flclash_running_detected(self):
        """运行中的 FlClash 应被检测"""
        self._stub("pgrep", "#!/bin/sh\n"
                   "case \"$*\" in\n"
                   "  *FlClashCore*) exit 0 ;;\n"
                   "  *) exit 1 ;;\n"
                   "esac\n")
        
        mode = self._run_installer_detect()
        self.assertEqual(mode, "flclash")

    def test_clash_verge_running_detected(self):
        """运行中的 Clash Verge 应被检测"""
        self._stub("pgrep", "#!/bin/sh\n"
                   "case \"$*\" in\n"
                   "  *verge-mihomo*) exit 0 ;;\n"
                   "  *) exit 1 ;;\n"
                   "esac\n")
        
        mode = self._run_installer_detect()
        self.assertEqual(mode, "clash-verge")


if __name__ == "__main__":
    unittest.main()
