#!/bin/bash
# 版本检测辅助函数单元测试
set -u
cd "$(dirname "$0")/.."
source ./ai-hub.sh

pass=0; fail=0
check() { # desc expected actual
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); printf '  ✓ %s\n' "$1"
    else fail=$((fail+1)); printf '  ✗ %s\n    期望: [%s]\n    实际: [%s]\n' "$1" "$2" "$3"; fi
}

echo "== npm_cmd_extract_spec =="
check "无引号钉版本" "@deepseek-ai/dsh@0.1.1-rc.2" "$(npm_cmd_extract_spec 'npm install -g @deepseek-ai/dsh@0.1.1-rc.2')"
check "单引号+registry" "gitnexus@latest" "$(npm_cmd_extract_spec "npm install -g 'gitnexus@latest' --registry 'https://registry.npmmirror.com'")"
check "带代理前缀" "context-mode" "$(npm_cmd_extract_spec "HTTP_PROXY='x' npm install -g context-mode --registry r")"
check "无版本号" "openclaw" "$(npm_cmd_extract_spec 'npm install -g openclaw')"
check "npx 命令不匹配" "" "$(npm_cmd_extract_spec 'npx -y @deepseek-ai/dsh@latest --help')"

echo "== npm_spec_name =="
check "scoped 钉版本" "@deepseek-ai/dsh" "$(npm_spec_name '@deepseek-ai/dsh@0.1.1-rc.2')"
check "scoped 无版本" "@deepseek-ai/dsh" "$(npm_spec_name '@deepseek-ai/dsh')"
check "scoped @latest" "@deepseek-ai/dsh" "$(npm_spec_name '@deepseek-ai/dsh@latest')"
check "非 scoped 钉版本" "gitnexus" "$(npm_spec_name 'gitnexus@1.2.3')"
check "非 scoped latest" "gitnexus" "$(npm_spec_name 'gitnexus@latest')"
check "非 scoped 无版本" "context-mode" "$(npm_spec_name 'context-mode')"

echo "== npm_latest_version（网络） =="
lv=$(npm_latest_version "@deepseek-ai/dsh")
[[ -n "$lv" ]] && echo "  ✓ @deepseek-ai/dsh 最新版本: $lv" || { fail=$((fail+1)); echo "  ✗ npm_latest_version 返回空"; }
check "不存在的包返回空" "" "$(npm_latest_version '@deepseek-ai/no-such-pkg-xyz')"

echo "== npm_installed_version（本地文件） =="
iv=$(npm_installed_version "@deepseek-ai/dsh")
if [[ -n "$iv" ]]; then
    npm_record=$(npm list -g @deepseek-ai/dsh --depth=0 --json 2>/dev/null | jq -r '.dependencies["@deepseek-ai/dsh"].version // empty')
    check "已安装版本与 npm 记录一致" "$npm_record" "$iv"
else
    check "未安装的 dsh 返回空" "" "$iv"
fi
iv2=$(npm_installed_version "opencode-ai")
if [[ -n "$iv2" ]]; then echo "  ✓ opencode-ai 已安装: v$iv2"; else echo "  ⚠ opencode-ai 未检测到（可能未通过 npm 全局安装）"; fi

echo "== update 钉版本提升替换逻辑 =="
nvd_spec="@deepseek-ai/dsh@0.1.1-rc.2"; nvd_name="@deepseek-ai/dsh"; nvd_latest="0.2.1-rc.2"
run_cmd="npm install -g @deepseek-ai/dsh@0.1.1-rc.2"
run_cmd="${run_cmd//"$nvd_spec"/"$nvd_name@$nvd_latest"}"
check "钉版本→最新" "npm install -g @deepseek-ai/dsh@0.2.1-rc.2" "$run_cmd"

echo
echo "结果: $pass 通过, $fail 失败"
exit $((fail > 0))
