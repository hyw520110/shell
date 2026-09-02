#!/bin/bash

# 关联数组兼容层 (Bash 3.2)
# Bash 3.2 不支持 declare -A,使用 eval 模拟（比文件 I/O 快 10-100 倍）
_USE_ASSOC_ARRAY=true
if ! (declare -A _test 2>/dev/null); then
    _USE_ASSOC_ARRAY=false

    # 将任意键名转换为合法的 bash 变量名
    # 将所有非字母数字下划线的字符替换为下划线
    _assoc_sanitize_key() {
        local key="$1"
        # 使用内置替换，避免调用 tr (Bash 3.2+)
        local sanitized="${key//[^a-zA-Z0-9_]/_}"
        echo "$sanitized"
    }

    # 设置键值
    assoc_set() {
        local array_name="$1" key="$2" value="$3"
        local safe_key
        safe_key=$(_assoc_sanitize_key "$key")
        # 验证变量名合法性（防注入）
        if [[ "$array_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            local escaped_value; printf -v escaped_value "%q" "$value"
            eval "ASSOC_${array_name}_${safe_key}=$escaped_value"
        else
            echo "警告: 非法的数组名称: $array_name" >&2
            return 1
        fi
    }

    # 获取值
    assoc_get() {
        local array_name="$1" key="$2" default="${3:-}"
        local safe_key
        safe_key=$(_assoc_sanitize_key "$key")
        local var_name="ASSOC_${array_name}_${safe_key}"
        # 使用间接引用获取值
        echo "${!var_name:-$default}"
    }

    # 检查键是否存在
    assoc_has() {
        local array_name="$1" key="$2"
        local safe_key
        safe_key=$(_assoc_sanitize_key "$key")
        local var_name="ASSOC_${array_name}_${safe_key}"
        [[ -n "${!var_name+x}" ]]
    }

    # 清理（无需操作，因为使用内存变量）
    assoc_cleanup() {
        true
    }

    # 无需 trap 清理
fi

# 关联数组包装函数(透明使用原生或模拟实现)
# 设置值: assoc_set_wrapper "数组名" "键" "值"
assoc_set_wrapper() {
    local array_name="$1" key="$2" value="$3"
    if [[ "$_USE_ASSOC_ARRAY" == "true" ]]; then
        [[ "$array_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
        # 使用 printf %q 安全转义键和值
        local escaped_key escaped_value
        printf -v escaped_key "%q" "$key"
        printf -v escaped_value "%q" "$value"
        eval "${array_name}[$escaped_key]=$escaped_value"
    else
        assoc_set "$array_name" "$key" "$value"
    fi
}

# 获取值: assoc_get_wrapper "数组名" "键" ["默认值"]
assoc_get_wrapper() {
    local array_name="$1" key="$2" default="${3:-}"
    if [[ "$_USE_ASSOC_ARRAY" == "true" ]]; then
        [[ "$array_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { echo "$default"; return 1; }
        local result=""
        local escaped_key; printf -v escaped_key "%q" "$key"
        if eval '[[ -n "${'"$array_name"'['"$escaped_key"']+x}" ]]'; then
            eval "result=\${${array_name}[$escaped_key]}"
        else
            result="$default"
        fi
        echo "$result"
    else
        assoc_get "$array_name" "$key" "$default"
    fi
}
