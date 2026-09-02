#!/bin/bash

# ELK Stack 卸载脚本
# 完全清理 Elasticsearch、Logstash、Kibana 及相关数据

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

# === 默认配置 ===
readonly DEFAULT_INSTALL_DIR="/data/elk"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
FORCE_MODE=false
KEEP_DATA=false
DRY_RUN=false
INSTALL_MODE="auto"
COMPONENTS=""

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

# === 显示帮助信息 ===
show_usage() {
    cat << 'EOF'
ELK Stack 卸载脚本

用法：./bin/uninstall-elk.sh [选项]

选项:
    -h, --help              显示此帮助信息
    -d, --dir DIR           ELK 安装目录 (默认：/data/elk)
    -f, --force             强制卸载，不确认提示
    --keep-data             保留数据文件，仅删除配置和容器
    --mode MODE             卸载模式 (auto|docker|host，默认：auto)
    --dry-run               试运行模式（不实际删除）
    --components LIST       仅卸载指定组件，逗号分隔: elasticsearch,logstash,kibana

示例:
    ./bin/uninstall-elk.sh              # 交互式卸载
    ./bin/uninstall-elk.sh --force      # 强制卸载
    ./bin/uninstall-elk.sh --keep-data  # 保留数据文件
    ./bin/uninstall-elk.sh -d /opt/elk  # 指定安装目录
    ./bin/uninstall-elk.sh -d /data/elk --mode host --components elasticsearch,logstash --force

警告:
    此操作将删除 ELK 容器、配置和数据，请提前备份重要数据！
    备份命令：curl -X POST "localhost:9200/_snapshot/backup" -d '{"type": "fs", "settings": {"location": "/backup/path"}}'
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
            -f|--force)
                FORCE_MODE=true
                shift
                ;;
            --keep-data)
                KEEP_DATA=true
                shift
                ;;
            --mode)
                INSTALL_MODE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --components)
                COMPONENTS="${2:-}"
                [[ -n "$COMPONENTS" ]] || { print_error "--components 不能为空"; exit 1; }
                shift 2
                ;;
            --components=*)
                COMPONENTS="${1#*=}"
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

validate_selected_components() {
    [[ -n "$COMPONENTS" ]] || return 0
    local component
    local selected_components=()
    IFS=',' read -r -a selected_components <<< "$COMPONENTS"
    for component in "${selected_components[@]}"; do
        case "$component" in
            elasticsearch|logstash|kibana) ;;
            *) print_error "不支持的 ELK 组件: $component"; exit 1 ;;
        esac
    done
}

stop_host_component() {
    local component="$1"
    local install_real pid exe
    install_real="$(cd "$INSTALL_DIR" && pwd -P)"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$component" 2>/dev/null || true
        systemctl disable "$component" 2>/dev/null || true
    fi

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        [[ "$exe" == "$install_real/$component/"* ]] || continue
        print_info "停止 ${component} 进程（PID: ${pid}）"
        kill -TERM "$pid" 2>/dev/null || true
    done < <(ps -eo pid=)

    sleep 3
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        [[ "$exe" == "$install_real/$component/"* ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
    done < <(ps -eo pid=)
}

uninstall_selected_host_components() {
    [[ "$INSTALL_MODE" == "host" ]] || { print_error "--components 当前仅支持 host 模式"; exit 1; }
    [[ "$INSTALL_DIR" == /* && "$INSTALL_DIR" != "/" ]] || { print_error "不安全的安装目录: $INSTALL_DIR"; exit 1; }

    local timestamp backup_dir component target
    local selected_components=()
    timestamp="$(date +%Y%m%d_%H%M%S)"
    backup_dir="$INSTALL_DIR/uninstall-backup/$timestamp"

    print_warning "仅卸载组件: ${COMPONENTS}（不会处理未选中的组件）"
    if [[ "$FORCE_MODE" != "true" && "$DRY_RUN" != "true" ]]; then
        read -r -p "确认卸载所选组件？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { print_info "取消卸载"; return 0; }
    fi

    IFS=',' read -r -a selected_components <<< "$COMPONENTS"
    for component in "${selected_components[@]}"; do
        target="$INSTALL_DIR/$component"
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[Dry-run] 停止并删除: $target"
            continue
        fi

        mkdir -p "$backup_dir/$component"
        if [[ -d "$target/config" ]]; then
            cp -a "$target/config" "$backup_dir/$component/"
        fi
        if [[ -d "$target/pipeline" ]]; then
            cp -a "$target/pipeline" "$backup_dir/$component/"
        fi
        [[ ! -f "/etc/systemd/system/$component.service" ]] || cp -a "/etc/systemd/system/$component.service" "$backup_dir/$component/" 2>/dev/null || true

        stop_host_component "$component"
        rm -rf "$target" "$INSTALL_DIR/data/$component" "$INSTALL_DIR/logs/$component" "$INSTALL_DIR/config/$component"
        if [[ -f "/etc/systemd/system/$component.service" ]]; then
            rm -f "/etc/systemd/system/$component.service" 2>/dev/null || sudo rm -f "/etc/systemd/system/$component.service"
        fi
        print_success "$component 已卸载"
    done

    command -v systemctl >/dev/null 2>&1 && { systemctl daemon-reload 2>/dev/null || sudo systemctl daemon-reload 2>/dev/null || true; }
    [[ "$DRY_RUN" == "true" ]] || print_info "配置备份目录: $backup_dir"
}

# === 检查是否安装 Docker ===
check_docker() {
    if command -v docker &> /dev/null; then
        if docker info &> /dev/null; then
            return 0
        fi
    fi
    return 1
}

# === 确定卸载模式 ===
detect_install_mode() {
    if [[ "$INSTALL_MODE" == "auto" ]]; then
        # 检测安装模式
        if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
            INSTALL_MODE="docker"
        elif [[ -d "$INSTALL_DIR/elasticsearch" ]]; then
            INSTALL_MODE="host"
        elif check_docker; then
            # 检查是否有 ELK 容器
            if docker ps -a --format '{{.Names}}' | grep -qE "^(elasticsearch|elk)"; then
                INSTALL_MODE="docker"
            else
                INSTALL_MODE="docker"  # 默认使用 Docker 模式
            fi
        else
            INSTALL_MODE="host"
        fi
        print_info "检测到安装模式：$INSTALL_MODE"
    fi
}

# === 确认卸载 ===
confirm_uninstall() {
    if [[ "$FORCE_MODE" == "true" ]]; then
        return 0
    fi
    
    print_warning "=========================================="
    print_warning "       ELK Stack 卸载确认"
    print_warning "=========================================="
    echo ""
    echo "安装目录：$INSTALL_DIR"
    echo "卸载模式：$INSTALL_MODE"
    echo ""
    
    if [[ "$KEEP_DATA" == "true" ]]; then
        echo "将保留数据文件，仅删除："
        if [[ "$INSTALL_MODE" == "docker" ]]; then
            echo "  - Docker 容器和网络"
        fi
        echo "  - 配置文件"
        echo "  - 日志文件"
        echo "  - systemd 服务配置"
    else
        echo "将删除以下内容："
        if [[ "$INSTALL_MODE" == "docker" ]]; then
            echo "  - Docker 容器和网络"
        fi
        echo "  - 所有数据文件（索引数据）"
        echo "  - 配置文件"
        echo "  - 日志文件"
        echo "  - systemd 服务配置"
    fi
    
    echo ""
    echo "建议在卸载前执行备份："
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        echo "  # 备份 Elasticsearch 索引"
        echo "  curl -X PUT \"localhost:9200/_snapshot/backup\" -H 'Content-Type: application/json' -d '{\"type\": \"fs\", \"settings\": {\"location\": \"/backup/path\"}}'"
        echo "  curl -X PUT \"localhost:9200/_snapshot/backup/snapshot_1?wait_for_completion=true\""
    else
        echo "  # 备份数据目录"
        echo "  tar -czf elk_backup.tar.gz $INSTALL_DIR/data"
    fi
    echo ""
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "[Dry-run] 继续卸载..."
        return 0
    fi
    
    read -p "确定要继续卸载吗？此操作不可逆！(y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "取消卸载"
        exit 0
    fi
}

# === 停止服务 ===
stop_service() {
    print_header "停止 ELK 服务"
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        # Docker 模式
        if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
            print_info "停止 Docker 容器..."
            cd "$INSTALL_DIR"
            
            if command -v docker compose &> /dev/null; then
                docker compose down 2>/dev/null || print_warning "停止容器失败"
            else
                docker-compose down 2>/dev/null || print_warning "停止容器失败"
            fi
        else
            print_info "尝试直接停止 Docker 容器..."
            docker stop elasticsearch 2>/dev/null || true
            docker stop logstash 2>/dev/null || true
            docker stop kibana 2>/dev/null || true
            docker stop filebeat 2>/dev/null || true
        fi
    else
        # 主机模式
        print_info "停止 systemd 服务..."
        
        if [[ -f /etc/systemd/system/elasticsearch.service ]]; then
            systemctl stop elasticsearch 2>/dev/null || true
        fi
        
        if [[ -f /etc/systemd/system/logstash.service ]]; then
            systemctl stop logstash 2>/dev/null || true
        fi
        
        if [[ -f /etc/systemd/system/kibana.service ]]; then
            systemctl stop kibana 2>/dev/null || true
        fi
        
        # 尝试直接停止进程
        pkill -f elasticsearch 2>/dev/null || true
        pkill -f logstash 2>/dev/null || true
        pkill -f kibana 2>/dev/null || true
    fi
    
    print_success "服务已停止"
}

# === 删除 Docker 资源 ===
remove_docker_resources() {
    print_header "删除 Docker 资源"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除 Docker 容器和网络"
        return
    fi
    
    # 删除容器
    print_info "删除容器..."
    docker rm -f elasticsearch 2>/dev/null || true
    docker rm -f logstash 2>/dev/null || true
    docker rm -f kibana 2>/dev/null || true
    docker rm -f filebeat 2>/dev/null || true
    
    # 删除网络
    print_info "删除网络..."
    docker network rm elk_elk-network 2>/dev/null || true
    
    # 删除卷（如果未保留数据）
    if [[ "$KEEP_DATA" != "true" ]]; then
        print_info "删除数据卷..."
        docker volume ls -q | grep -iE "(elasticsearch|logstash|kibana|elk)" | xargs -r docker volume rm -f 2>/dev/null || true
    fi
    
    print_success "Docker 资源已清理"
}

# === 删除文件 ===
remove_files() {
    print_header "删除文件"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除目录：$INSTALL_DIR"
        return
    fi
    
    if [[ -d "$INSTALL_DIR" ]]; then
        if [[ "$KEEP_DATA" == "true" ]]; then
            # 保留数据目录
            print_info "保留数据目录..."
            rm -rf "$INSTALL_DIR/bin"
            rm -rf "$INSTALL_DIR/logs"
            rm -rf "$INSTALL_DIR/config"
            rm -f "$INSTALL_DIR/docker-compose.yml"
            rm -f "$INSTALL_DIR/.env"
        else
            # 删除所有内容
            print_warning "删除整个安装目录：$INSTALL_DIR"
            rm -rf "$INSTALL_DIR"
        fi
        
        print_success "文件已删除"
    else
        print_info "安装目录不存在：$INSTALL_DIR"
    fi
}

# === 删除服务配置 ===
remove_service_config() {
    print_header "删除服务配置"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除服务配置文件"
        return
    fi
    
    local services_deleted=0
    
    # systemd 服务
    if [[ -f /etc/systemd/system/elk.service ]]; then
        print_info "停止并禁用 elk 服务..."
        systemctl stop elk 2>/dev/null || true
        systemctl disable elk 2>/dev/null || true
        rm -f /etc/systemd/system/elk.service
        ((services_deleted++))
    fi
    
    if [[ -f /etc/systemd/system/elasticsearch.service ]]; then
        print_info "停止并禁用 elasticsearch 服务..."
        systemctl stop elasticsearch 2>/dev/null || true
        systemctl disable elasticsearch 2>/dev/null || true
        rm -f /etc/systemd/system/elasticsearch.service
        ((services_deleted++))
    fi
    
    if [[ -f /etc/systemd/system/logstash.service ]]; then
        print_info "停止并禁用 logstash 服务..."
        systemctl stop logstash 2>/dev/null || true
        systemctl disable logstash 2>/dev/null || true
        rm -f /etc/systemd/system/logstash.service
        ((services_deleted++))
    fi
    
    if [[ -f /etc/systemd/system/kibana.service ]]; then
        print_info "停止并禁用 kibana 服务..."
        systemctl stop kibana 2>/dev/null || true
        systemctl disable kibana 2>/dev/null || true
        rm -f /etc/systemd/system/kibana.service
        ((services_deleted++))
    fi
    
    if [[ $services_deleted -gt 0 ]]; then
        systemctl daemon-reload 2>/dev/null || true
        print_success "已删除 $services_deleted 个 systemd 服务"
    else
        print_info "未发现 systemd 服务配置"
    fi
    
    # init.d 服务
    for service in elk elasticsearch logstash kibana; do
        if [[ -f "/etc/init.d/$service" ]]; then
            print_info "删除 init.d 服务：$service"
            rm -f "/etc/init.d/$service"
            if command -v chkconfig &> /dev/null; then
                chkconfig --del "$service" 2>/dev/null || true
            fi
        fi
    done
}

# === 删除用户（主机模式）===
remove_users() {
    print_header "删除系统用户"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 删除 elasticsearch 用户"
        return
    fi
    
    if [[ "$INSTALL_MODE" == "host" ]]; then
        if id elasticsearch &>/dev/null; then
            print_info "删除 elasticsearch 用户..."
            userdel elasticsearch 2>/dev/null || print_warning "删除用户失败"
            print_success "elasticsearch 用户已删除"
        else
            print_info "elasticsearch 用户不存在"
        fi
    fi
}

# === 清理 Docker 镜像（可选）===
cleanup_images() {
    print_header "清理 Docker 镜像（可选）"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "[Dry-run] 清理 ELK 相关镜像"
        return
    fi
    
    if [[ "$INSTALL_MODE" != "docker" ]]; then
        print_info "非 Docker 模式，跳过"
        return
    fi
    
    read -p "是否删除 ELK 相关 Docker 镜像？(y/N): " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        print_info "删除镜像..."
        docker rmi -f docker.elastic.co/elasticsearch/elasticsearch:* 2>/dev/null || true
        docker rmi -f docker.elastic.co/logstash/logstash:* 2>/dev/null || true
        docker rmi -f docker.elastic.co/kibana/kibana:* 2>/dev/null || true
        docker rmi -f docker.elastic.co/beats/filebeat:* 2>/dev/null || true
        print_success "镜像已删除"
    else
        print_info "保留镜像"
    fi
}

# === 显示卸载摘要 ===
show_summary() {
    print_header "卸载完成"
    
    cat << EOF
${GREEN}ELK Stack 卸载成功！${NC}

已删除:
EOF

    if [[ "$INSTALL_MODE" == "docker" ]]; then
        echo "  - Docker 容器 (elasticsearch, logstash, kibana, filebeat)"
        echo "  - Docker 网络"
    else
        echo "  - systemd/init.d 服务配置"
        echo "  - 系统用户 (elasticsearch)"
    fi

    if [[ "$KEEP_DATA" != "true" ]]; then
        echo "  - 数据文件（所有索引数据）"
        echo "  - 配置文件"
        echo "  - 日志文件"
    else
        echo -e "  ${GREEN}保留数据文件${NC}"
    fi

    cat << EOF

如需重新安装，请运行:
  cd /path/to/shell/elk
  ./bin/install-elk.sh

EOF
}

# === 主函数 ===
main() {
    print_header "ELK Stack 卸载脚本"
    
    parse_arguments "$@"
    validate_selected_components
    
    detect_install_mode

    if [[ -n "$COMPONENTS" ]]; then
        uninstall_selected_host_components
        return 0
    fi
    
    echo ""
    echo "卸载配置:"
    echo "  安装目录：$INSTALL_DIR"
    echo "  卸载模式：$INSTALL_MODE"
    echo "  保留数据：$KEEP_DATA"
    echo "  强制模式：$FORCE_MODE"
    echo ""
    
    confirm_uninstall
    stop_service
    
    if [[ "$INSTALL_MODE" == "docker" ]]; then
        remove_docker_resources
    fi
    
    remove_files
    remove_service_config
    remove_users
    cleanup_images
    show_summary
}

# 执行主函数
main "$@"
