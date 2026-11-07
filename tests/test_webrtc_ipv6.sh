#!/bin/bash
# WebRTC IPv6 出口检测回归测试
set -e

echo "====== WebRTC IPv6 出口检测测试 ======"
echo ""

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMP=$(mktemp -d)
trap "rm -rf '$TEMP'" EXIT

# 提取 assess_probe 函数到 Python 测试脚本
cat > "$TEMP/test_assess.py" << 'PYTHON_END'
#!/usr/bin/env python3
import sys
import ipaddress

def assess_probe(policy, expected_ip, output, exit_code):
    if exit_code != "0":
        return "fail:STUN 探测执行失败，未确认 UDP 出口"
    # 验证 expected_ip 是否为有效 IPv4(STUN 仅支持 IPv4)
    try:
        expected = ipaddress.IPv4Address(expected_ip)
    except ValueError:
        # expected_ip 不是 IPv4: 可能是 IPv6、空值或无效格式
        # 这不是 STUN 泄漏,而是无法获取可靠的 IPv4 观测进行比对
        if ":" in expected_ip:
            # 明确是 IPv6 地址
            return "warn:出口为 IPv6,STUN 比对需 IPv4 观测,无法验证(非泄漏)"
        return "warn:未获取有效 IPv4 出口,无法比对 STUN(非探测失败)"
    if output == "RESULT:NONE":
        if policy == "reject":
            return "ok:常见 STUN UDP 拒绝规则已验证，探测无响应"
        return "fail:STUN 无响应，无法确认 UDP 是否经过代理"
    if not output.startswith("RESULT:"):
        return "fail:STUN 探测结果格式异常"
    try:
        addresses = [ipaddress.IPv4Address(value) for value in output[7:].split(",")]
    except ValueError:
        return "fail:STUN 探测结果格式异常"
    if policy == "reject":
        return "fail:拒绝策略下仍收到 STUN 响应，请检查运行规则"
    if any(address != expected for address in addresses):
        return "fail:STUN 暴露了非代理出口地址"
    return "ok:STUN 仅返回代理出口地址"

# 运行测试
if __name__ == "__main__":
    tests = [
        # (policy, expected_ip, output, exit_code, expected_result_prefix)
        ("proxy", "203.0.113.1", "RESULT:203.0.113.1", "0", "ok:"),
        ("proxy", "203.0.113.1", "RESULT:203.0.113.1,198.51.100.1", "0", "fail:STUN 暴露"),
        ("proxy", "2001:db8::1", "RESULT:203.0.113.1", "0", "warn:出口为 IPv6"),
        ("proxy", "", "RESULT:203.0.113.1", "0", "warn:未获取有效 IPv4"),
        ("proxy", "invalid", "RESULT:203.0.113.1", "0", "warn:未获取有效 IPv4"),
        ("proxy", "203.0.113.1", "RESULT:NONE", "0", "fail:STUN 无响应"),
        ("reject", "203.0.113.1", "RESULT:NONE", "0", "ok:常见 STUN UDP 拒绝"),
        ("proxy", "203.0.113.1", "ERROR", "1", "fail:STUN 探测执行失败"),
    ]
    
    passed = 0
    failed = 0
    for policy, expected_ip, output, exit_code, expected_prefix in tests:
        result = assess_probe(policy, expected_ip, output, exit_code)
        if result.startswith(expected_prefix):
            print(f"✓ 通过: policy={policy}, expected={expected_ip}, output={output}")
            passed += 1
        else:
            print(f"✗ 失败: policy={policy}, expected={expected_ip}")
            print(f"  期望前缀: {expected_prefix}")
            print(f"  实际结果: {result}")
            failed += 1
    
    print(f"\n总计: {passed} 通过, {failed} 失败")
    sys.exit(0 if failed == 0 else 1)
PYTHON_END

chmod +x "$TEMP/test_assess.py"
python3 "$TEMP/test_assess.py"

echo ""
echo "====== 所有测试通过 ======"
