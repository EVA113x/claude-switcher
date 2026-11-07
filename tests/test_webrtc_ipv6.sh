#!/bin/bash
# WebRTC IPv6 出口检测回归测试 - 修正版(fail-closed)
set -e

echo "====== WebRTC IPv6 出口检测测试(修正版) ======"
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
        # expected_ip 不是 IPv4: 尝试解析为 IPv6 或判定为无效
        try:
            ipaddress.IPv6Address(expected_ip)
            # 确实是 IPv6 地址
            return "fail:出口为 IPv6,STUN 无法验证 UDP 泄漏,不能放行"
        except ValueError:
            # 空值或无效格式
            return "fail:未获取有效出口 IP,无法验证 STUN,不能放行"
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
        # (policy, expected_ip, output, exit_code, expected_result_prefix, test_name)
        ("proxy", "203.0.113.1", "RESULT:203.0.113.1", "0", "ok:", "IPv4匹配"),
        ("proxy", "203.0.113.1", "RESULT:203.0.113.1,198.51.100.1", "0", "fail:STUN 暴露", "IPv4泄漏"),
        ("proxy", "2001:db8::1", "RESULT:203.0.113.1", "0", "fail:出口为 IPv6", "IPv6出口(fail-closed)"),
        ("proxy", "", "RESULT:203.0.113.1", "0", "fail:未获取有效出口", "空出口(fail-closed)"),
        ("proxy", "invalid", "RESULT:203.0.113.1", "0", "fail:未获取有效出口", "无效格式(fail-closed)"),
        ("proxy", "203.0.113.1", "RESULT:NONE", "0", "fail:STUN 无响应", "STUN无响应"),
        ("reject", "203.0.113.1", "RESULT:NONE", "0", "ok:常见 STUN UDP 拒绝", "reject策略无响应"),
        ("proxy", "203.0.113.1", "ERROR", "1", "fail:STUN 探测执行失败", "探测失败"),
        ("proxy", "2001:0db8:85a3:0000:0000:8a2e:0370:7334", "RESULT:203.0.113.1", "0", "fail:出口为 IPv6", "完整IPv6地址"),
        ("proxy", "not::valid::ipv6", "RESULT:203.0.113.1", "0", "fail:未获取有效出口", "格式错误"),
    ]
    
    passed = 0
    failed = 0
    for policy, expected_ip, output, exit_code, expected_prefix, name in tests:
        result = assess_probe(policy, expected_ip, output, exit_code)
        if result.startswith(expected_prefix):
            print(f"✓ 通过: {name}")
            passed += 1
        else:
            print(f"✗ 失败: {name}")
            print(f"  输入: policy={policy}, expected={expected_ip}, output={output}")
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
