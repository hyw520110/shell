#!/bin/bash
# ==============================================================================
# Trivy 一键脚本 - 安装/配置/执行
# 用法: ./trivy.sh <命令> [参数]
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
TRIVY_VERSION="0.59.0"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/trivy_scan}"

# 显示帮助
show_help() {
    echo -e "${BLUE}Trivy 一键脚本 - 容器安全扫描${NC}"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "安装命令:"
    echo "  install             安装 Trivy"
    echo "  update              更新漏洞数据库"
    echo ""
    echo "扫描命令:"
    echo "  image <镜像>        扫描容器镜像"
    echo "  fs <路径>           扫描文件系统/代码"
    echo "  config <文件>       扫描配置文件 (IaC)"
    echo "  repo <URL>          扫描代码仓库"
    echo "  k8s                 扫描 Kubernetes 集群"
    echo ""
    echo "选项:"
    echo "  --critical          仅显示严重漏洞"
    echo "  --high              显示高危及以上漏洞"
    echo "  -o <文件>           输出文件"
    echo ""
    echo "示例:"
    echo "  $0 install"
    echo "  $0 image nginx:latest"
    echo "  $0 fs . --high"
    echo "  $0 config Dockerfile"
}

# 检测系统
detect_os() {
    OS_TYPE=$(uname -s)
    ARCH=$(uname -m)
}

# 获取架构
get_arch() {
    case "$ARCH" in
        x86_64|amd64) echo "64bit" ;;
        aarch64|arm64) echo "ARM64" ;;
        *) echo -e "${RED}[错误] 不支持架构: $ARCH${NC}"; exit 1 ;;
    esac
}

# 检查是否安装
check_installed() {
    command -v trivy &> /dev/null
}

# 包管理器安装
install_package() {
    case "$OS_TYPE" in
        Linux)
            if command -v apt-get &> /dev/null; then
                sudo apt-get install -y wget apt-transport-https gnupg lsb-release
                wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
                echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee -a /etc/apt/sources.list.d/trivy.list
                sudo apt-get update && sudo apt-get install -y trivy
                return 0
            elif command -v yum &> /dev/null; then
                sudo yum install -y wget
                cat <<EOF | sudo tee /etc/yum.repos.d/trivy.repo
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/\$releasever/\$basearch/
enabled=1
gpgcheck=0
EOF
                sudo yum install -y trivy
                return 0
            fi
            ;;
        Darwin)
            if command -v brew &> /dev/null; then
                brew install trivy
                return 0
            fi
            ;;
    esac
    return 1
}

# 二进制安装
install_binary() {
    local arch=$(get_arch)
    local os_lower=$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')
    local filename="trivy_${TRIVY_VERSION}_${os_lower}-${arch}.tar.gz"
    local url="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${filename}"
    local tar_file="$DOWNLOAD_DIR/$filename"
    
    mkdir -p "$DOWNLOAD_DIR"
    
    echo -e "${GREEN}[信息] 下载 Trivy...${NC}"
    wget -O "$tar_file" "$url"
    
    local tmp_dir=$(mktemp -d)
    tar -xzf "$tar_file" -C "$tmp_dir"
    
    if [ -w "$INSTALL_DIR" ]; then
        mv "$tmp_dir/trivy" "$INSTALL_DIR/"
    else
        sudo mv "$tmp_dir/trivy" "$INSTALL_DIR/"
    fi
    
    chmod +x "$INSTALL_DIR/trivy"
    rm -rf "$tmp_dir"
}

# 安装
cmd_install() {
    if check_installed; then
        echo -e "${GREEN}[信息] Trivy 已安装: $(trivy --version | head -1)${NC}"
        return 0
    fi
    
    echo -e "${GREEN}[信息] 开始安装 Trivy ${TRIVY_VERSION}...${NC}"
    detect_os
    
    if ! install_package; then
        install_binary
    fi
    
    echo -e "${GREEN}[完成] Trivy 安装成功${NC}"
    trivy --version | head -1
}

# 更新数据库
cmd_update() {
    check_installed || { echo -e "${RED}[错误] Trivy 未安装${NC}"; exit 1; }
    echo -e "${GREEN}[信息] 更新漏洞数据库...${NC}"
    trivy image --download-db-only
    echo -e "${GREEN}[完成] 数据库已更新${NC}"
}

# 扫描函数
do_scan() {
    check_installed || { echo -e "${RED}[错误] Trivy 未安装，请先执行: $0 install${NC}"; exit 1; }
    
    local scan_type="$1"
    local target="$2"
    
    mkdir -p "$OUTPUT_DIR"
    local output_file="${OUTPUT_FILE:-$OUTPUT_DIR/${scan_type}_$(date +%Y%m%d-%H%M%S).json}"
    
    local trivy_opts="--quiet --format json --output $output_file"
    
    if [ "$SEVERITY" = "critical" ]; then
        trivy_opts="$trivy_opts --severity CRITICAL"
    elif [ "$SEVERITY" = "high" ]; then
        trivy_opts="$trivy_opts --severity CRITICAL,HIGH"
    fi
    
    echo -e "${GREEN}[信息] ${scan_type} 扫描: $target${NC}"
    trivy "$scan_type" $trivy_opts "$target"
    
    # 显示摘要
    echo ""
    echo -e "${GREEN}[结果]${NC}"
    if command -v jq &> /dev/null; then
        jq -r '.Results[]?.Vulnerabilities[]? | "[\(.Severity)] \(.PkgName): \(.VulnerabilityID) - \(.Title)"' "$output_file" 2>/dev/null || echo "无漏洞"
    else
        echo "漏洞详情已保存到: $output_file"
        echo "安装 jq 可查看详细结果: brew install jq 或 apt install jq"
    fi
    
    echo ""
    echo -e "${GREEN}[完成] 报告: $output_file${NC}"
}

# 主函数
main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi
    
    local cmd="$1"
    shift
    SEVERITY=""
    OUTPUT_FILE=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --critical) SEVERITY="critical"; shift ;;
            --high) SEVERITY="high"; shift ;;
            -o) OUTPUT_FILE="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) break ;;
        esac
    done
    
    case "$cmd" in
        install) cmd_install ;;
        update) cmd_update ;;
        image|fs|config|repo|k8s)
            [ -z "${1:-}" ] && { echo -e "${RED}[错误] 请指定目标${NC}"; exit 1; }
            do_scan "$cmd" "$1"
            ;;
        -h|--help) show_help ;;
        *)
            echo -e "${RED}[错误] 未知命令: $cmd${NC}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
