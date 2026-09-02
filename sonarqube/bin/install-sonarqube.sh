#!/bin/bash

# SonarQube一键安装配置脚本
# 代码质量检测平台
# 支持自动检测、避免重复安装、自动更新、自动配置

set -euo pipefail

# === 颜色定义 ===
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# === 常量定义 ===
readonly SONARQUBE_VERSION="25.7.0.110598"
readonly SONARQUBE_IMAGE="sonarqube"
readonly SONARQUBE_ZH_PLUGIN_VERSION="25.7"
readonly SONARQUBE_ZH_PLUGIN_NAME="sonar-l10n-zh-plugin-${SONARQUBE_ZH_PLUGIN_VERSION}.jar"
readonly SONARQUBE_ZH_PLUGIN_URL="https://github.com/SonarQubeCommunity/sonar-l10n-zh/releases/download/sonar-l10n-zh-plugin-${SONARQUBE_ZH_PLUGIN_VERSION}/${SONARQUBE_ZH_PLUGIN_NAME}"
readonly DEFAULT_SONARQUBE_PORT=9000
readonly DEFAULT_INSTALL_DIR="$HOME/sonarqube"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === 全局变量 ===
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
SONARQUBE_PORT="$DEFAULT_SONARQUBE_PORT"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
DRY_RUN=false
UNINSTALL_MODE=false
STATUS_MODE=false
UPDATE_MODE=false
FORCE_UPDATE=false
INSTALL_ZH_MODE=false
INSTALL_MODE="auto"   # auto|docker|host

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "sonarqube" ]; then
        echo "$input"
    else
        echo "$input/sonarqube"
    fi
}

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
SonarQube一键安装配置脚本

SonarQube是一个开源的代码质量平台，用于检测代码中的bug、代码异味和安全漏洞。

特性:
    - 自动检测已安装版本，避免重复安装
    - 自动更新到最新版本（可选）
    - 自动配置端口和启动脚本
    - 支持 Docker 和主机模式

用法: ./install-sonarqube.sh [选项]

选项:
    -h, --help                  显示此帮助信息
    -d, --dir DIR               安装目录 (默认: ~/sonarqube)
    -w, --download-dir DIR      下载目录 (默认: ~/Downloads)
    -p, --port PORT             端口号 (默认: 9000)
    -m, --mode MODE             安装模式: auto|docker|host (默认: auto)
    -f, --force                 强制重新安装（忽略已安装检测）
    --update                    更新到最新版本
    --install-zh                只安装/更新 SonarQube 中文汉化插件
    --status                    显示安装状态
    --dry-run                   试运行模式
    --uninstall                 卸载SonarQube

示例:
    ./install-sonarqube.sh                          # 安装（自动检测避免重复）
    ./install-sonarqube.sh --force                  # 强制重新安装
    ./install-sonarqube.sh --update                 # 更新到最新版本
    ./install-sonarqube.sh --install-zh             # 已有实例只安装/更新中文汉化插件
    ./install-sonarqube.sh --status                 # 查看状态
    ./install-sonarqube.sh --port 9900              # 指定端口
    ./install-sonarqube.sh --mode host              # 主机模式安装
    ./install-sonarqube.sh --uninstall              # 卸载SonarQube

使用指南:
    Docker模式:
      1. 启动SonarQube: cd $INSTALL_DIR && ./bin/startup.sh
      2. 访问控制台: http://localhost:9000
    主机模式:
      1. 启动SonarQube: cd $INSTALL_DIR && ./bin/startup.sh
      2. 访问控制台: http://localhost:9000
    默认账号密码: admin / admin

更多信息: https://www.sonarqube.org/
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
                INSTALL_DIR="$(normalize_install_dir "$2")"
                shift 2
                ;;
            -p|--port)
                SONARQUBE_PORT="$2"
                shift 2
                ;;
            -w|--download-dir)
                DOWNLOAD_DIR="${2/#\~/$HOME}"
                shift 2
                ;;
            -m|--mode)
                INSTALL_MODE="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_UPDATE=true
                shift
                ;;
            --update)
                UPDATE_MODE=true
                FORCE_UPDATE=true
                shift
                ;;
            --install-zh)
                INSTALL_ZH_MODE=true
                shift
                ;;
            --status)
                STATUS_MODE=true
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
                print_error "未知选项: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# === 检测已安装的 SonarQube ===
detect_installed_sonarqube() {
    local installed_version=""
    
    # 检查主机模式安装
    if [ -f "$INSTALL_DIR/bin/linux-x86-64/sonar.sh" ] || [ -f "$INSTALL_DIR/bin/macosx-universal-64/sonar.sh" ]; then
        # 从目录名或文件中提取版本（兼容 macOS）
        if [ -d "$INSTALL_DIR" ]; then
            installed_version=$(basename "$INSTALL_DIR" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
            if [ -z "$installed_version" ]; then
                installed_version="unknown"
            fi
            print_success "检测到已安装的 SonarQube (主机模式): $installed_version"
            return 0
        fi
    fi
    
    # 检查 Docker 模式安装
    if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        installed_version=$(grep 'image: sonarqube:' "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" 2>/dev/null | sed 's/.*image: sonarqube:\([^[:space:]]*\).*/\1/' || echo "")
        if [ -n "$installed_version" ]; then
            print_success "检测到已安装的 SonarQube (Docker 模式): $installed_version"
            return 0
        fi
    fi
    
    # 检查 Docker 容器
    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -q "^sonarqube$"; then
        print_success "检测到已安装的 SonarQube (Docker 容器)"
        return 0
    fi
    
    return 1
}

# === 显示状态 ===
show_status() {
    print_header "SonarQube 安装状态"
    echo ""
    
    # 检测安装
    if detect_installed_sonarqube; then
        print_info "安装目录: $INSTALL_DIR"
        
        # 检查运行状态
        if [ -f "$INSTALL_DIR/bin/startup.sh" ]; then
            if pgrep -f "sonarqube" > /dev/null 2>&1; then
                print_success "SonarQube 正在运行"
                print_info "访问地址: http://localhost:$SONARQUBE_PORT"
            else
                print_warning "SonarQube 未运行"
            fi
        fi
        
        # 检查 Docker 容器
        if command -v docker &>/dev/null && docker ps --format '{{.Names}}' | grep -q "^sonarqube$"; then
            print_success "SonarQube Docker 容器正在运行"
            print_info "访问地址: http://localhost:$SONARQUBE_PORT"
        fi
    else
        print_warning "SonarQube 未安装"
    fi
    
    echo ""
    
    # 检查配置文件
    if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        print_success "Docker Compose 配置存在"
    fi
    
    if [ -f "$INSTALL_DIR/bin/startup.sh" ]; then
        print_success "启动脚本存在"
    fi
    
    if [ -f "$INSTALL_DIR/bin/stop.sh" ]; then
        print_success "停止脚本存在"
    fi

    local zh_plugin_dir="$INSTALL_DIR/extensions/plugins"
    if [ -f "$zh_plugin_dir/$SONARQUBE_ZH_PLUGIN_NAME" ]; then
        print_success "中文汉化插件已安装: $zh_plugin_dir/$SONARQUBE_ZH_PLUGIN_NAME"
    else
        print_warning "中文汉化插件未检测到: $zh_plugin_dir/$SONARQUBE_ZH_PLUGIN_NAME"
    fi
}

# === 检查系统要求 ===
check_system_requirements() {
    if [ "$(uname -s)" != "Linux" ]; then
        print_info "非 Linux 系统，跳过 vm.max_map_count 检查"
        return 0
    fi

    # 检查vm.max_map_count
    local vm_max_map_count
    vm_max_map_count=$(sysctl vm.max_map_count | awk '{print $3}')
    
    if [ "$vm_max_map_count" -lt 262144 ]; then
        print_warning "vm.max_map_count建议设置为262144或更高"
        print_info "当前值: $vm_max_map_count"
        print_info "临时设置: sudo sysctl -w vm.max_map_count=262144"
        print_info "永久设置: 在/etc/sysctl.conf中添加 vm.max_map_count=262144"
        
        read -p "是否自动设置vm.max_map_count? (y/n): " auto_set
        if [[ "$auto_set" =~ ^[Yy]$ ]]; then
            if sysctl -w vm.max_map_count=262144 &> /dev/null; then
                print_success "vm.max_map_count已临时设置为262144"
            else
                print_warning "自动设置失败，请手动设置"
            fi
        fi
    fi
}

# === 检查Docker ===
docker_available() {
    command -v docker &>/dev/null && docker info &>/dev/null
}

check_docker() {
    if ! docker_available; then
        print_error "未检测到Docker"
        print_info "请先安装Docker，可以使用 docker/install-docker-compose.sh 脚本"
        exit 1
    fi

    print_info "检测到Docker: $(docker --version)"
}

# === 检查Docker Compose ===
check_docker_compose() {
    if command -v docker-compose &> /dev/null; then
        print_info "检测到Docker Compose: $(docker-compose --version)"
        return 0
    elif docker compose version &> /dev/null; then
        print_info "检测到Docker Compose Plugin: $(docker compose version)"
        return 0
    else
        print_error "未检测到Docker Compose"
        print_info "请先安装Docker Compose"
        exit 1
    fi
}

# === 创建Docker Compose配置 ===
create_docker_compose() {
    print_header "创建Docker Compose配置..."
    
    mkdir -p "$INSTALL_DIR"/{data,extensions,logs,conf}
    
    cat > "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" << EOF
services:
  sonarqube:
    image: ${SONARQUBE_IMAGE}:${SONARQUBE_VERSION}-community
    container_name: sonarqube
    restart: always
    ports:
      - "${SONARQUBE_PORT}:9000"
    environment:
      - SONAR_JDBC_URL=jdbc:postgresql://postgres:5432/sonar
      - SONAR_JDBC_USERNAME=sonar
      - SONAR_JDBC_PASSWORD=sonar
      - SONAR_WEB_CONTEXT=/
      - SONAR_WEB_JAVAOPTS=-Xmx2048m -Xms2048m
    volumes:
      - ./data:/opt/sonarqube/data
      - ./extensions:/opt/sonarqube/extensions
      - ./logs:/opt/sonarqube/logs
      - ./conf:/opt/sonarqube/conf
    networks:
      - sonarqube-network
    depends_on:
      - postgres
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/api/system/status"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  postgres:
    image: postgres:15
    container_name: sonar-postgres
    restart: always
    environment:
      - POSTGRES_USER=sonar
      - POSTGRES_PASSWORD=sonar
      - POSTGRES_DB=sonar
      - TZ=Asia/Shanghai
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - sonarqube-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sonar"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  sonarqube-network:
    driver: bridge

volumes:
  postgres-data:
EOF
    
    print_success "Docker Compose配置创建完成: $INSTALL_DIR/$DOCKER_COMPOSE_FILE"
}

copy_bin_scripts() {
    mkdir -p "$INSTALL_DIR/bin"

    local script
    for script in startup.sh stop.sh; do
        if [ ! -f "$SCRIPT_DIR/$script" ]; then
            print_error "缺少脚本: $SCRIPT_DIR/$script"
            exit 1
        fi
        cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/bin/$script"
        chmod +x "$INSTALL_DIR/bin/$script"
        print_success "复制脚本: $INSTALL_DIR/bin/$script"
    done
}

# === 下载文件通用函数 ===
download_file() {
    local url="$1" output="$2"
    local output_dir="$(dirname "$output")"
    local output_file="$(basename "$output")"

    if [ -d "$output_dir" ] && [ ! -w "$output_dir" ]; then
        if command -v sudo &>/dev/null; then
            sudo chown "$(id -u):$(id -g)" "$output_dir" 2>/dev/null || true
        fi
    fi
    mkdir -p "$output_dir"

    if [ -f "$output" ] && [ ! -w "$output" ]; then
        if command -v sudo &>/dev/null; then
            sudo rm -f "$output" 2>/dev/null || true
        fi
    fi

    if command -v adl &>/dev/null; then
        print_info "使用 adl 下载: $url"
        adl "$url" "$output_dir" "$output_file"
        return $?
    fi
    if command -v curl &>/dev/null; then
        print_info "使用 curl 下载: $url"
        curl -L -C - -o "$output" "$url"
        return $?
    fi
    if command -v wget &>/dev/null; then
        print_info "使用 wget 下载: $url"
        wget -c -O "$output" "$url"
        return $?
    fi
    print_error "未找到可用下载工具"
    return 1
}

# === 重启 SonarQube ===
restart_sonarqube() {
    if [ "$DRY_RUN" = true ]; then
        print_info "[Dry-run] 将重启 SonarQube"
        return 0
    fi

    if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        print_info "重启 SonarQube Docker 服务以加载插件..."
        (cd "$INSTALL_DIR" && {
            if command -v docker-compose &> /dev/null; then
                if docker-compose ps -q sonarqube 2>/dev/null | grep -q .; then
                    docker-compose restart sonarqube
                else
                    print_warning "SonarQube 容器尚未创建，插件将在首次启动时生效"
                fi
            else
                if docker compose ps -q sonarqube 2>/dev/null | grep -q .; then
                    docker compose restart sonarqube
                else
                    print_warning "SonarQube 容器尚未创建，插件将在首次启动时生效"
                fi
            fi
        })
        return 0
    fi

    if [ -f "$INSTALL_DIR/bin/stop.sh" ] && [ -f "$INSTALL_DIR/bin/startup.sh" ]; then
        print_info "重启 SonarQube 主机服务以加载插件..."
        bash "$INSTALL_DIR/bin/stop.sh" || true
        bash "$INSTALL_DIR/bin/startup.sh"
        return 0
    fi

    print_warning "未找到可用启动脚本，插件将在下次启动 SonarQube 时生效"
}

# === 安装中文汉化插件 ===
install_zh_plugin() {
    print_header "安装 SonarQube 中文汉化插件..."
    print_info "插件版本: $SONARQUBE_ZH_PLUGIN_VERSION"
    print_info "下载地址: $SONARQUBE_ZH_PLUGIN_URL"

    if [ "$DRY_RUN" = true ]; then
        print_info "[Dry-run] 将安装到: $INSTALL_DIR/extensions/plugins/$SONARQUBE_ZH_PLUGIN_NAME"
        return 0
    fi

    local plugin_dir="$INSTALL_DIR/extensions/plugins"
    local plugin_path="$plugin_dir/$SONARQUBE_ZH_PLUGIN_NAME"
    mkdir -p "$plugin_dir"

    find "$plugin_dir" -maxdepth 1 -type f -name 'sonar-l10n-zh-plugin-*.jar' ! -name "$SONARQUBE_ZH_PLUGIN_NAME" -print -delete 2>/dev/null || true

    if [ -f "$plugin_path" ] && [ -s "$plugin_path" ]; then
        print_success "中文汉化插件已存在: $plugin_path"
    else
        if ! download_file "$SONARQUBE_ZH_PLUGIN_URL" "$plugin_path"; then
            print_error "中文汉化插件下载失败"
            exit 1
        fi
        chmod 644 "$plugin_path"
        print_success "中文汉化插件安装完成: $plugin_path"
    fi

    restart_sonarqube
}

# === 主机模式安装 ===
install_host_sonarqube() {
    print_header "使用主机系统安装模式..."

    if [ "$DRY_RUN" = true ]; then
        print_info "[Dry-run] 将下载到 $DOWNLOAD_DIR 并安装到 $INSTALL_DIR"
        return 0
    fi

    local zip_name="sonarqube-${SONARQUBE_VERSION}.zip"
    local url="https://binaries.sonarsource.com/Distribution/sonarqube/${zip_name}"
    local archive="$DOWNLOAD_DIR/$zip_name"

    mkdir -p "$DOWNLOAD_DIR"

    if [ -f "$archive" ] && [ -s "$archive" ]; then
        print_info "检测到已存在安装包: $archive"
    else
        print_info "下载 SonarQube: $url"
        if ! download_file "$url" "$archive"; then
            print_error "下载失败"
            exit 1
        fi
    fi

    # 解压
    local temp_dir
    temp_dir="$(mktemp -d)"
    print_info "解压 SonarQube..."
    unzip -q "$archive" -d "$temp_dir"

    local extracted
    extracted="$(find "$temp_dir" -maxdepth 1 -type d | grep -v "^$temp_dir$" | head -1)"
    if [ -z "$extracted" ]; then
        rm -rf "$temp_dir"
        print_error "解压后未找到 SonarQube 目录"
        exit 1
    fi

    # 安装到目标目录
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR"/*
    cp -R "$extracted"/* "$INSTALL_DIR/"
    rm -rf "$temp_dir"

    # 修改端口配置
    local sonar_props="$INSTALL_DIR/conf/sonar.properties"
    if [ -f "$sonar_props" ]; then
        sed -i.bak "s/^#\?sonar\.web\.port=.*/sonar.web.port=${SONARQUBE_PORT}/" "$sonar_props"
        rm -f "$sonar_props.bak"
        print_info "端口已配置为: $SONARQUBE_PORT"
    fi

    # 复制启动/停止脚本
    copy_bin_scripts
    install_zh_plugin

    print_success "SonarQube 主机模式安装完成"
}

# === 更新 SonarQube ===
update_sonarqube() {
    print_header "更新 SonarQube..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[Dry-run] 将更新 SonarQube 到版本: $SONARQUBE_VERSION"
        return 0
    fi
    
    # 检测当前安装模式
    if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        print_info "检测到 Docker 模式安装"
        
        # 停止服务
        if [ -f "$INSTALL_DIR/bin/stop.sh" ]; then
            bash "$INSTALL_DIR/bin/stop.sh"
        fi
        
        # 更新 Docker Compose 配置
        create_docker_compose
        copy_bin_scripts
        install_zh_plugin
        
        print_success "SonarQube Docker 模式更新完成"
        print_info "启动服务: $INSTALL_DIR/bin/startup.sh"
    elif [ -d "$INSTALL_DIR" ] && { [ -f "$INSTALL_DIR/bin/linux-x86-64/sonar.sh" ] || [ -f "$INSTALL_DIR/bin/macosx-universal-64/sonar.sh" ]; }; then
        print_info "检测到主机模式安装"
        
        # 停止服务
        if [ -f "$INSTALL_DIR/bin/stop.sh" ]; then
            bash "$INSTALL_DIR/bin/stop.sh"
        fi
        
        # 重新安装
        install_host_sonarqube
        
        print_success "SonarQube 主机模式更新完成"
    else
        print_error "未检测到已安装的 SonarQube"
        print_info "请先安装 SonarQube"
        exit 1
    fi
}

# === 安装SonarQube ===
install_sonarqube() {
    print_info "准备安装 SonarQube"
    print_info "版本: $SONARQUBE_VERSION"
    print_info "安装目录: $INSTALL_DIR"
    print_info "端口: $SONARQUBE_PORT"
    print_info "模式: $INSTALL_MODE"

    if [ "$DRY_RUN" = true ]; then
        print_info "试运行模式: 将安装SonarQube到 $INSTALL_DIR"
        return 0
    fi

    # 自动选择模式
    if [ "$INSTALL_MODE" = "auto" ]; then
        if docker_available; then
            INSTALL_MODE="docker"
            print_info "检测到 Docker，使用 Docker 模式"
        else
            INSTALL_MODE="host"
            print_info "Docker 不可用，使用主机模式"
        fi
    fi

    if [ "$INSTALL_MODE" = "docker" ]; then
        # 检查系统要求
        check_system_requirements
        # 检查Docker环境
        check_docker
        check_docker_compose
        # 创建配置
        create_docker_compose
        copy_bin_scripts
        install_zh_plugin
    else
        install_host_sonarqube
    fi

    print_success "SonarQube安装完成"
}

# === 验证安装 ===
verify_installation() {
    print_header "验证安装..."
    
    if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        print_success "Docker Compose配置文件存在"
    elif [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/bin/startup.sh" ]; then
        print_success "主机模式安装文件存在"
    else
        print_error "安装文件不完整"
        return 1
    fi
    
    # 显示使用说明
    print_header "使用说明"
    print_info "1. 启动SonarQube: cd $INSTALL_DIR && ./bin/startup.sh"
    print_info "2. 访问控制台: http://localhost:$SONARQUBE_PORT"
    print_info "3. 默认账号密码: admin / admin"
    print_info "4. 首次登录会要求修改密码"
    print_info "5. 配置数据库连接、创建项目、进行代码扫描"
    print_info "6. 查看日志: docker logs -f sonarqube (Docker模式)"
    print_info "7. 停止服务: cd $INSTALL_DIR && ./bin/stop.sh"
    
    return 0
}

# === 卸载SonarQube ===
uninstall_sonarqube() {
    print_header "卸载SonarQube..."
    
    if [ "$DRY_RUN" = true ]; then
        print_info "试运行: 将删除以下内容:"
        print_info "  安装目录: $INSTALL_DIR"
        return 0
    fi
    
    # 停止并删除容器
    if [ -f "$INSTALL_DIR/$DOCKER_COMPOSE_FILE" ]; then
        print_info "停止并删除SonarQube容器..."
        cd "$INSTALL_DIR"
        if command -v docker-compose &> /dev/null; then
            docker-compose down -v
        else
            docker compose down -v
        fi
    fi
    
    # 停止主机进程
    if pgrep -f "sonarqube" > /dev/null 2>&1; then
        print_info "停止 SonarQube 进程..."
        if [ -f "$INSTALL_DIR/bin/stop.sh" ]; then
            bash "$INSTALL_DIR/bin/stop.sh"
        else
            pkill -f "sonarqube" || true
        fi
    fi
    
    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        print_info "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    else
        print_warning "安装目录不存在: $INSTALL_DIR"
    fi
    
    print_success "SonarQube卸载完成"
}

# === 主函数 ===
main() {
    print_header "SonarQube一键安装配置脚本"
    
    # 解析参数
    parse_arguments "$@"
    
    # 状态模式
    if [ "$STATUS_MODE" = true ]; then
        show_status
        return 0
    fi
    
    # 卸载模式
    if [ "$UNINSTALL_MODE" = true ]; then
        uninstall_sonarqube
        return 0
    fi

    # 只安装/更新中文汉化插件
    if [ "$INSTALL_ZH_MODE" = true ]; then
        install_zh_plugin
        return 0
    fi
    
    # 更新模式
    if [ "$UPDATE_MODE" = true ]; then
        update_sonarqube
        return 0
    fi
    
    # 检测已安装
    if [ "$FORCE_UPDATE" = false ] && detect_installed_sonarqube; then
        print_success "SonarQube 已安装，跳过安装"
        print_info "如需重新安装: $0 --force"
        print_info "如需更新: $0 --update"
        print_info "如需查看状态: $0 --status"
        return 0
    fi
    
    # 安装SonarQube
    install_sonarqube
    
    # 验证安装
    verify_installation
    
    print_header "安装完成!"
    print_success "SonarQube已成功安装并配置"
    print_info "执行以下命令启动SonarQube:"
    print_info "  cd $INSTALL_DIR && ./bin/startup.sh"
}

# === 执行主函数 ===
main "$@"
