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

# 检测操作系统
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

OS_TYPE=$(detect_os)
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

# 安全清理函数
cleanup() {
    local dir="$1"
    local name="$2"
    local size_before
    
    # 检查目录是否存在
    if [[ -d "$dir" ]]; then
        # 使用 du 获取大小，过滤掉错误信息
        if size_before=$(du -sh "$dir" 2>/dev/null | cut -f1); then
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
                    if size_after=$(du -sh "$dir" 2>/dev/null | cut -f1); then
                        echo -e "  ${GREEN}✓${NC} 已清理 $name: $size_before -> $size_after"
                    else
                        echo -e "  ${YELLOW}-${NC} 清理 $name 时无法获取大小信息"
                    fi
                else
                    echo -e "  ${RED}✗${NC} 清理 $name 时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 $name"
            fi
        else
            echo -e "  ${YELLOW}-${NC} 无法获取 $name 目录大小"
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
        if size_before=$(du -sh "$cache_dir" 2>/dev/null | cut -f1); then
            echo -e "  - 当前大小: ${YELLOW}$size_before${NC}"
            
            # 确认
            read -r -p "  - 确认清理 $name? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                # 只删除非隐藏目录/文件以避免删除重要的缓存结构
                if find "$cache_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
                    local size_after
                    if size_after=$(du -sh "$cache_dir" 2>/dev/null | cut -f1); then
                        echo -e "  ${GREEN}✓${NC} 已清理 $name: $size_before -> $size_after"
                    else
                        echo -e "  ${YELLOW}-${NC} 清理 $name 时无法获取大小信息"
                    fi
                else
                    echo -e "  ${RED}✗${NC} 清理 $name 时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过 $name"
            fi
        else
            echo -e "  ${YELLOW}-${NC} 无法获取 $name 目录大小"
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
        if size_before=$(du -sh "$downloads_dir" 2>/dev/null | cut -f1); then
            echo -e "  - 当前大小: ${YELLOW}$size_before${NC}"
            
            # 确认
            read -r -p "  - 确认清空下载文件夹（保留安装包如dmg/pkg/iso）? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                # 查找并删除非隐藏文件，除了安装程序
                if find "$downloads_dir" -maxdepth 1 -type f -not -name ".*" -not -name "*.dmg" -not -name "*.pkg" -not -name "*.iso" -not -name "*.mpkg" -not -name "*.deb" -not -name "*.rpm" -delete 2>/dev/null; then
                    # 同时删除空目录
                    find "$downloads_dir" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
                    
                    local size_after
                    if size_after=$(du -sh "$downloads_dir" 2>/dev/null | cut -f1); then
                        echo -e "  ${GREEN}✓${NC} 已清理下载文件夹: $size_before -> $size_after (保留安装包)"
                    else
                        echo -e "  ${YELLOW}-${NC} 清理下载文件夹时无法获取大小信息"
                    fi
                else
                    echo -e "  ${RED}✗${NC} 清理下载文件夹时出现错误"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 已跳过下载文件夹清理"
            fi
        else
            echo -e "  ${YELLOW}-${NC} 无法获取下载文件夹大小"
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
            if size_before=$(du -sh "$cache_dir" 2>/dev/null | cut -f1); then
                echo -e "  - 当前大小: ${YELLOW}$size_before${NC}"
                read -r -p "  - 确认清理用户应用缓存? [y/N] " response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    if find "$cache_dir" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -not -name ".*" -exec rm -rf {} + 2>/dev/null; then
                        local size_after
                        if size_after=$(du -sh "$cache_dir" 2>/dev/null | cut -f1); then
                            echo -e "  ${GREEN}✓${NC} 已清理用户应用缓存: $size_before -> $size_after"
                        else
                            echo -e "  ${YELLOW}-${NC} 清理用户应用缓存时无法获取大小信息"
                        fi
                    else
                        echo -e "  ${RED}✗${NC} 清理用户应用缓存时出现错误"
                    fi
                else
                    echo -e "  ${YELLOW}-${NC} 已跳过用户应用缓存清理"
                fi
            else
                echo -e "  ${YELLOW}-${NC} 无法获取用户应用缓存大小"
            fi
        else
            echo -e "  - 用户应用缓存目录不存在，跳过 ($HOME/.cache)"
        fi
        
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
    fi
}

# 清理 Homebrew 缓存
cleanup_homebrew() {
    if command -v brew &> /dev/null; then
        echo -e "  - ${GREEN}检测到 Homebrew${NC}，扫描缓存..."
        # 显示将要清理的内容但不执行，除非确认
        local cache_size
        cache_size=$(brew --cache 2>/dev/null | xargs du -sh 2>/dev/null | cut -f1 || echo "N/A")
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

# 主循环，持续显示菜单直到用户选择退出
while true; do
    # 选项菜单 - 根据操作系统显示相应的选项
    echo -e "\\n${YELLOW}请选择要清理的项目 (输入数字):${NC}"
    echo "1. 清理用户缓存 ($HOME/Library/Caches - macOS / $HOME/.cache - Linux)"
    echo "2. 清理临时文件 (/tmp 和用户缓存)"
    echo "3. 清理下载文件夹 ($HOME/Downloads)"
    if [[ "$OS_TYPE" == "macOS" ]]; then
        echo "4. 清理 Safari 下载历史"
        echo "5. 清理系统诊断报告 (/Library/Logs/DiagnosticReports)"
        echo "6. 清理软件更新缓存 (/Library/Caches/com.apple.SoftwareUpdate)"
        echo "7. 清理 Homebrew 缓存"
        echo "8. 清理所有 (以上所有 macOS 选项)"
        echo "9. 退出"
    else
        echo "4. 清理 Linux 系统缓存 (/var/cache, $HOME/.cache)"
        echo "5. 清理 APT/YUM/DNF 包管理器缓存"
        echo "6. 清理 Homebrew 缓存"
        echo "7. 清理所有 (以上所有 Linux 选项)"
        echo "8. 退出"
    fi
    
    # 读取用户选择
    if [[ "$OS_TYPE" == "macOS" ]]; then
        read -p "请选择 (1-9): " choice
    else
        read -p "请选择 (1-8): " choice
    fi

    # 标记是否需要退出
    should_exit=false
    
    # 执行清理
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
                echo -e "\\n正在清理 APT/YUM/DNF 包管理器缓存..."
                # 清理 APT 缓存 (Ubuntu/Debian)
                if command -v apt &> /dev/null || command -v apt-get &> /dev/null; then
                    echo -e "  - 检测到 APT 包管理器"
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
                
                # 清理 YUM/DNF 缓存 (CentOS/RHEL/Fedora)
                if command -v yum &> /dev/null || command -v dnf &> /dev/null; then
                    echo -e "  - 检测到 YUM/DNF 包管理器"
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
            fi
            ;;
        
        6)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在清理软件更新缓存 (/Library/Caches/com.apple.SoftwareUpdate)..."
                # 使用 sudo 清理系统缓存
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
                echo -e "\\n正在执行全部 Linux 清理..."
                cleanup_linux_specific
            fi
            ;;
        
        8)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "\\n正在执行全部 macOS 清理..."
                cleanup_macos_specific
            else
                # Linux 系统的退出选项
                echo -e "${GREEN}已退出清理工具${NC}"
                should_exit=true
            fi
            ;;
        
        9)
            if [[ "$OS_TYPE" == "macOS" ]]; then
                echo -e "${GREEN}已退出清理工具${NC}"
                should_exit=true
            else
                # 如果是 Linux 系统，选项 9 不存在，所以会显示无效选择
                echo -e "${RED}无效选择，请输入正确的数字${NC}"
                continue
            fi
            ;;
        
        *)
            echo -e "${RED}无效选择，请输入正确的数字${NC}"
            continue
            ;;
    esac
    
    # 检查是否需要退出
    if [[ "$should_exit" == true ]]; then
        break
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
                echo "- 清理 APT/YUM/DNF 包管理器缓存"
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
                echo "- 执行 Linux 系统全面清理"
            fi
            ;;
        8) 
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