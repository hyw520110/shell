#!/bin/bash
# ==============================================================================
# OpenVAS 一键脚本 - 安装/配置/扫描
# 用法: ./openvas.sh <命令> [参数]
# 注意: 资源消耗较大，建议至少 4GB 内存
# ==============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 显示帮助
show_help() {
    echo -e "${BLUE}OpenVAS/GVM 一键脚本 - 企业级漏洞扫描${NC}"
    echo ""
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  install             安装 OpenVAS (交互式)"
    echo "  start               启动服务"
    echo "  stop                停止服务"
    echo "  status              查看状态"
    echo "  update              更新漏洞库"
    echo ""
    echo "安装方式:"
    echo "  1) Docker (推荐)"
    echo "  2) 包管理器 (Ubuntu)"
    echo ""
    echo "访问地址: https://localhost:9392"
    echo "默认账号: admin / admin"
}

# 检查是否安装
check_installed() {
    command -v gvm &> /dev/null || command -v openvas &> /dev/null || docker ps | grep -q openvas
}

# Docker 安装
install_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}[错误] 请先安装 Docker${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}[信息] 使用 Docker 安装 OpenVAS...${NC}"
    
    mkdir -p ~/openvas/data
    
    docker run -d \
        --name openvas \
        -p 9392:9392 \
        -v ~/openvas/data:/data \
        --restart unless-stopped \
        mikesplain/openvas
    
    echo -e "${GREEN}[完成] OpenVAS 容器已启动${NC}"
    echo -e "${GREEN}访问地址: https://localhost:9392${NC}"
    echo -e "${GREEN}默认账号: admin / admin${NC}"
}

# 包管理器安装
install_package() {
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y software-properties-common
        sudo add-apt-repository -y ppa:mrazavi/gvm
        sudo apt-get update
        sudo apt-get install -y gvm
        sudo gvm-setup
        return 0
    fi
    return 1
}

# 安装
cmd_install() {
    if check_installed; then
        echo -e "${GREEN}[信息] OpenVAS 已安装${NC}"
        return 0
    fi
    
    # 检查内存
    if [ "$(uname -s)" = "Linux" ]; then
        local mem=$(free -m | awk '/^Mem:/{print $2}')
        if [ "$mem" -lt 4000 ]; then
            echo -e "${YELLOW}[警告] 建议至少 4GB 内存，当前: ${mem}MB${NC}"
        fi
    fi
    
    echo -e "${GREEN}[信息] 选择安装方式:${NC}"
    echo "  1) Docker (推荐)"
    echo "  2) 包管理器 (仅 Ubuntu)"
    read -p "请选择 [1-2]: " choice
    
    case $choice in
        1) install_docker ;;
        2) install_package || { echo -e "${RED}[错误] 包管理器安装失败${NC}"; exit 1; } ;;
        *) echo -e "${RED}[错误] 无效选择${NC}"; exit 1 ;;
    esac
}

# 启动
cmd_start() {
    if docker ps -a | grep -q openvas; then
        docker start openvas
        echo -e "${GREEN}[完成] OpenVAS 已启动${NC}"
        echo -e "${GREEN}访问: https://localhost:9392${NC}"
    elif command -v gvm &> /dev/null; then
        sudo gvm-start
    else
        echo -e "${RED}[错误] OpenVAS 未安装${NC}"
    fi
}

# 停止
cmd_stop() {
    if docker ps | grep -q openvas; then
        docker stop openvas
        echo -e "${GREEN}[完成] OpenVAS 已停止${NC}"
    elif command -v gvm &> /dev/null; then
        sudo gvm-stop
    fi
}

# 状态
cmd_status() {
    if docker ps | grep -q openvas; then
        echo -e "${GREEN}[信息] OpenVAS Docker 容器运行中${NC}"
        docker logs --tail 20 openvas
    elif command -v gvm &> /dev/null; then
        sudo gvm-check-setup
    else
        echo -e "${YELLOW}[信息] OpenVAS 未安装${NC}"
    fi
}

# 更新
cmd_update() {
    if docker ps | grep -q openvas; then
        echo -e "${YELLOW}[信息] Docker 版本更新: docker pull mikesplain/openvas && docker restart openvas${NC}"
    elif command -v gvm &> /dev/null; then
        sudo gvm-update
    fi
}

# 主函数
main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi
    
    local cmd="$1"
    
    case "$cmd" in
        install) cmd_install ;;
        start) cmd_start ;;
        stop) cmd_stop ;;
        status) cmd_status ;;
        update) cmd_update ;;
        -h|--help) show_help ;;
        *)
            echo -e "${RED}[错误] 未知命令: $cmd${NC}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
