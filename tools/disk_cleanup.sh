#!/bin/bash

# 跨平台磁盘清理脚本
# 安全清理用户缓存、临时文件和下载内容
# 支持Linux和macOS系统
# 不会删除系统文件或重要数据

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 系统检测函数
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            echo "macOS"
            ;;
        Linux*)
            echo "Linux"
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# 系统详细检测函数（用于检测不同Linux发行版）
detect_distro() {
    if [[ "$OS_TYPE" != "Linux" ]]; then
        return 1
    fi
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)
DISTRO=$(detect_distro)
SCRIPT_NAME="磁盘清理工具"
if [[ "$OS_TYPE" == "macOS" ]]; then
    SCRIPT_NAME="macOS 磁盘清理工具"
fi

# 显示脚本信息
echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}          ${SCRIPT_NAME} (安全版)${NC}"
if [[ "$OS_TYPE" == "Linux" ]]; then
    echo -e "${BLUE}       仅清理用户可安全删除的缓存和临时文件${NC}"
else
    echo -e "${BLUE}      仅清理用户可安全删除的缓存和临时文件${NC}"
fi
echo -e "${BLUE}      不会删除系统关键文件${NC}"
echo -e "${BLUE}==================================================${NC}"

# 显示当前磁盘使用情况
show_disk_usage() {
    echo -e "\\n${YELLOW}当前磁盘使用情况:${NC}"
    df -h /
    echo -e "\\n${YELLOW}当前可用磁盘空间:${NC}"
    df -h / | awk 'NR==2 {print $4 "B (" $5 " 已使用)"}'
}

show_disk_usage

# 检查是否有足够权限执行某些操作
check_permissions() {
    # 检查是否可以访问用户目录
    if [[ ! -r "$HOME" ]]; then
        echo -e "${RED}错误: 没有权限访问 $HOME 目录${NC}"
        exit 1
    fi
}

check_permissions

# 获取目录大小的函数，兼容不同系统的 du 命令行为
get_dir_size() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        # 在 macOS 上，某些版本的 du 可能不支持 -h 选项，所以先尝试获取字节大小
        if [[ "$OS_TYPE" == "macOS" ]]; then
            # macOS 上的 du 通常支持 -h，但为了兼容性，先尝试获取原始大小
            local size_bytes
            size_bytes=$(du -s "$dir" 2>/dev/null | cut -f1)
            # 转换为人类可读格式
            if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
                # 将字节转换为 KB, MB, GB
                if [ "$size_bytes" -ge 1073741824 ]; then
                    printf "%.1fGB" "$(echo "$size_bytes/1073741824" | bc -l 2>/dev/null || echo "0")"
                elif [ "$size_bytes" -ge 1048576 ]; then
                    printf "%.1fMB" "$(echo "$size_bytes/1048576" | bc -l 2>/dev/null || echo "0")"
                elif [ "$size_bytes" -ge 1024 ]; then
                    printf "%.1fKB" "$(echo "$size_bytes/1024" | bc -l 2>/dev/null || echo "0")"
                else
                    printf "%dB" "$size_bytes"
                fi
            else
                # 如果无法转换，返回原始 du 输出
                du -sh "$dir" 2>/dev/null | cut -f1
            fi
        else
            # Linux 系统
            du -sh "$dir" 2>/dev/null | cut -f1
        fi
    else
        echo "N/A"
    fi
}

# 安全清理函数
cleanup() {
    local dir="$1"
    local name="$2"
    
    # 检查目录是否存在
    if [[ -d "$dir" ]]; then
        # 使用 du 获取大小，过滤掉错误信息
        local size_before
        size_before=$(get_dir_size "$dir")
        
        # 安全检查：确保目录路径有效以防止意外删除
        if [[ "$dir" == "/" || "$dir" == "" ]]; then
            echo -e "${RED}错误: 试图删除根目录或空路径，已中止清理操作！${NC}"
            return 1
        fi
        
        # 显示要清理的目录信息并请求确认
        echo -e "  - 检查到 ${GREEN}$name${NC} 目录 ($dir)，大小: ${YELLOW}$size_before${NC}"
        read -r -p "  - 确认清理 $name? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            # 使用 find 进行更安全的删除，只删除内容不删除目录本身
            if find "$dir" -mindepth 1 -maxdepth 1 -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
                local size_after
                size_after=$(get_dir_size "$dir")
                echo -e "  ${GREEN}✓${NC} 已清理 $name: $size_before -> $size_after"
            else
                echo -e "  ${RED}✗${NC} 清理 $name 时出现错误"
            fi
        else
            echo -e "  ${YELLOW}-${NC} 已跳过 $name"
        fi
    else
        echo -e "  ${YELLOW}-${NC} 警告: $name 目录不存在，跳过 ($dir)"
    fi
}

# 清理用户缓存（安全版本）
cleanup_user_cache() {
    local cache_dir="$1"
    local name="$2"
    
    if [[ -d "$cache_dir" ]]; then
        echo -e "  - 扫描 ${GREEN}$name${NC} ($cache_dir)..."
        local size_before
        size_before=$(get_dir_size "$cache_dir")
        echo -e "  - 当前大小: ${YELLOW}$size_before${NC}"
        
        # 确认
        read -r -p "  - 确认清理 $name? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            # 只删除非隐藏目录/文件以避免删除重要的缓存结构
            if find "$cache_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
                local size_after
                size_after=$(get_dir_size "$cache_dir")
                echo -e "  ${GREEN}✓${NC} 已清理 $name: $size_before -> $size_after"
            else
                echo -e "  ${RED}✗${NC} 清理 $name 时出现错误"
            fi
        else
            echo -e "  ${YELLOW}-${NC} 已跳过 $name"
        fi
    else
        echo -e "  ${YELLOW}-${NC} 警告: $name 目录不存在，跳过 ($cache_dir)"
    fi
}

# 清理下载文件夹（保留重要文件）
cleanup_downloads() {
    local downloads_dir="$HOME/Downloads"
    
    if [[ -d "$downloads_dir" ]]; then
        echo -e "  - 扫描下载文件夹 ($downloads_dir)..."
        local size_before
        size_before=$(get_dir_size "$downloads_dir")
        echo -e "  - 当前大小: ${YELLOW}$size_before${NC}"
        
        # 确认
        read -r -p "  - 确认清空下载文件夹（保留安装包如dmg/pkg/iso）? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            # 查找并删除非隐藏文件，除了安装程序
            local find_cmd="find \"$downloads_dir\" -maxdepth 1 -type f -not -name \".*\""
            # 根据操作系统添加不同的安装包扩展名
            if [[ "$OS_TYPE" == "macOS" ]]; then
                find_cmd="$find_cmd -not -name \"*.dmg\" -not -name \"*.pkg\" -not -name \"*.iso\" -not -name \"*.mpkg\""
            else
                find_cmd="$find_cmd -not -name \"*.deb\" -not -name \"*.rpm\" -not -name \"*.AppImage\" -not -name \"*.flatpak\" -not -name \"*.snap\""
            fi
            find_cmd="$find_cmd -delete 2>/dev/null"
            
            if eval $find_cmd; then
                # 同时删除空目录
                find "$downloads_dir" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
                
                local size_after
                size_after=$(get_dir_size "$downloads_dir")
                echo -e "  ${GREEN}✓${NC} 已清理下载文件夹: $size_before -> $size_after (保留安装包)"
            else
                echo -e "  ${RED}✗${NC} 清理下载文件夹时出现错误"
            fi
        else
            echo -e "  ${YELLOW}-${NC} 已跳过下载文件夹清理"
        fi
    else
        echo -e "  ${YELLOW}-${NC} 警告: 下载文件夹不存在，跳过 ($downloads_dir)"
    fi
}

# 清理 macOS 专用文件
cleanup_macos_specific() {
    if [[ "$OS_TYPE" == "macOS" ]]; then
        echo -e "\\n正在清理 macOS 专用缓存..."
        
        # 清理 Safari 下载历史
        local safari_file="$HOME/Library/Safari/Downloads.plist"
        if [[ -f "$safari_file" ]]; then
            echo -e "  - 找到 Safari 下载历史: $safari_file"
            read -r -p "  - 确认清理 Safari 下载历史? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -f "$safari_file" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Safari 下载历史"
                else
                    echo -e "  ${RED}✗${NC} 清理 Safari 下载历史时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Safari 下载历史清理"
            fi
        else
            echo -e "  - Safari 下载历史文件不存在，跳过"
        fi
        
        # 清理系统诊断报告
        echo -e "\\n正在清理系统诊断报告 (/Library/Logs/DiagnosticReports)..."
        cleanup "/Library/Logs/DiagnosticReports" "系统诊断报告"
        
        # 清理软件更新缓存
        echo -e "\\n正在清理软件更新缓存 (/Library/Caches/com.apple.SoftwareUpdate)..."
        if [[ -d "/Library/Caches/com.apple.SoftwareUpdate" ]]; then
            echo -e "  - 检测到软件更新缓存，需要管理员权限"
            read -r -p "  - 确认清理软件更新缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo rm -rf /Library/Caches/com.apple.SoftwareUpdate/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理软件更新缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理软件更新缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过软件更新缓存清理"
            fi
        else
            echo -e "  - 软件更新缓存目录不存在，跳过"
        fi
        
        # 清理 Trash（macOS 回收站）
        local trash_dir="$HOME/.Trash"
        if [[ -d "$trash_dir" ]]; then
            echo -e "\\n正在清理用户回收站..."
            local trash_size
            trash_size=$(get_dir_size "$trash_dir")
            echo -e "  - 当前回收站大小: ${YELLOW}$trash_size${NC}"
            read -r -p "  - 确认清空回收站? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$trash_dir"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清空回收站"
                    # 重建目录
                    mkdir -p "$trash_dir" 2>/dev/null
                else
                    echo -e "  ${RED}✗${NC} 清空回收站时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过回收站清理"
            fi
        fi
        
        # 清理系统临时文件
        echo -e "\\n正在清理系统临时文件..."
        if [[ -d "/private/tmp" ]]; then
            read -r -p "  - 确认清理 /private/tmp? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                cleanup "/private/tmp" "系统临时文件"
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 /private/tmp 清理"
            fi
        fi
        
        # 清理系统缓存 (/System/Volumes/Data/Volumes/Data/com.apple.MachineLearning 等)
        echo -e "\\n正在清理系统缓存..."
        if [[ -d "/System/Volumes/Data/com.apple.MachineLearning" ]]; then
            local ml_cache="/System/Volumes/Data/com.apple.MachineLearning"
            local ml_cache_size
            ml_cache_size=$(get_dir_size "$ml_cache")
            echo -e "  - 检测到机器学习模型缓存，大小: ${YELLOW}$ml_cache_size${NC}"
            read -r -p "  - 确认清理机器学习模型缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo rm -rf "$ml_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理机器学习模型缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理机器学习模型缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过机器学习模型缓存清理"
            fi
        fi
        
        # 清理用户日志文件
        echo -e "\\n正在清理用户日志文件..."
        if [[ -d "$HOME/Library/Logs" ]]; then
            local logs_dir="$HOME/Library/Logs"
            local logs_size
            logs_size=$(get_dir_size "$logs_dir")
            echo -e "  - 检测到用户日志目录，大小: ${YELLOW}$logs_size${NC}"
            read -r -p "  - 确认清理用户日志文件? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if find "$logs_dir" -mindepth 1 -maxdepth 2 -name "*.log" -not -path "*/Containers/*" -exec rm -f {} + 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理用户日志文件"
                else
                    echo -e "  ${RED}✗${NC} 清理用户日志文件时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过用户日志文件清理"
            fi
        fi
        
        # 清理自动保存信息
        echo -e "\\n正在清理自动保存文件..."
        if [[ -d "$HOME/Library/Autosave Information" ]]; then
            local autosave_dir="$HOME/Library/Autosave Information"
            local autosave_size
            autosave_size=$(get_dir_size "$autosave_dir")
            echo -e "  - 检测到自动保存目录，大小: ${YELLOW}$autosave_size${NC}"
            read -r -p "  - 确认清理自动保存文件? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$autosave_dir"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理自动保存文件"
                else
                    echo -e "  ${RED}✗${NC} 清理自动保存文件时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过自动保存文件清理"
            fi
        fi
        
        # 清理保存的应用状态
        echo -e "\\n正在清理保存的应用状态..."
        if [[ -d "$HOME/Library/Saved Application State" ]]; then
            local saved_state_dir="$HOME/Library/Saved Application State"
            local saved_state_size
            saved_state_size=$(get_dir_size "$saved_state_dir")
            echo -e "  - 检测到保存应用状态目录，大小: ${YELLOW}$saved_state_size${NC}"
            read -r -p "  - 确认清理保存的应用状态? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$saved_state_dir"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理保存的应用状态"
                else
                    echo -e "  ${RED}✗${NC} 清理保存的应用状态时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过保存应用状态清理"
            fi
        fi
        
        # 清理容器缓存（应用程序沙盒缓存）
        echo -e "\\n正在清理应用容器缓存..."
        if [[ -d "$HOME/Library/Containers" ]]; then
            local containers_dir="$HOME/Library/Containers"
            local containers_size
            containers_size=$(get_dir_size "$containers_dir")
            echo -e "  - 检测到应用容器目录，大小: ${YELLOW}$containers_size${NC}"
            read -r -p "  - 确认清理部分应用容器缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                # 只清理缓存文件，而不是整个应用数据
                if find "$containers_dir" -name "Cache.db" -exec rm -f {} + 2>/dev/null && 
                   find "$containers_dir" -name "Caches" -type d -exec rm -rf {} + 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理应用容器缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理应用容器缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过应用容器缓存清理"
            fi
        fi
        
        # 清理邮件缓存
        echo -e "\\n正在清理邮件缓存..."
        local mail_cache_dirs=("$HOME/Library/Mail" "$HOME/Library/Containers/com.apple.mail/Data/Library/Caches")
        for mail_cache_dir in "${mail_cache_dirs[@]}"; do
            if [[ -d "$mail_cache_dir" ]]; then
                local mail_cache_size
                mail_cache_size=$(get_dir_size "$mail_cache_dir")
                echo -e "  - 检测到邮件缓存目录: $mail_cache_dir, 大小: ${YELLOW}$mail_cache_size${NC}"
                read -r -p "  - 确认清理邮件缓存? [y/N] " response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    if find "$mail_cache_dir" -name "Cache" -type d -exec rm -rf {} + 2>/dev/null; then
                        echo -e "  ${GREEN}✓${NC} 已清理邮件缓存"
                    else
                        echo -e "  ${RED}✗${NC} 清理邮件缓存时出现错误"
                    fi
                else
                    echo -e "  ${YELLOW}-${NC} 已跳过邮件缓存清理"
                fi
                break  # 只处理找到的第一个邮件缓存目录
            fi
        done
        
        # 清理 QuickLook 缓存
        echo -e "\\n正在清理 QuickLook 缓存..."
        if [[ -d "$HOME/Library/Caches/com.apple.quicklook" ]]; then
            local quicklook_cache="$HOME/Library/Caches/com.apple.quicklook"
            local quicklook_size
            quicklook_size=$(get_dir_size "$quicklook_cache")
            echo -e "  - 检测到 QuickLook 缓存，大小: ${YELLOW}$quicklook_size${NC}"
            read -r -p "  - 确认清理 QuickLook 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo rm -rf "$quicklook_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 QuickLook 缓存"
                    # 重启 QuickLook 服务
                    sudo qlmanage -r 2>/dev/null
                    echo -e "  - 已重启 QuickLook 服务"
                else
                    echo -e "  ${RED}✗${NC} 清理 QuickLook 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 QuickLook 缓存清理"
            fi
        fi
        
        # 清理 Xcode 缓存（如果安装了开发工具）
        if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
            echo -e "\\n正在清理 Xcode 编译缓存..."
            local xcode_cache="$HOME/Library/Developer/Xcode/DerivedData"
            local xcode_cache_size
            xcode_cache_size=$(get_dir_size "$xcode_cache")
            echo -e "  - 检测到 Xcode 编译缓存，大小: ${YELLOW}$xcode_cache_size${NC}"
            read -r -p "  - 确认清理 Xcode 编译缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if rm -rf "$xcode_cache"/* 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Xcode 编译缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Xcode 编译缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Xcode 缓存清理"
            fi
        fi
    fi
}

# 清理 Linux 专用文件
cleanup_linux_specific() {
    if [[ "$OS_TYPE" == "Linux" ]]; then
        echo -e "\\n正在清理 Linux 专用缓存..."
        
        # 清理系统缓存目录
        if [[ -d "/var/cache" ]]; then
            echo -e "  - 检测到系统缓存目录 /var/cache"
            read -r -p "  - 确认清理系统缓存(/var/cache)? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo find /var/cache -mindepth 1 -maxdepth 1 -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理系统缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理系统缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过系统缓存清理"
            fi
        fi
        
        # 清理用户应用缓存
        if [[ -d "$HOME/.cache" ]]; then
            echo -e "\\n正在清理用户应用缓存 ($HOME/.cache)..."
            local cache_dir="$HOME/.cache"
            local size_before
            size_before=$(get_dir_size "$cache_dir")
            echo -e "  - 当前大小: ${YELLOW}$size_before${NC}"
            read -r -p "  - 确认清理用户应用缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if find "$cache_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
                    local size_after
                    size_after=$(get_dir_size "$cache_dir")
                    echo -e "  ${GREEN}✓${NC} 已清理用户应用缓存: $size_before -> $size_after"
                else
                    echo -e "  ${RED}✗${NC} 清理用户应用缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过用户应用缓存清理"
            fi
        else
            echo -e "  - 用户应用缓存目录不存在，跳过 ($HOME/.cache)"
        fi
        
        # 检测并清理不同 Linux 发行版的包管理器缓存
        case "$DISTRO" in
            ubuntu|debian)
                # 清理 APT 缓存 (Ubuntu/Debian)
                if command -v apt &> /dev/null || command -v apt-get &> /dev/null; then
                    echo -e "\\n检测到 APT 包管理器"
                    read -r -p "  - 确认清理 APT 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if sudo apt-get clean 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 APT 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 APT 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 APT 缓存清理"
                    fi
                fi
                ;;
            centos|rhel|fedora)
                # 清理 YUM/DNF 缓存 (CentOS/RHEL/Fedora)
                if command -v yum &> /dev/null || command -v dnf &> /dev/null; then
                    echo -e "\\n检测到 YUM/DNF 包管理器"
                    read -r -p "  - 确认清理 YUM/DNF 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if command -v dnf &> /dev/null; then
                            if sudo dnf clean all 2>/dev/null; then
                                echo -e "  ${GREEN}✓${NC} 已清理 DNF 缓存"
                            else
                                echo -e "  ${RED}✗${NC} 清理 DNF 缓存时出现错误"
                            fi
                        elif command -v yum &> /dev/null; then
                            if sudo yum clean all 2>/dev/null; then
                                echo -e "  ${GREEN}✓${NC} 已清理 YUM 缓存"
                            else
                                echo -e "  ${RED}✗${NC} 清理 YUM 缓存时出现错误"
                            fi
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 YUM/DNF 缓存清理"
                    fi
                fi
                ;;
            arch|manjaro)
                # 清理 Pacman 缓存 (Arch Linux/Manjaro)
                if command -v pacman &> /dev/null; then
                    echo -e "\\n检测到 Pacman 包管理器"
                    read -r -p "  - 确认清理 Pacman 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if sudo pacman -Sc 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 Pacman 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 Pacman 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 Pacman 缓存清理"
                    fi
                fi
                ;;
            opensuse)
                # 清理 Zypper 缓存 (openSUSE)
                if command -v zypper &> /dev/null; then
                    echo -e "\\n检测到 Zypper 包管理器"
                    read -r -p "  - 确认清理 Zypper 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if sudo zypper clean 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 Zypper 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 Zypper 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 Zypper 缓存清理"
                    fi
                fi
                ;;
            *)
                # 检查是否有其他包管理器
                if command -v apt &> /dev/null || command -v apt-get &> /dev/null; then
                    echo -e "\\n检测到 APT 包管理器"
                    read -r -p "  - 确认清理 APT 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if sudo apt-get clean 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 APT 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 APT 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 APT 缓存清理"
                    fi
                elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
                    echo -e "\\n检测到 YUM/DNF 包管理器"
                    read -r -p "  - 确认清理 YUM/DNF 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if command -v dnf &> /dev/null; then
                            if sudo dnf clean all 2>/dev/null; then
                                echo -e "  ${GREEN}✓${NC} 已清理 DNF 缓存"
                            else
                                echo -e "  ${RED}✗${NC} 清理 DNF 缓存时出现错误"
                            fi
                        elif command -v yum &> /dev/null; then
                            if sudo yum clean all 2>/dev/null; then
                                echo -e "  ${GREEN}✓${NC} 已清理 YUM 缓存"
                            else
                                echo -e "  ${RED}✗${NC} 清理 YUM 缓存时出现错误"
                            fi
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 YUM/DNF 缓存清理"
                    fi
                elif command -v pacman &> /dev/null; then
                    echo -e "\\n检测到 Pacman 包管理器"
                    read -r -p "  - 确认清理 Pacman 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if sudo pacman -Sc 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 Pacman 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 Pacman 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 Pacman 缓存清理"
                    fi
                elif command -v zypper &> /dev/null; then
                    echo -e "\\n检测到 Zypper 包管理器"
                    read -r -p "  - 确认清理 Zypper 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if sudo zypper clean 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 Zypper 缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理 Zypper 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 Zypper 缓存清理"
                    fi
                fi
                ;;
        esac
        
        # 清理 Snap 包缓存（如果存在）
        if command -v snap &> /dev/null; then
            echo -e "\\n检测到 Snap 包管理器"
            read -r -p "  - 确认清理 Snap 包缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if sudo snap remove --purge $(snap list --all | grep -E "\s[0-9]+\s+" | awk '{print $1 "_" $3}') 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Snap 已移除包的缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 Snap 包缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Snap 包缓存清理"
            fi
        fi
        
        # 清理 Flatpak 缓存
        if command -v flatpak &> /dev/null; then
            echo -e "\\n检测到 Flatpak 包管理器"
            read -r -p "  - 确认清理 Flatpak 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if flatpak uninstall --unused 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 Flatpak 未使用的运行时"
                else
                    echo -e "  ${RED}✗${NC} 清理 Flatpak 未使用的运行时时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 Flatpak 缓存清理"
            fi
        fi
    fi
}

# 清理 Homebrew 缓存（在 Linux 和 macOS 上都可用）
cleanup_homebrew() {
    if command -v brew &> /dev/null; then
        echo -e "  - ${GREEN}检测到 Homebrew${NC}，扫描缓存..."
        # 显示将要清理的内容但不执行，除非确认
        local cache_size
        cache_size=$(get_dir_size "$(brew --cache 2>/dev/null)")
        echo -e "  - 当前 Homebrew 缓存大小: ${YELLOW}$cache_size${NC}"
        
        read -r -p "  - 确认清理 Homebrew 缓存? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            echo -e "  - 正在清理 Homebrew 缓存..."
            if brew cleanup --prune=all 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} 已清理 Homebrew 缓存"
            else
                echo -e "  ${RED}✗${NC} 清理 Homebrew 缓存时出现错误"
            fi
        else
            echo -e "  ${YELLOW}-${NC} 已跳过 Homebrew 缓存清理"
        fi
    else
        echo -e "  - 未检测到 Homebrew，跳过"
    fi
}

# 清理 NPM 缓存
cleanup_npm() {
    if command -v npm &> /dev/null; then
        echo -e "  - ${GREEN}检测到 NPM${NC}，扫描缓存..."
        local cache_dir
        cache_dir=$(npm config get cache 2>/dev/null)
        if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
            local cache_size
            cache_size=$(get_dir_size "$cache_dir")
            echo -e "  - 当前 NPM 缓存大小: ${YELLOW}$cache_size${NC}"
            
            read -r -p "  - 确认清理 NPM 缓存? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                if npm cache clean --force 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已清理 NPM 缓存"
                else
                    echo -e "  ${RED}✗${NC} 清理 NPM 缓存时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 NPM 缓存清理"
            fi
        else
            echo -e "  - NPM 缓存目录不存在或未配置"
        fi
    else
        echo -e "  - 未检测到 NPM，跳过"
    fi
}

# 清理 Docker 缓存
cleanup_docker() {
    if command -v docker &> /dev/null; then
        echo -e "  - ${GREEN}检测到 Docker${NC}"
        read -r -p "  - 确认清理 Docker 缓存（镜像、容器、网络）? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            # 获取当前 Docker 使用的空间
            if docker system df > /dev/null 2>&1; then
                echo -e "  - Docker 系统信息:"
                docker system df
            fi
            
            if docker system prune -a --volumes --force 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} 已清理 Docker 缓存"
            else
                echo -e "  ${RED}✗${NC} 清理 Docker 缓存时出现错误"
            fi
        else
            echo -e "  ${YELLOW}-${NC} 已跳过 Docker 缓存清理"
        fi
    else
        echo -e "  - 未检测到 Docker，跳过"
    fi
}

# 根据操作系统显示菜单选项
show_menu() {
    echo -e "\\n${YELLOW}请选择要清理的项目 (输入数字):${NC}"
    echo "1. 清理用户缓存 ($HOME/Library/Caches - macOS / $HOME/.cache - Linux)"
    echo "2. 清理临时文件 (/tmp 和用户缓存)"
    echo "3. 清理下载文件夹 ($HOME/Downloads)"
    if [[ "$OS_TYPE" == "macOS" ]]; then
        echo "4. 清理 Safari 下载历史"
        echo "5. 清理系统诊断报告 (/Library/Logs/DiagnosticReports)"
        echo "6. 清理软件更新缓存 (/Library/Caches/com.apple.SoftwareUpdate)"
        echo "7. 清理 Homebrew 缓存"
        echo "8. 清理其他缓存 (NPM, Docker)"
        echo "9. 清理日志和自动保存文件"
        echo "10. 清理应用容器缓存"
        echo "11. 清理邮件和 QuickLook 缓存"
        echo "12. 清理所有 (以上所有 macOS 选项)"
        echo "13. 退出"
    else
        echo "4. 清理 Linux 系统缓存 (/var/cache, $HOME/.cache)"
        echo "5. 清理包管理器缓存 (APT/YUM/DNF/Pacman/Zypper/Snap/Flatpak)"
        echo "6. 清理 Homebrew 缓存"
        echo "7. 清理其他缓存 (NPM, Docker)"
        echo "8. 清理所有 (以上所有 Linux 选项)"
        echo "9. 退出"
    fi
}

# 执行清理操作的函数
execute_cleanup() {
    local choice="$1"
    case $choice in
        1)
            echo -e "\\n正在清理用户缓存..."
            if [[ "$OS_TYPE" == "macOS" ]]; then
                cleanup_user_cache "$HOME/Library/Caches" "用户缓存"
            else
                cleanup_user_cache "$HOME/.cache" "用户应用缓存"
            fi
            ;;
        
        2)
            echo -e "\\n正在清理临时文件 (/tmp)..."
            cleanup "/tmp" "系统临时文件"
            
            echo -e "\\n正在清理用户缓存..."
            if [[ "$OS_TYPE" == "macOS" ]]; then
                cleanup_user_cache "$HOME/Library/Caches" "用户缓存"
            else
                cleanup_user_cache "$HOME/.cache" "用户应用缓存"
            fi
            ;;
        
        3)
            echo -e "\\n正在清理下载文件夹 ($HOME/Downloads)..."
            cleanup_downloads
            ;;
        
        4)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在清理 Safari 下载历史..."
                local safari_file="$HOME/Library/Safari/Downloads.plist"
                if [[ -f "$safari_file" ]]; then
                    echo -e "  - 找到 Safari 下载历史: $safari_file"
                    read -r -p "  - 确认清理 Safari 下载历史? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if rm -f "$safari_file" 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 Safari 下载历史"
                        else
                            echo -e "  ${RED}✗${NC} 清理 Safari 下载历史时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 Safari 下载历史清理"
                    fi
                else
                    echo -e "  - Safari 下载历史文件不存在，跳过"
                fi
            else
                echo -e "\\n正在清理 Linux 系统缓存..."
                cleanup_linux_specific
            fi
            ;;
        
        5)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在清理系统诊断报告 (/Library/Logs/DiagnosticReports)..."
                cleanup "/Library/Logs/DiagnosticReports" "系统诊断报告"
            else
                echo -e "\\n正在清理包管理器缓存..."
                cleanup_linux_specific
            fi
            ;;
        
        6)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在清理软件更新缓存 (/Library/Caches/com.apple.SoftwareUpdate)..."
                if [[ -d "/Library/Caches/com.apple.SoftwareUpdate" ]]; then
                    echo -e "  - 检测到软件更新缓存，需要管理员权限"
                    read -r -p "  - 确认清理软件更新缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if sudo rm -rf /Library/Caches/com.apple.SoftwareUpdate/* 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理软件更新缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理软件更新缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过软件更新缓存清理"
                    fi
                else
                    echo -e "  - 软件更新缓存目录不存在，跳过"
                fi
            else
                echo -e "\\n正在清理 Homebrew 缓存..."
                cleanup_homebrew
            fi
            ;;
        
        7)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在清理 Homebrew 缓存..."
                cleanup_homebrew
            else
                echo -e "\\n正在清理其他缓存..."
                cleanup_npm
                cleanup_docker
            fi
            ;;
        
        8)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在清理其他缓存..."
                cleanup_npm
                cleanup_docker
            else
                echo -e "\\n正在执行全部 Linux 清理..."
                cleanup_linux_specific
            fi
            ;;
        
        9)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在清理日志和自动保存文件..."
                # 清理用户日志文件
                if [[ -d "$HOME/Library/Logs" ]]; then
                    local logs_dir="$HOME/Library/Logs"
                    local logs_size
                    logs_size=$(get_dir_size "$logs_dir")
                    echo -e "  - 检测到用户日志目录，大小: ${YELLOW}$logs_size${NC}"
                    read -r -p "  - 确认清理用户日志文件? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if find "$logs_dir" -mindepth 1 -maxdepth 2 -name "*.log" -not -path "*/Containers/*" -exec rm -f {} + 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理用户日志文件"
                        else
                            echo -e "  ${RED}✗${NC} 清理用户日志文件时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过用户日志文件清理"
                    fi
                fi
                
                # 清理自动保存信息
                echo -e "\\n正在清理自动保存文件..."
                if [[ -d "$HOME/Library/Autosave Information" ]]; then
                    local autosave_dir="$HOME/Library/Autosave Information"
                    local autosave_size
                    autosave_size=$(get_dir_size "$autosave_dir")
                    echo -e "  - 检测到自动保存目录，大小: ${YELLOW}$autosave_size${NC}"
                    read -r -p "  - 确认清理自动保存文件? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if rm -rf "$autosave_dir"/* 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理自动保存文件"
                        else
                            echo -e "  ${RED}✗${NC} 清理自动保存文件时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过自动保存文件清理"
                    fi
                fi
                
                # 清理保存的应用状态
                echo -e "\\n正在清理保存的应用状态..."
                if [[ -d "$HOME/Library/Saved Application State" ]]; then
                    local saved_state_dir="$HOME/Library/Saved Application State"
                    local saved_state_size
                    saved_state_size=$(get_dir_size "$saved_state_dir")
                    echo -e "  - 检测到保存应用状态目录，大小: ${YELLOW}$saved_state_size${NC}"
                    read -r -p "  - 确认清理保存的应用状态? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if rm -rf "$saved_state_dir"/* 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理保存的应用状态"
                        else
                            echo -e "  ${RED}✗${NC} 清理保存的应用状态时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过保存应用状态清理"
                    fi
                fi
            else
                # Linux 系统的退出选项
                echo -e "${GREEN}已退出清理工具${NC}"
                return 1
            fi
            ;;
        
        10)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在清理应用容器缓存..."
                # 清理容器缓存（应用程序沙盒缓存）
                if [[ -d "$HOME/Library/Containers" ]]; then
                    local containers_dir="$HOME/Library/Containers"
                    local containers_size
                    containers_size=$(get_dir_size "$containers_dir")
                    echo -e "  - 检测到应用容器目录，大小: ${YELLOW}$containers_size${NC}"
                    read -r -p "  - 确认清理部分应用容器缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        # 只清理缓存文件，而不是整个应用数据
                        if find "$containers_dir" -name "Cache.db" -exec rm -f {} + 2>/dev/null && 
                           find "$containers_dir" -name "Caches" -type d -exec rm -rf {} + 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理应用容器缓存"
                        else
                            echo -e "  ${RED}✗${NC} 清理应用容器缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过应用容器缓存清理"
                    fi
                fi
            else
                # Linux 系统没有此选项
                echo -e "${RED}无效选择，请输入正确的数字${NC}"
                return 0
            fi
            ;;
        
        11)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在清理邮件和 QuickLook 缓存..."
                # 清理邮件缓存
                local mail_cache_dirs=("$HOME/Library/Mail" "$HOME/Library/Containers/com.apple.mail/Data/Library/Caches")
                for mail_cache_dir in "${mail_cache_dirs[@]}"; do
                    if [[ -d "$mail_cache_dir" ]]; then
                        local mail_cache_size
                        mail_cache_size=$(get_dir_size "$mail_cache_dir")
                        echo -e "  - 检测到邮件缓存目录: $mail_cache_dir, 大小: ${YELLOW}$mail_cache_size${NC}"
                        read -r -p "  - 确认清理邮件缓存? [y/N] " response
                        if [[ "$response" =~ ^[Yy]$ ]]; then
                            if find "$mail_cache_dir" -name "Cache" -type d -exec rm -rf {} + 2>/dev/null; then
                                echo -e "  ${GREEN}✓${NC} 已清理邮件缓存"
                            else
                                echo -e "  ${RED}✗${NC} 清理邮件缓存时出现错误"
                            fi
                        else
                            echo -e "  ${YELLOW}-${NC} 已跳过邮件缓存清理"
                        fi
                        break  # 只处理找到的第一个邮件缓存目录
                    fi
                done
                
                # 清理 QuickLook 缓存
                echo -e "\\n正在清理 QuickLook 缓存..."
                if [[ -d "$HOME/Library/Caches/com.apple.quicklook" ]]; then
                    local quicklook_cache="$HOME/Library/Caches/com.apple.quicklook"
                    local quicklook_size
                    quicklook_size=$(get_dir_size "$quicklook_cache")
                    echo -e "  - 检测到 QuickLook 缓存，大小: ${YELLOW}$quicklook_size${NC}"
                    read -r -p "  - 确认清理 QuickLook 缓存? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if sudo rm -rf "$quicklook_cache"/* 2>/dev/null; then
                            echo -e "  ${GREEN}✓${NC} 已清理 QuickLook 缓存"
                            # 重启 QuickLook 服务
                            sudo qlmanage -r 2>/dev/null
                            echo -e "  - 已重启 QuickLook 服务"
                        else
                            echo -e "  ${RED}✗${NC} 清理 QuickLook 缓存时出现错误"
                        fi
                    else
                        echo -e "  ${YELLOW}-${NC} 已跳过 QuickLook 缓存清理"
                    fi
                fi
            else
                # Linux 系统没有此选项
                echo -e "${RED}无效选择，请输入正确的数字${NC}"
                return 0
            fi
            ;;
        
        12)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在执行全部 macOS 清理..."
                cleanup_macos_specific
            else
                # Linux 系统没有此选项
                echo -e "${RED}无效选择，请输入正确的数字${NC}"
                return 0
            fi
            ;;
        
        13)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "${GREEN}已退出清理工具${NC}"
                return 1
            else
                # Linux 系统没有此选项
                echo -e "${RED}无效选择，请输入正确的数字${NC}"
                return 0
            fi
            ;;
        
        *)
            echo -e "${RED}无效选择，请输入正确的数字${NC}"
            return 0
            ;;
    esac
    
    return 0
}

# 主循环，持续显示菜单直到用户选择退出
while true; do
    show_menu
    
    # 读取用户选择
    if [[ "$OS_TYPE" == "macOS" ]]; then
        read -p "请选择 (1-13): " choice
    else
        read -p "请选择 (1-9): " choice
    fi

    # 执行清理操作
    execute_cleanup "$choice"
    local exit_code=$?
    
    # 检查返回值，如果为1则退出循环
    if [[ $exit_code -eq 1 ]]; then
        break
    elif [[ $exit_code -ne 0 ]]; then
        # 如果不是1也不是0，说明是无效选择，继续下一次循环
        continue
    fi

    # 显示清理后的磁盘使用情况
    show_disk_usage

    echo -e "\\n${GREEN}本次清理完成！${NC}"

    # 显示日志和清理报告直接在控制台
    echo -e "\\n${YELLOW}=================================${NC}"
    echo -e "${YELLOW}清理日志:${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 执行操作: $choice"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 操作完成"
    
    echo -e "\\n${YELLOW}=================================${NC}"
    echo -e "${YELLOW}清理报告:${NC}"
    echo "本次执行的操作:"
    case $choice in
        1) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理用户缓存 ($HOME/Library/Caches)"
            else
                echo "- 清理用户应用缓存 ($HOME/.cache)"
            fi
            ;;
        2) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理临时文件和用户缓存 (macOS)"
            else
                echo "- 清理临时文件和用户应用缓存 (Linux)"
            fi
            ;;
        3) echo "- 清理下载文件夹" ;;
        4) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理 Safari 下载历史"
            else
                echo "- 清理 Linux 系统缓存"
            fi
            ;;
        5) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理系统诊断报告"
            else
                echo "- 清理包管理器缓存"
            fi
            ;;
        6) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理软件更新缓存"
            else
                echo "- 清理 Homebrew 缓存"
            fi
            ;;
        7) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理 Homebrew 缓存"
            else
                echo "- 清理其他缓存 (NPM, Docker)"
            fi
            ;;
        8) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理其他缓存 (NPM, Docker)"
            else
                echo "- 执行 Linux 全面清理"
            fi
            ;;
        9) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理日志和自动保存文件"
            else
                echo "- 执行 Linux 全面清理"
            fi
            ;;
        10) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理应用容器缓存"
            else
                echo "无效选项"
            fi
            ;;
        11) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 清理邮件和 QuickLook 缓存"
            else
                echo "无效选项"
            fi
            ;;
        12) 
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo "- 执行 macOS 全面清理"
            else
                echo "- 执行 Linux 全面清理"
            fi
            ;;
    esac
    echo ""
    df -h / | tail -n +2
    
    echo "注意：此脚本不会删除系统关键文件，仅清理可安全删除的缓存和临时文件。"
done

echo -e "\\n${GREEN}感谢使用${SCRIPT_NAME}！${NC}"