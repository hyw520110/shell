#!/bin/bash

# Maven Install Script
# Simple and reliable Maven installation

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DEFAULT_MAVEN_VERSION="3.9.9"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
DEFAULT_INSTALL_DIR="$HOME/maven"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
DEFAULT_LOCAL_REPO="$HOME/.m2/repository"
LOCAL_REPO="$DEFAULT_LOCAL_REPO"
DRY_RUN=false
SKIP_SETTINGS=false
UNINSTALL_MODE=false

MAVEN_MIRROR_ALIYUN="https://maven.aliyun.com/repository/public"
MAVEN_MIRROR_TENCENT="https://mirrors.cloud.tencent.com/nexus/repository/maven-public/"
MAVEN_MIRROR_HUAWEI="https://mirrors.huaweicloud.com/repository/maven/"
MAVEN_MIRROR_OFFICIAL=""
USE_MIRROR="$MAVEN_MIRROR_ALIYUN"
USE_MIRROR_ID="aliyun-maven"
USE_MIRROR_NAME="Aliyun Maven"

# Download mirrors
MIRRORS=(
    "https://mirrors.huaweicloud.com/apache/maven"
    "https://mirrors.aliyun.com/apache/maven"
    "https://mirrors.tuna.tsinghua.edu.cn/apache/maven"
    "https://downloads.apache.org/maven"
)

# Functions
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_option_value() {
    local option="$1"
    local value="${2:-}"

    if [[ -z "$value" || "$value" == -* ]]; then
        error "Option $option requires a value"
        exit 1
    fi
}

find_adl() {
    if command -v adl >/dev/null 2>&1 && adl --help >/dev/null 2>&1; then
        command -v adl
        return 0
    fi
    return 1
}

download_with_adl() {
    local url="$1"
    local output="$2"
    local output_dir
    local filename
    output_dir="$(dirname "$output")"
    filename="$(basename "$output")"

    mkdir -p "$output_dir"

    local adl_path
    if adl_path=$(find_adl); then
        info "使用 adl 下载..."
        if "$adl_path" "$url" "$output_dir" "$filename"; then
            return 0
        fi
        warn "adl 下载失败，回退到 curl/wget"
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url"
    else
        error "未找到可用下载工具，请安装 adl、curl 或 wget"
        return 1
    fi
}

detect_os() {
    case "$(uname -s)" in
        Linux*) echo "linux" ;;
        Darwin*) echo "macos" ;;
        *) echo "unknown" ;;
    esac
}

normalize_install_dir() {
    local input="${1:-$DEFAULT_INSTALL_DIR}"
    input="${input/#\~/$HOME}"
    input="${input%/}"
    if [ "$(basename "$input")" = "maven" ]; then
        echo "$input"
    else
        echo "$input/maven"
    fi
}

get_latest_version() {
    local url="https://maven.apache.org/download.cgi"
    if command -v curl >/dev/null 2>&1; then
        curl -s "$url" 2>/dev/null | grep -o 'apache-maven-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-bin' | head -1 | sed 's/apache-maven-//;s/-bin//' || echo "$DEFAULT_MAVEN_VERSION"
    else
        echo "$DEFAULT_MAVEN_VERSION"
    fi
}

get_current_version() {
    if [[ -L "$INSTALL_DIR/current" ]]; then
        basename "$(readlink "$INSTALL_DIR/current")" | sed 's/apache-maven-//'
    elif [[ -x "$INSTALL_DIR/current/bin/mvn" ]]; then
        "$INSTALL_DIR/current/bin/mvn" -v 2>/dev/null | grep -o "Apache Maven [0-9\.]*" | head -1 | cut -d' ' -f3
    elif command -v mvn >/dev/null 2>&1; then
        mvn -v 2>/dev/null | grep -o "Apache Maven [0-9\.]*" | head -1 | cut -d' ' -f3
    fi
}

download_maven() {
    local version="$1"
    local os_type=$(detect_os)
    local ext="tar.gz"
    [[ "$os_type" == "windows" ]] && ext="zip"
    
    local filename="apache-maven-${version}-bin.${ext}"
    local url=""
    
    mkdir -p "$DOWNLOAD_DIR"
    
    for mirror in "${MIRRORS[@]}"; do
        url="${mirror}/maven-3/${version}/binaries/${filename}"
        info "Trying: $url"
        
        if download_with_adl "$url" "$DOWNLOAD_DIR/$filename"; then
            if [[ -s "$DOWNLOAD_DIR/$filename" ]] && tar -tzf "$DOWNLOAD_DIR/$filename" >/dev/null 2>&1; then
                success "Downloaded: $filename"
                return 0
            fi
        fi
        
        warn "Failed from: $mirror"
    done
    
    error "All mirrors failed"
    return 1
}

install_maven() {
    local version="$1"
    local filename="apache-maven-${version}-bin.tar.gz"
    local extract_dir="$INSTALL_DIR/apache-maven-$version"
    local skip_extract=false
    
    if [[ -d "$extract_dir" ]]; then
        if [[ -L "$INSTALL_DIR/current" && "$(readlink "$INSTALL_DIR/current")" == "$extract_dir" ]]; then
            warn "Maven $version already installed and active, skipping..."
            return 0
        fi
        warn "Maven $version is already extracted but not active, will set as current..."
        skip_extract=true
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] Would extract $DOWNLOAD_DIR/$filename to $INSTALL_DIR"
        info "[Dry-run] Would link $INSTALL_DIR/current -> $extract_dir"
        return 0
    fi
    
    local use_sudo=""
    if [ ! -w "$(dirname "$INSTALL_DIR")" ]; then
        warn "需要管理员权限，正在请求sudo..."
        use_sudo="sudo"
    fi

    if [[ "$skip_extract" == false ]]; then
        $use_sudo mkdir -p "$INSTALL_DIR"
        $use_sudo tar -xzf "$DOWNLOAD_DIR/$filename" -C "$INSTALL_DIR"
    fi
    
    # 迁移并备份全局配置文件
    if [[ -f "$INSTALL_DIR/current/conf/settings.xml" ]]; then
        info "Backing up and migrating global settings.xml to new version..."
        local backup_name="settings.xml.backup.$(date +%Y%m%d_%H%M%S)"
        $use_sudo cp "$INSTALL_DIR/current/conf/settings.xml" "$INSTALL_DIR/current/conf/$backup_name"
        $use_sudo cp -a "$INSTALL_DIR/current/conf/settings.xml" "$extract_dir/conf/settings.xml"
        success "Migrated global settings.xml"
    fi

    $use_sudo ln -sfn "$extract_dir" "$INSTALL_DIR/current"
    
    success "Maven $version installed to $extract_dir"
}

configure_maven_settings() {
    if [[ "$SKIP_SETTINGS" == true ]]; then
        info "Skipping Maven settings.xml configuration"
        return 0
    fi

    local settings_file="$HOME/.m2/settings.xml"
    local settings_dir
    settings_dir="$(dirname "$settings_file")"

    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] Would configure Maven settings: $settings_file"
        info "[Dry-run] Local repository: $LOCAL_REPO"
        if [[ -n "$USE_MIRROR" ]]; then
            info "[Dry-run] Mirror: $USE_MIRROR_NAME ($USE_MIRROR)"
        else
            info "[Dry-run] Mirror: official Maven repositories"
        fi
        return 0
    fi

    mkdir -p "$settings_dir" "$LOCAL_REPO"

    if [[ -f "$settings_file" ]]; then
        cp "$settings_file" "$settings_file.backup.$(date +%Y%m%d_%H%M%S)"
        info "Backed up existing settings.xml"
    fi

    if [[ -n "$USE_MIRROR" ]]; then
        cat > "$settings_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                              http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <localRepository>$LOCAL_REPO</localRepository>

  <mirrors>
    <mirror>
      <id>$USE_MIRROR_ID</id>
      <mirrorOf>*</mirrorOf>
      <name>$USE_MIRROR_NAME</name>
      <url>$USE_MIRROR</url>
    </mirror>
  </mirrors>

  <profiles>
    <profile>
      <id>default</id>
      <activation>
        <activeByDefault>true</activeByDefault>
      </activation>
      <properties>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
        <maven.compiler.source>1.8</maven.compiler.source>
        <maven.compiler.target>1.8</maven.compiler.target>
      </properties>
    </profile>
  </profiles>
</settings>
EOF
    else
        cat > "$settings_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                              http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <localRepository>$LOCAL_REPO</localRepository>

  <profiles>
    <profile>
      <id>default</id>
      <activation>
        <activeByDefault>true</activeByDefault>
      </activation>
      <properties>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
        <maven.compiler.source>1.8</maven.compiler.source>
        <maven.compiler.target>1.8</maven.compiler.target>
      </properties>
    </profile>
  </profiles>
</settings>
EOF
    fi

    success "Configured Maven settings: $settings_file"
}

configure_shell() {
    local shell_config=""
    local shell_name
    shell_name="$(basename "${SHELL:-}")"

    case "$shell_name" in
        zsh)
            shell_config="$HOME/.zshrc"
            ;;
        bash)
            if [[ -f "$HOME/.bash_profile" ]]; then
                shell_config="$HOME/.bash_profile"
            else
                shell_config="$HOME/.bashrc"
            fi
            ;;
        *)
            shell_config="$HOME/.profile"
            ;;
    esac
    
    local maven_home="$INSTALL_DIR/current"
    local export_line="export MAVEN_HOME=\"$maven_home\""
    local path_line="export PATH=\"\$MAVEN_HOME/bin:\$PATH\""
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] Would configure shell file: $shell_config"
        return 0
    fi

    if ! grep -q "Maven Environment Variables" "$shell_config" 2>/dev/null; then
        echo "" >> "$shell_config"
        echo "# Maven Environment Variables" >> "$shell_config"
        echo "$export_line" >> "$shell_config"
        echo "$path_line" >> "$shell_config"
        success "Added to $shell_config"
        info "Run: source $shell_config"
    else
        info "Maven already configured"
    fi
}

uninstall_maven() {
    info "Uninstalling Maven from: $INSTALL_DIR"

    if [ "$DRY_RUN" == true ]; then
        info "[Dry-run] Would remove: $INSTALL_DIR"
        return 0
    fi

    # 删除安装目录（包含 apache-maven-x.x.x 子目录和 current 符号链接）
    if [ -d "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; then
        info "Removing install directory: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
        success "Maven directory removed: $INSTALL_DIR"
    else
        warn "Maven directory not found: $INSTALL_DIR"
    fi

    # 清理 shell 配置中的 MAVEN_HOME 和 PATH 引用
    local shell_config=""
    local shell_name
    shell_name="$(basename "${SHELL:-}")"
    case "$shell_name" in
        zsh)  shell_config="$HOME/.zshrc" ;;
        bash)
            if [[ -f "$HOME/.bash_profile" ]]; then
                shell_config="$HOME/.bash_profile"
            else
                shell_config="$HOME/.bashrc"
            fi
            ;;
        *)    shell_config="$HOME/.profile" ;;
    esac

    if [ -f "$shell_config" ]; then
        info "Cleaning shell config: $shell_config"
        if grep -q "Maven Environment Variables" "$shell_config" 2>/dev/null; then
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' '/# Maven Environment Variables/,/MAVEN_HOME\/bin:\$PATH/d' "$shell_config"
            else
                sed -i '/# Maven Environment Variables/,/MAVEN_HOME\/bin:\$PATH/d' "$shell_config"
            fi
            success "Shell config cleaned"
        fi
    fi

    success "Maven uninstall completed"
    info "Note: ~/.m2/repository is preserved. Remove manually if needed: rm -rf ~/.m2"
}

show_help() {
    echo "Maven Installer"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -v, --version VERSION    Specify Maven version"
    echo "  -d, --dir DIR            Install parent or actual install directory (default: $DEFAULT_INSTALL_DIR)"
    echo "  -r, --repo DIR           Maven local repository (default: $DEFAULT_LOCAL_REPO)"
    echo "  -m, --mirror MIRROR      Maven dependency mirror (aliyun|tencent|huawei|official)"
    echo "  -l, --latest             Install latest version"
    echo "  -u, --upgrade            Upgrade to the latest version if a newer one is available"
    echo "  --skip-settings          Do not write ~/.m2/settings.xml"
    echo "  --dry-run                Show planned actions without writing files"
    echo "  --uninstall              Uninstall Maven"
    echo "  -h, --help              Show this help"
    echo ""
    echo "Mirror defaults:"
    echo "  aliyun   $MAVEN_MIRROR_ALIYUN [default]"
    echo "  tencent  $MAVEN_MIRROR_TENCENT"
    echo "  huawei   $MAVEN_MIRROR_HUAWEI"
    echo "  official no mirror"
}

main() {
    local version="$DEFAULT_MAVEN_VERSION"
    local upgrade_mode=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version)
                require_option_value "$1" "${2:-}"
                version="$2"
                shift 2
                ;;
            -d|--dir)
                require_option_value "$1" "${2:-}"
                INSTALL_DIR="$(normalize_install_dir "$2")"
                shift 2
                ;;
            -r|--repo)
                require_option_value "$1" "${2:-}"
                LOCAL_REPO="${2/#\~/$HOME}"
                shift 2
                ;;
            -m|--mirror)
                require_option_value "$1" "${2:-}"
                case "${2:-}" in
                    aliyun)
                        USE_MIRROR="$MAVEN_MIRROR_ALIYUN"
                        USE_MIRROR_ID="aliyun-maven"
                        USE_MIRROR_NAME="Aliyun Maven"
                        ;;
                    tencent)
                        USE_MIRROR="$MAVEN_MIRROR_TENCENT"
                        USE_MIRROR_ID="tencent-maven"
                        USE_MIRROR_NAME="Tencent Maven"
                        ;;
                    huawei)
                        USE_MIRROR="$MAVEN_MIRROR_HUAWEI"
                        USE_MIRROR_ID="huawei-maven"
                        USE_MIRROR_NAME="Huawei Cloud Maven"
                        ;;
                    official)
                        USE_MIRROR="$MAVEN_MIRROR_OFFICIAL"
                        USE_MIRROR_ID="official-maven"
                        USE_MIRROR_NAME="Official Maven"
                        ;;
                    *)
                        error "Unsupported mirror: ${2:-}"
                        error "Supported mirrors: aliyun, tencent, huawei, official"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -l|--latest)
                version=$(get_latest_version)
                shift
                ;;
            -u|--upgrade)
                upgrade_mode=true
                shift
                ;;
            --skip-settings)
                SKIP_SETTINGS=true
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
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    if [[ "$upgrade_mode" == true ]]; then
        version=$(get_latest_version)
        local current_version
        current_version=$(get_current_version)
        if [[ -n "$current_version" && "$current_version" == "$version" ]]; then
            success "Maven is already up to date (version $version)"
            exit 0
        fi
        if [[ -n "$current_version" ]]; then
            info "Upgrading Maven from $current_version to $version"
        else
            info "Maven not found, installing latest version $version"
        fi
    fi

    info "Installing Maven $version..."
    info "Install dir: $INSTALL_DIR"
    info "Local repository: $LOCAL_REPO"
    if [[ "$UNINSTALL_MODE" == true ]]; then
        uninstall_maven
        exit 0
    fi
    if [[ "$SKIP_SETTINGS" == false ]]; then
        if [[ -n "$USE_MIRROR" ]]; then
            info "Dependency mirror: $USE_MIRROR_NAME ($USE_MIRROR)"
        else
            info "Dependency mirror: official Maven repositories"
        fi
    fi
    
    # 先检查是否已安装
    local extract_dir="$INSTALL_DIR/apache-maven-$version"
    if [[ -d "$extract_dir" ]]; then
        if [[ "$upgrade_mode" == true ]]; then
            install_maven "$version"
            configure_maven_settings
            configure_shell
            success "Maven upgraded to version $version successfully!"
        else
            warn "Maven $version already installed, skipping download..."
            install_maven "$version"
            configure_maven_settings
            configure_shell
            success "Maven $version is already installed!"
        fi
        info "Run: source ~/.bashrc (or ~/.zshrc)"
        info "Verify: mvn -version"
        exit 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[Dry-run] Would download Maven $version"
    else
        if ! download_maven "$version"; then
            exit 1
        fi
    fi
    
    install_maven "$version"
    configure_maven_settings
    configure_shell

    if [[ "$DRY_RUN" == true ]]; then
        success "Dry-run completed"
        exit 0
    fi
    
    if [[ "$upgrade_mode" == true ]]; then
        success "Maven upgraded to version $version successfully!"
    else
        success "Maven $version installed successfully!"
    fi
    info "Run: source ~/.bashrc (or ~/.zshrc)"
    info "Verify: mvn -version"
}

main "$@"
