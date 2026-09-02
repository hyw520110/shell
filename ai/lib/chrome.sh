#!/bin/bash
# ==================== Chrome 检测模块 ====================
# 提供 Chrome 路径检测、验证和配置功能
# 兼容 Bash 3.2+

# 验证Chrome路径是否正确
validate_chrome_path() {
    local path=$1

    if [[ -z "$path" ]]; then
        debug_log "Chrome路径为空"
        return 1
    fi

    if [[ ! -f "$path" ]]; then
        debug_log "Chrome路径文件不存在: $path"
        return 1
    fi

    if [[ ! -r "$path" ]]; then
        debug_log "Chrome路径文件不可读: $path"
        return 1
    fi

    if [[ ! -x "$path" ]]; then
        debug_log "Chrome路径文件不可执行，尝试添加执行权限: $path"
        if ! chmod +x "$path" 2>/dev/null; then
            debug_log "无法为Chrome文件添加执行权限: $path"
            return 1
        fi
        debug_log "已成功为Chrome文件添加执行权限: $path"
    fi

    debug_log "Chrome路径验证成功: $path"
    return 0
}

# 检测Chrome可执行文件路径
detect_chrome_path() {
    local cache_file="$HOME/.ai-cli-chrome-cache"
    local cache_ttl=1800

    # 检查缓存
    if [[ -f "$cache_file" ]]; then
        local cache_time=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)
        local current_time=$(date +%s)
        local cache_age=$((current_time - cache_time))

        debug_log "缓存检查: 文件存在，年龄 ${cache_age} 秒，TTL ${cache_ttl} 秒"

        if [[ $cache_age -lt $cache_ttl ]]; then
            local cached_path=$(cat "$cache_file" 2>/dev/null)
            if [[ -n "$cached_path" && -f "$cached_path" ]]; then
                debug_log "从缓存获取Chrome路径: $cached_path (缓存年龄: ${cache_age}秒)"
                echo "$cached_path"
                return 0
            else
                debug_log "缓存路径无效或不存在: '$cached_path'"
            fi
        else
            debug_log "缓存已过期: ${cache_age} 秒 >= ${cache_ttl} 秒"
        fi
    else
        debug_log "缓存文件不存在: $cache_file"
    fi

    local chrome_path=""

    debug_log "开始检测Chrome路径，当前操作系统: $OS"

    # 首先检查环境变量
    if [[ -n "$CHROME_PATH" && -f "$CHROME_PATH" ]]; then
        chrome_path="$CHROME_PATH"
        debug_log "使用环境变量CHROME_PATH: $chrome_path"
        echo "$chrome_path" > "$cache_file"
        echo "$chrome_path"
        return 0
    fi

    if [[ "$OS" == "macOS" ]]; then
        local macos_paths=(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
            "/Applications/Chromium.app/Contents/MacOS/Chromium"
        )

        for path in "${macos_paths[@]}"; do
            if [[ -f "$path" ]]; then
                chrome_path="$path"
                debug_log "在macOS预设路径找到Chrome: $path"
                break
            fi
        done

        if [[ -z "$chrome_path" ]]; then
            debug_log "预设路径未找到，搜索 /Applications 目录..."
            for app in /Applications/*.app; do
                if [[ -d "$app" ]]; then
                    local app_name=$(basename "$app" .app)
                    if [[ "$app_name" == "Google Chrome" || "$app_name" == "Chromium" ]]; then
                        local executable="$app/Contents/MacOS/$app_name"
                        if [[ -f "$executable" ]]; then
                            chrome_path="$executable"
                            debug_log "在 /Applications 目录找到Chrome: $executable"
                            break
                        fi
                    fi
                fi
            done
        fi

    elif [[ "$OS" == "Linux" ]]; then
        local linux_paths=(
            "/usr/bin/google-chrome"
            "/usr/bin/google-chrome-stable"
            "/usr/bin/google-chrome-beta"
            "/usr/bin/google-chrome-dev"
            "/usr/local/bin/google-chrome"
            "/usr/local/bin/chrome"
            "/opt/google/chrome/google-chrome"
            "/opt/google/chrome-beta/google-chrome"
            "/opt/google/chrome-unstable/google-chrome"
            "/opt/apps/cn.google.chrome-pre/files/google/chrome/chrome"
            "/opt/apps/*/google/chrome/chrome"
            "/usr/bin/chromium-browser"
            "/usr/bin/chromium"
            "/usr/local/bin/chromium-browser"
            "/snap/bin/chromium"
        )

        for path in "${linux_paths[@]}"; do
            if [[ -f "$path" ]]; then
                chrome_path="$path"
                debug_log "在Linux预设路径找到Chrome: $path"
                break
            fi
        done

        if [[ -z "$chrome_path" ]]; then
            debug_log "预设路径未找到，动态搜索常用软件目录..."

            local search_dirs=(
                "/opt"
                "/opt/apps"
                "$HOME/.local/share"
                "$HOME/Applications"
                "/usr/local"
                "/snap/bin"
            )

            for search_dir in "${search_dirs[@]}"; do
                if [[ -d "$search_dir" ]]; then
                    debug_log "搜索目录: $search_dir"
                    local found_chromes=$(find "$search_dir" -maxdepth 4 \( -name "google-chrome" -o -name "chrome" -o -name "chromium" \) -type f 2>/dev/null | head -3)
                    for found in $found_chromes; do
                        if [[ -f "$found" ]] && [[ -x "$found" ]]; then
                            chrome_path="$found"
                            debug_log "动态找到Chrome: $found"
                            break 2
                        fi
                    done
                fi
            done
        fi

        if [[ -z "$chrome_path" ]]; then
            local which_result
            which_result=$(which google-chrome 2>/dev/null || which chromium-browser 2>/dev/null || which chromium 2>/dev/null || which chrome 2>/dev/null || echo "")
            if [[ -n "$which_result" && -f "$which_result" ]]; then
                chrome_path="$which_result"
                debug_log "通过which命令找到Chrome: $chrome_path"
            fi
        fi

        if [[ -z "$chrome_path" ]]; then
            local whereis_result=$(whereis google-chrome 2>/dev/null | cut -d' ' -f2- | cut -d' ' -f1)
            if [[ -n "$whereis_result" && -f "$whereis_result" ]]; then
                chrome_path="$whereis_result"
                debug_log "通过whereis命令找到Chrome: $chrome_path"
            fi
        fi
    else
        warn_log "不支持的操作系统: $OS"
    fi

    if [[ -n "$chrome_path" ]]; then
        debug_log "检测到Chrome路径: $chrome_path"
        echo "$chrome_path" > "$cache_file"
        debug_log "Chrome路径已缓存到文件: $cache_file"
        echo "$chrome_path"
        return 0
    else
        debug_log "未找到Chrome浏览器"
        echo "" > "$cache_file"
        debug_log "已缓存未找到Chrome的结果（5分钟TTL）"
        return 1
    fi
}

# 验证并修复Chrome路径配置
validate_and_fix_chrome_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        debug_log "配置文件不存在: $config_file"
        return 1
    fi
    
    # 检测 Chrome 路径
    local chrome_path
    chrome_path=$(detect_chrome_path)
    
    if [[ -z "$chrome_path" ]]; then
        warn_log "未检测到 Chrome，某些功能可能不可用"
        return 1
    fi
    
    # 验证路径
    if validate_chrome_path "$chrome_path"; then
        info_log "Chrome 路径验证成功: $chrome_path"
        echo "$chrome_path"
        return 0
    else
        error_log "Chrome 路径验证失败: $chrome_path"
        return 1
    fi
}
