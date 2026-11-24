#!/bin/bash

# Harbor 一键安装配置脚本
# Harbor 是一个开源的容器镜像仓库，支持漏洞扫描、镜像复制、权限管理等功能
# 支持 Docker Compose 安装模式

set -e
set -u
set -o pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly HARBOR_VERSION="v2.9.0"
readonly HARBOR_OFFLINE_PACKAGE="harbor-offline-installer-${HARBOR_VERSION}.tgz"
readonly HARBOR_DOWNLOAD_URL="https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${HARBOR_OFFLINE_PACKAGE}"
readonly DEFAULT_INSTALL_DIR="/data/harbor"
readonly DEFAULT_HARBOR_DOMAIN="harbor.local"
readonly DEFAULT_HARBOR_PASSWORD="Harbor12345"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
HARBOR_DOMAIN="$DEFAULT_HARBOR_DOMAIN"
HARBOR_PASSWORD="$DEFAULT_HARBOR_PASSWORD"
HARBOR_PORT="80"
HARBOR_HTTPS_PORT="443"
WITH_TRIVY="true"  # 是否安装 Trivy 漏洞扫描
WITH_NOTARY="false"  # 是否安装 Notary
AUTO_START=false
DRY_RUN=false
UNINSTALL_MODE=false
SKIP_DOWNLOAD=false

# === 工具函数 ===
print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

print_header() {
    echo -e "${CYAN}${BOLD}>>> $*${NC}"
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
Harbor 一键安装配置脚本

Harbor 是一个开源的容器镜像仓库，支持：
- 镜像漏洞扫描（Trivy）
- 镜像复制
- 权限管理
- 镜像签名（Notary）
- Web 管理界面

用法：./bin/install-harbor.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认：/data/harbor)
    --domain DOMAIN             Harbor 访问域名 (默认：harbor.local)
    --port PORT                 HTTP 端口 (默认：80)
    --https-port PORT           HTTPS 端口 (默认：443)
    --password PWD              admin 初始密码 (默认：Harbor12345)
    --with-trivy                安装 Trivy 漏洞扫描 (默认：安装)
    --without-trivy             不安装 Trivy 漏洞扫描
    --with-notary               安装 Notary 镜像签名
    --auto-start                配置自启动服务
    --skip-download             跳过下载（使用已有安装包）
    --dry-run                   试运行模式（不实际安装）
    --uninstall                 卸载 Harbor

示例:
    # 使用默认设置安装
    sudo ./bin/install-harbor.sh
    
    # 指定域名和密码
    sudo ./bin/install-harbor.sh --domain registry.example.com --password MyPwd123
    
    # 不安装漏洞扫描
    sudo ./bin/install-harbor.sh --without-trivy
    
    # 配置自启动
    sudo ./bin/install-harbor.sh --auto-start
    
    # 卸载
    sudo ./bin/install-harbor.sh --uninstall

使用指南:
    1. 访问 Harbor: http://<domain>:<port>
    2. 默认账号：admin
    3. 默认密码：安装时设置的密码
    4. Docker 登录：docker login <domain>:<port>

更多信息：https://goharbor.io/
EOF
}

# === 解析命令行参数 ===
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --domain)
                HARBOR_DOMAIN="$2"
                shift 2
                ;;
            --port)
                HARBOR_PORT="$2"
                shift 2
                ;;
            --https-port)
                HARBOR_HTTPS_PORT="$2"
                shift 2
                ;;
            --password)
                HARBOR_PASSWORD="$2"
                shift 2
                ;;
            --with-trivy)
                WITH_TRIVY="true"
                shift
                ;;
            --without-trivy)
                WITH_TRIVY="false"
                shift
                ;;
            --with-notary)
                WITH_NOTARY="true"
                shift
                ;;
            --auto-start)
                AUTO_START=true
                shift
                ;;
            --skip-download)
                SKIP_DOWNLOAD=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --uninstall)
                UNINSTALL_MODE=true
                shift
                ;;
            *)
                print_error "未知选项：$1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检查前置条件 ===
check_prerequisites() {
    print_header "检查前置条件"
    
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        print_error "需要 root 权限，请使用 sudo 执行"
        exit 1
    fi
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Docker 服务未运行"
        exit 1
    fi
    
    # 检查 Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        print_error "Docker Compose 未安装"
        exit 1
    fi
    
    # 检查 OpenSSL（生成证书需要）
    if ! command -v openssl &> /dev/null; then
        print_error "OpenSSL 未安装"
        exit 1
    fi
    
    # 检查内存（建议至少 4GB）
    if command -v free &> /dev/null; then
        local total_mem
        total_mem=$(free -m | awk '/^Mem:/{print $2}')
        if [[ "$total_mem" -lt 4096 ]]; then
            print_warning "总内存不足 4GB (${total_mem}MB)，可能影响 Harbor 运行"
        fi
    fi
    
    # 检查磁盘空间（建议至少 50GB）
    local available_disk
    available_disk=$(df -m "$INSTALL_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$available_disk" && "$available_disk" -lt 51200 ]]; then
        print_warning "可用磁盘空间不足 50GB，建议清理空间"
    fi
    
    # 检查端口占用
    if command -v lsof &> /dev/null; then
        if lsof -i :"$HARBOR_PORT" &> /dev/null; then
            print_warning "端口 $HARBOR_PORT 已被占用"
        fi
        if lsof -i :"$HARBOR_HTTPS_PORT" &> /dev/null; then
            print_warning "端口 $HARBOR_HTTPS_PORT 已被占用"
        fi
    fi
    
    print_success "前置条件检查通过"
}

# === 创建安装目录 ===
create_directories() {
    print_header "创建安装目录"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建目录：$INSTALL_DIR"
        return
    fi
    
    mkdir -p "$INSTALL_DIR"/{data/{registry,redis,postgresql,job_log,upload,trivy-adapter},logs,bin}
    chmod -R 755 "$INSTALL_DIR"
    print_success "目录创建完成：$INSTALL_DIR"
}

# === 下载 Harbor 安装包 ===
download_harbor() {
    print_header "下载 Harbor 安装包"
    
    if [[ "$SKIP_DOWNLOAD" == "true" ]]; then
        print_info "跳过下载"
        return
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 下载 Harbor $HARBOR_VERSION"
        return
    fi
    
    local PACKAGE_FILE="$INSTALL_DIR/$HARBOR_OFFLINE_PACKAGE"
    
    # 检查是否已存在
    if [[ -f "$PACKAGE_FILE" ]]; then
        print_info "安装包已存在，跳过下载"
        return
    fi
    
    print_info "下载 Harbor 离线安装包..."
    print_info "下载地址：$HARBOR_DOWNLOAD_URL"
    print_info "这可能需要几分钟，请耐心等待..."
    
    cd "$INSTALL_DIR"
    
    # 使用 curl 下载
    if command -v curl &> /dev/null; then
        curl -L -o "$PACKAGE_FILE" "$HARBOR_DOWNLOAD_URL"
    else
        wget -O "$PACKAGE_FILE" "$HARBOR_DOWNLOAD_URL"
    fi
    
    if [[ -f "$PACKAGE_FILE" ]]; then
        local size
        size=$(du -h "$PACKAGE_FILE" | cut -f1)
        print_success "下载完成：$PACKAGE_FILE ($size)"
    else
        print_error "下载失败"
        exit 1
    fi
}

# === 解压 Harbor 安装包 ===
extract_harbor() {
    print_header "解压 Harbor 安装包"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 解压安装包"
        return
    fi
    
    local PACKAGE_FILE="$INSTALL_DIR/$HARBOR_OFFLINE_PACKAGE"
    
    if [[ ! -f "$PACKAGE_FILE" ]]; then
        print_error "安装包不存在：$PACKAGE_FILE"
        exit 1
    fi
    
    print_info "解压中..."
    tar -xzf "$PACKAGE_FILE" -C "$INSTALL_DIR"
    
    print_success "解压完成"
}

# === 生成 Harbor 配置文件 ===
generate_harbor_config() {
    print_header "生成 Harbor 配置文件"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 生成 harbor.yml"
        return
    fi
    
    local HARBOR_YML="$INSTALL_DIR/harbor/harbor.yml"
    
    # 备份原文件
    if [[ -f "$HARBOR_YML" ]]; then
        cp "$HARBOR_YML" "${HARBOR_YML}.bak"
    fi
    
    # 生成配置文件
    cat > "$HARBOR_YML" << EOF
# Harbor 配置文件
    
hostname: ${HARBOR_DOMAIN}
    
http:
  port: ${HARBOR_PORT}
    
# https:
#   port: ${HARBOR_HTTPS_PORT}
#   certificate: /etc/ssl/certs/harbor.crt
#   private_key: /etc/ssl/private/harbor.key
    
harbor_admin_password: ${HARBOR_PASSWORD}
    
database:
  password: ${HARBOR_PASSWORD}
  max_idle_conns: 50
  max_open_conns: 1000
    
data_volume: ${INSTALL_DIR}/data
    
trivy:
  ignore_unfixed: false
  skip_update: false
  offline_scan: false
  insecure: false
    
jobservice:
  max_job_workers: 10
    
notification:
  webhook_job_max_retry: 10
    
log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
    location: ${INSTALL_DIR}/logs
    
_version: ${HARBOR_VERSION}
EOF
    
    # 如果不安装 Trivy，注释掉相关配置
    if [[ "$WITH_TRIVY" == "false" ]]; then
        sed -i '/^trivy:/,/insecure: false/s/^/#/' "$HARBOR_YML"
    fi
    
    print_success "Harbor 配置文件生成完成"
}

# === 安装 Harbor ===
install_harbor() {
    print_header "安装 Harbor"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 运行 Harbor 安装脚本"
        return
    fi
    
    cd "$INSTALL_DIR/harbor"
    
    print_info "执行安装脚本..."
    
    # 尝试使用 docker compose (v2) 或 docker-compose (v1)
    if command -v docker compose &> /dev/null; then
        ./install.sh --with-trivy --no-https
    else
        ./install.sh --with-trivy --no-https
    fi
    
    print_success "Harbor 安装完成"
}

# === 创建启动脚本 ===
create_startup_script() {
    print_header "创建启动脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/startup.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/startup.sh" << 'EOF'
#!/bin/bash

# Harbor 启动脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
HARBOR_DIR="$INSTALL_DIR/harbor"

cd "$HARBOR_DIR"

# 检查 Docker 是否运行
if ! docker info &> /dev/null; then
    echo "错误：Docker 服务未运行"
    exit 1
fi

# 检查 docker-compose.yml 是否存在
if [[ ! -f "docker-compose.yml" ]]; then
    echo "错误：docker-compose.yml 不存在"
    exit 1
fi

echo "正在启动 Harbor..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi

echo ""
echo "等待服务启动..."
sleep 30

# 检查服务状态
echo "检查服务状态..."
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "Harbor 启动完成！"
echo "访问地址：http://<domain>:<port>"
echo "查看日志：docker-compose logs -f"
EOF
    
    chmod +x "$INSTALL_DIR/bin/startup.sh"
    print_success "启动脚本创建完成"
}

# === 创建停止脚本 ===
create_stop_script() {
    print_header "创建停止脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/stop.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/stop.sh" << 'EOF'
#!/bin/bash

# Harbor 停止脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
HARBOR_DIR="$INSTALL_DIR/harbor"

cd "$HARBOR_DIR"

echo "正在停止 Harbor..."

# 尝试使用 docker compose (v2) 或 docker-compose (v1)
if command -v docker compose &> /dev/null; then
    docker compose down
else
    docker-compose down
fi

echo ""
echo "Harbor 已停止"
EOF
    
    chmod +x "$INSTALL_DIR/bin/stop.sh"
    print_success "停止脚本创建完成"
}

# === 创建状态检查脚本 ===
create_status_script() {
    print_header "创建状态检查脚本"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 创建 bin/status.sh"
        return
    fi
    
    cat > "$INSTALL_DIR/bin/status.sh" << EOF
#!/bin/bash

# Harbor 状态检查脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
HARBOR_DIR="\$INSTALL_DIR/harbor"

cd "\$HARBOR_DIR"

echo "=== Harbor 服务状态 ==="
echo ""

# 检查容器状态
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

echo ""
echo "=== Harbor 访问信息 ==="
echo "访问地址：http://${HARBOR_DOMAIN}:${HARBOR_PORT}"
echo "管理员账号：admin"
echo ""

echo "=== 资源使用 ==="
docker stats --no-stream 2>/dev/null || echo "stats 信息不可用"

echo ""
echo "=== 数据目录大小 ==="
du -sh "${INSTALL_DIR}/data" 2>/dev/null || echo "无法获取数据目录大小"

echo ""
echo "=== 最近日志 ==="
if command -v docker compose &> /dev/null; then
    docker compose logs --tail=20 core 2>/dev/null || echo "日志不可用"
else
    docker-compose logs --tail=20 core 2>/dev/null || echo "日志不可用"
fi
EOF
    
    chmod +x "$INSTALL_DIR/bin/status.sh"
    print_success "状态检查脚本创建完成"
}

# === 配置自启动服务 ===
configure_autostart() {
    print_header "配置自启动服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 配置自启动服务"
        return
    fi
    
    if [[ ! -f /etc/systemd/system ]]; then
        print_warning "不支持 systemd，跳过自启动配置"
        return
    fi
    
    local SERVICE_FILE="/etc/systemd/system/harbor.service"
    
    if [[ -f "$SERVICE_FILE" ]]; then
        print_warning "Harbor systemd 服务已存在"
        return
    fi
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Harbor Registry
Documentation=https://goharbor.io/
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}/harbor
ExecStart=/usr/bin/docker compose -f ${INSTALL_DIR}/harbor/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f ${INSTALL_DIR}/harbor/docker-compose.yml down
TimeoutStartSec=600
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    
    if command -v systemctl &> /dev/null; then
        systemctl daemon-reload
        print_success "systemd 服务配置完成"
        print_info "启用：systemctl enable harbor"
        print_info "启动：systemctl start harbor"
        print_info "查看状态：systemctl status harbor"
    fi
}

# === 启动 Harbor ===
start_harbor() {
    print_header "启动 Harbor 服务"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[Dry-run] 启动 Harbor 服务"
        return
    fi
    
    cd "$INSTALL_DIR/harbor"
    
    # 尝试使用 docker compose (v2) 或 docker-compose (v1)
    if command -v docker compose &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    print_info "等待服务启动..."
    sleep 30
    
    # 检查服务状态
    print_info "检查服务状态..."
    if command -v docker compose &> /dev/null; then
        docker compose ps
    else
        docker-compose ps
    fi
    
    print_success "Harbor 服务已启动"
}

# === 卸载 Harbor ===
uninstall_harbor() {
    print_header "卸载 Harbor"
    
    print_warning "此操作将删除 Harbor 所有数据和配置！"
    read -p "确定要继续吗？(y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi
    
    # 停止服务
    if [[ -d "$INSTALL_DIR/harbor" ]]; then
        print_info "停止 Docker 容器..."
        cd "$INSTALL_DIR/harbor"
        
        if command -v docker compose &> /dev/null; then
            docker compose down 2>/dev/null || true
        else
            docker-compose down 2>/dev/null || true
        fi
    fi
    
    # 删除 systemd 服务
    if [[ -f /etc/systemd/system/harbor.service ]]; then
        print_info "删除 systemd 服务..."
        systemctl stop harbor 2>/dev/null || true
        systemctl disable harbor 2>/dev/null || true
        rm -f /etc/systemd/system/harbor.service
        systemctl daemon-reload
    fi
    
    # 删除安装目录（可选）
    read -p "是否删除数据目录？(y/N): " confirm_data
    if [[ "$confirm_data" == "y" || "$confirm_data" == "Y" ]]; then
        print_info "删除安装目录：$INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_info "保留数据目录，仅删除程序文件..."
        rm -rf "$INSTALL_DIR/harbor"
    fi
    
    print_success "Harbor 卸载完成"
}

# === 显示安装后信息 ===
show_post_install_info() {
    print_header "安装完成"
    
    cat << EOF
${GREEN}Harbor 安装成功！${NC}

${BOLD}安装目录:${NC} $INSTALL_DIR
${BOLD}访问地址:${NC} http://${HARBOR_DOMAIN}:${HARBOR_PORT}
${BOLD}管理员账号:${NC} admin
${BOLD}管理员密码:${NC} $HARBOR_PASSWORD

${BOLD}常用命令:${NC}
  启动服务：cd $INSTALL_DIR && ./bin/startup.sh
  停止服务：cd $INSTALL_DIR && ./bin/stop.sh
  查看状态：cd $INSTALL_DIR && ./bin/status.sh
  查看日志：cd $INSTALL_DIR/harbor && docker-compose logs -f

${BOLD}Docker 使用:${NC}
  登录：docker login ${HARBOR_DOMAIN}:${HARBOR_PORT}
  推送：docker push ${HARBOR_DOMAIN}:${HARBOR_PORT/library/myimage:tag}
  拉取：docker pull ${HARBOR_DOMAIN}:${HARBOR_PORT/library/myimage:tag}

${BOLD}自启动配置:${NC}
EOF
    
    if [[ "$AUTO_START" == "true" ]]; then
        echo -e "  ${GREEN}已配置自启动服务${NC}"
    else
        echo "  未配置自启动，如需配置请运行：--auto-start"
    fi
    
    echo ""
    echo -e "${CYAN}更多信息请访问：https://goharbor.io/${NC}"
    echo ""
    print_warning "首次登录后请立即修改管理员密码！"
}

# === 主函数 ===
main() {
    print_header "Harbor 容器镜像仓库安装脚本"
    
    parse_arguments "$@"
    
    if [[ "$UNINSTALL_MODE" == "true" ]]; then
        uninstall_harbor
        exit 0
    fi
    
    echo ""
    echo "安装配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  访问域名：$HARBOR_DOMAIN"
    echo "  HTTP 端口：$HARBOR_PORT"
    echo "  管理员密码：$HARBOR_PASSWORD"
    echo "  安装 Trivy: $WITH_TRIVY"
    echo "  安装 Notary: $WITH_NOTARY"
    echo "  自动启动：$AUTO_START"
    echo "  跳过下载：$SKIP_DOWNLOAD"
    echo "  试运行：$DRY_RUN"
    echo ""
    
    check_prerequisites
    create_directories
    download_harbor
    extract_harbor
    generate_harbor_config
    install_harbor
    create_startup_script
    create_stop_script
    create_status_script
    
    if [[ "$DRY_RUN" != "true" ]]; then
        print_info "是否立即启动 Harbor？(y/N)"
        read -r -p "> " start_now
        if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
            start_harbor
            
            if [[ "$AUTO_START" == "true" ]]; then
                configure_autostart
            fi
        fi
    fi
    
    show_post_install_info
}

# 执行主函数
main "$@"
