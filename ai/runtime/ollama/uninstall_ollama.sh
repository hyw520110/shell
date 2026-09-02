#!/usr/bin/env bash
###############################################################################
# Ollama 完整卸载脚本
# 功能: 删除 Ollama 程序、模型、配置、容器、服务
# 用法: bash uninstall_ollama.sh
###############################################################################
set -euo pipefail

# --------------------------- 颜色输出 ----------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
step()    { echo -e "${CYAN}[STEP]${NC} ${BOLD}$*${NC}"; }

# --------------------------- 帮助信息 ----------------------------------------
usage() {
  cat <<EOF
${BOLD}Ollama 完整卸载脚本${NC}

用法: $0 [选项]

选项:
  -a, --all             卸载所有内容（默认）
  -p, --program         仅卸载 Ollama 程序
  -m, --models          仅删除模型
  -c, --config          仅删除配置
  -d, --docker          仅删除 Docker 容器/镜像
  -s, --service         仅删除系统服务
  --dry-run             仅显示将要删除的内容，不实际执行
  -f, --force           强制删除，不询问确认
  -h, --help            显示帮助

示例:
  $0                              # 交互式完整卸载
  $0 --all --force                # 强制完整卸载（无提示）
  $0 --models --force             # 仅强制删除模型
  $0 --dry-run                    # 预览将删除的内容
EOF
  exit 0
}

# --------------------------- 参数解析 ----------------------------------------
UNINSTALL_ALL=false
UNINSTALL_PROGRAM=false
UNINSTALL_MODELS=false
UNINSTALL_CONFIG=false
UNINSTALL_DOCKER=false
UNINSTALL_SERVICE=false
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--all) UNINSTALL_ALL=true; shift;;
    -p|--program) UNINSTALL_PROGRAM=true; shift;;
    -m|--models) UNINSTALL_MODELS=true; shift;;
    -c|--config) UNINSTALL_CONFIG=true; shift;;
    -d|--docker) UNINSTALL_DOCKER=true; shift;;
    -s|--service) UNINSTALL_SERVICE=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -f|--force) FORCE=true; shift;;
    -h|--help) usage;;
    *) error "未知参数: $1"; usage;;
  esac
done

# 默认行为：如果未指定任何选项，则执行完整卸载
if ! $UNINSTALL_PROGRAM && ! $UNINSTALL_MODELS && ! $UNINSTALL_CONFIG && \
   ! $UNINSTALL_DOCKER && ! $UNINSTALL_SERVICE; then
  UNINSTALL_ALL=true
fi

# --------------------------- 系统检测 ----------------------------------------
detect_os() {
  if [[ "$(uname)" == "Darwin" ]]; then
    OS="macos"
    info "检测到 macOS"
  else
    OS="linux"
    if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      DISTRO="${ID}"
      info "检测到 Linux: ${DISTRO}"
    fi
  fi
}

# --------------------------- 确认提示 ----------------------------------------
confirm() {
  if $FORCE; then
    return 0
  fi
  
  if $DRY_RUN; then
    return 0
  fi
  
  read -rp "$1 [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# --------------------------- 停止进程 ----------------------------------------
stop_processes() {
  step "停止 Ollama 相关进程..."
  
  if $DRY_RUN; then
    info "[预览] 将停止以下进程:"
    pgrep -fl "ollama" 2>/dev/null || info "未检测到 Ollama 进程"
    return
  fi
  
  # 停止 Docker 容器
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    local containers
    containers=$(docker ps --filter "name=ollama" --format '{{.Names}}' 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
      info "停止 Docker 容器: $containers"
      echo "$containers" | while read -r container; do
        docker stop "$container" && success "容器 ${container} 已停止" || warn "停止容器 ${container} 失败"
      done
    fi
  fi
  
  # 停止系统服务
  if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet ollama.service 2>/dev/null; then
      info "停止 ollama.service..."
      sudo systemctl stop ollama.service && success "服务已停止" || warn "停止服务失败"
    fi
  fi
  
  # macOS LaunchAgent
  if [[ "$OS" == "macos" ]]; then
    if launchctl list | grep -q "com.ollama" 2>/dev/null; then
      info "停止 Ollama LaunchAgent..."
      launchctl stop com.ollama 2>/dev/null || true
    fi
  fi
  
  # 强制终止残留进程
  local pids
  pids=$(pgrep -f "ollama" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    info "终止残留进程..."
    echo "$pids" | while read -r pid; do
      kill "$pid" 2>/dev/null || true
      success "进程 ${pid} 已终止"
    done
    sleep 2
    # 强制 kill
    pids=$(pgrep -f "ollama" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      echo "$pids" | while read -r pid; do
        kill -9 "$pid" 2>/dev/null || true
      done
    fi
  fi
  
  success "所有 Ollama 进程已停止"
}

# --------------------------- 卸载程序 ----------------------------------------
uninstall_program() {
  step "卸载 Ollama 程序..."
  
  if $DRY_RUN; then
    info "[预览] 将执行以下操作:"
    [[ -f "/usr/local/bin/ollama" ]] && info "  删除: /usr/local/bin/ollama"
    [[ -d "/Applications/Ollama.app" ]] && info "  删除: /Applications/Ollama.app"
    info "  删除相关二进制文件"
    return
  fi
  
  case "$OS" in
    macos)
      # 删除命令行工具
      if [[ -f "/usr/local/bin/ollama" ]]; then
        info "删除 /usr/local/bin/ollama"
        sudo rm -f /usr/local/bin/ollama
      fi
      
      # 删除应用程序
      if [[ -d "/Applications/Ollama.app" ]]; then
        info "删除 /Applications/Ollama.app"
        sudo rm -rf /Applications/Ollama.app
      fi
      
      # 删除 Homebrew 安装
      if command -v brew &>/dev/null && brew list ollama &>/dev/null 2>&1; then
        info "卸载 Homebrew 版本的 Ollama"
        brew uninstall ollama
      fi
      ;;
      
    linux)
      # 使用官方卸载脚本（如果存在）
      if [[ -f "/usr/share/ollama/ollama" ]]; then
        info "删除 /usr/share/ollama"
        sudo rm -rf /usr/share/ollama
      fi
      
      # 删除二进制
      if [[ -f "/usr/local/bin/ollama" ]]; then
        info "删除 /usr/local/bin/ollama"
        sudo rm -f /usr/local/bin/ollama
      fi
      
      if [[ -f "/usr/bin/ollama" ]]; then
        info "删除 /usr/bin/ollama"
        sudo rm -f /usr/bin/ollama
      fi
      
      # 删除 ollama 用户（如果存在）
      if id "ollama" &>/dev/null; then
        info "删除 ollama 用户和用户组"
        sudo userdel -r ollama 2>/dev/null || true
      fi
      ;;
  esac
  
  # 验证
  if command -v ollama &>/dev/null; then
    warn "Ollama 仍然存在: $(which ollama)"
  else
    success "Ollama 程序已卸载"
  fi
}

# --------------------------- 删除模型 ----------------------------------------
uninstall_models() {
  step "删除 Ollama 模型..."
  
  # 列出将删除的模型
  if command -v ollama &>/dev/null; then
    info "当前已安装的模型:"
    ollama list 2>/dev/null || info "无法获取模型列表"
  fi
  
  if $DRY_RUN; then
    info "[预览] 将删除以下模型目录:"
    [[ -d "$HOME/.ollama/models" ]] && info "  $HOME/.ollama/models"
    [[ -d "/opt/ollama/models" ]] && info "  /opt/ollama/models"
    return
  fi
  
  if ! confirm "是否删除所有 Ollama 模型?"; then
    info "跳过模型删除"
    return
  fi
  
  # 删除用户目录模型
  if [[ -d "$HOME/.ollama/models" ]]; then
    local model_size
    model_size=$(du -sh "$HOME/.ollama/models" 2>/dev/null | cut -f1)
    info "删除 $HOME/.ollama/models (${model_size})"
    rm -rf "$HOME/.ollama/models"
    success "用户模型已删除"
  fi
  
  # 删除 /opt/ollama/models (Docker 挂载)
  if [[ -d "/opt/ollama/models" ]]; then
    local model_size
    model_size=$(du -sh "/opt/ollama/models" 2>/dev/null | cut -f1)
    info "删除 /opt/ollama/models (${model_size})"
    sudo rm -rf /opt/ollama/models
    success "Docker 模型已删除"
  fi
  
  success "所有模型已删除"
}

# --------------------------- 删除配置 ----------------------------------------
uninstall_config() {
  step "删除 Ollama 配置..."
  
  if $DRY_RUN; then
    info "[预览] 将删除以下配置:"
    [[ -d "$HOME/.ollama" ]] && info "  $HOME/.ollama"
    [[ -f "$HOME/.ollama/config.json" ]] && info "  $HOME/.ollama/config.json"
    [[ -d "$HOME/.config/ollama" ]] && info "  $HOME/.config/ollama"
    return
  fi
  
  if ! confirm "是否删除 Ollama 配置?"; then
    info "跳过配置删除"
    return
  fi
  
  # 删除配置目录
  local config_dirs=(
    "$HOME/.ollama"
    "$HOME/.config/ollama"
    "/etc/ollama"
  )
  
  for dir in "${config_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      info "删除 ${dir}"
      rm -rf "$dir" 2>/dev/null || sudo rm -rf "$dir" 2>/dev/null || true
    fi
  done
  
  # 删除日志
  local log_files=(
    "$HOME/ollama.log"
    "$HOME/.ollama/logs"
  )
  
  for log in "${log_files[@]}"; do
    if [[ -e "$log" ]]; then
      info "删除 ${log}"
      rm -rf "$log" 2>/dev/null || true
    fi
  done
  
  success "配置已删除"
}

# --------------------------- 删除 Docker 资源 --------------------------------
uninstall_docker() {
  step "删除 Docker 相关资源..."
  
  if ! command -v docker &>/dev/null; then
    info "Docker 未安装，跳过"
    return
  fi
  
  if ! docker info &>/dev/null; then
    info "Docker 守护进程未运行，跳过"
    return
  fi
  
  if $DRY_RUN; then
    info "[预览] 将删除以下 Docker 资源:"
    docker ps -a --filter "name=ollama" --format "  容器: {{.Names}}" 2>/dev/null || true
    docker ps -a --filter "name=open-webui" --format "  容器: {{.Names}}" 2>/dev/null || true
    docker images --filter "reference=ollama/ollama" --format "  镜像: {{.Repository}}:{{.Tag}}" 2>/dev/null || true
    docker images --filter "reference=*open-webui*" --format "  镜像: {{.Repository}}:{{.Tag}}" 2>/dev/null || true
    docker volume ls --filter "name=ollama" --format "  卷: {{.Name}}" 2>/dev/null || true
    return
  fi
  
  if ! confirm "是否删除 Ollama 相关的 Docker 容器、镜像和卷?"; then
    info "跳过 Docker 资源删除"
    return
  fi
  
  # 停止并删除容器
  local containers
  containers=$(docker ps -a --filter "name=ollama" --filter "name=open-webui" --format '{{.Names}}' 2>/dev/null || true)
  if [[ -n "$containers" ]]; then
    info "删除容器..."
    echo "$containers" | while read -r container; do
      info "删除容器: ${container}"
      docker rm -f "$container" 2>/dev/null && success "容器 ${container} 已删除" || warn "删除容器 ${container} 失败"
    done
  fi
  
  # 删除镜像
  local images
  images=$(docker images --filter "reference=ollama/ollama" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
  images+=" "
  images+=$(docker images --filter "reference=*open-webui*" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
  
  if [[ -n "$images" ]]; then
    info "删除镜像..."
    echo "$images" | tr ' ' '\n' | while read -r image; do
      [[ -z "$image" ]] && continue
      info "删除镜像: ${image}"
      docker rmi -f "$image" 2>/dev/null && success "镜像 ${image} 已删除" || warn "删除镜像 ${image} 失败"
    done
  fi
  
  # 删除卷（可选）
  local volumes
  volumes=$(docker volume ls --filter "name=ollama" --format '{{.Name}}' 2>/dev/null || true)
  if [[ -n "$volumes" ]]; then
    info "删除数据卷..."
    echo "$volumes" | while read -r volume; do
      info "删除卷: ${volume}"
      docker volume rm -f "$volume" 2>/dev/null && success "卷 ${volume} 已删除" || warn "删除卷 ${volume} 失败"
    done
  fi
  
  success "Docker 资源已清理"
}

# --------------------------- 删除系统服务 ------------------------------------
uninstall_service() {
  step "删除系统服务..."
  
  if $DRY_RUN; then
    info "[预览] 将删除以下服务:"
    [[ -f "/etc/systemd/system/ollama.service" ]] && info "  /etc/systemd/system/ollama.service"
    [[ -f "/etc/systemd/system/ollama.service.d/" ]] && info "  /etc/systemd/system/ollama.service.d/"
    [[ -f "$HOME/Library/LaunchAgents/com.ollama.plist" ]] && info "  $HOME/Library/LaunchAgents/com.ollama.plist"
    return
  fi
  
  if ! confirm "是否删除 Ollama 系统服务?"; then
    info "跳过服务删除"
    return
  fi
  
  case "$OS" in
    linux)
      # systemd 服务
      if [[ -f "/etc/systemd/system/ollama.service" ]]; then
        info "停止并删除 ollama.service"
        sudo systemctl stop ollama.service 2>/dev/null || true
        sudo systemctl disable ollama.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/ollama.service
        sudo systemctl daemon-reload
        success "systemd 服务已删除"
      fi
      
      # 服务配置目录
      if [[ -d "/etc/systemd/system/ollama.service.d" ]]; then
        sudo rm -rf /etc/systemd/system/ollama.service.d
      fi
      
      # 环境变量文件
      if [[ -f "/etc/ollama/env" ]]; then
        sudo rm -f /etc/ollama/env
      fi
      ;;
      
    macos)
      # LaunchAgent
      local plist_files=(
        "$HOME/Library/LaunchAgents/com.ollama.plist"
        "/Library/LaunchAgents/com.ollama.plist"
        "/Library/LaunchDaemons/com.ollama.plist"
      )
      
      for plist in "${plist_files[@]}"; do
        if [[ -f "$plist" ]]; then
          info "卸载并删除 ${plist}"
          launchctl unload "$plist" 2>/dev/null || true
          rm -f "$plist" 2>/dev/null || sudo rm -f "$plist" 2>/dev/null || true
        fi
      done
      ;;
  esac
  
  success "系统服务已删除"
}

# --------------------------- 清理其他残留 ------------------------------------
cleanup_residuals() {
  step "清理其他残留文件..."
  
  if $DRY_RUN; then
    info "[预览] 将清理以下残留:"
    [[ -d "/opt/ollama" ]] && info "  /opt/ollama"
    [[ -d "/var/lib/ollama" ]] && info "  /var/lib/ollama"
    return
  fi
  
  # 删除安装下载文件
  local download_files=(
    "$HOME/Downloads/ollama-linux-amd64"
    "$HOME/Downloads/ollama-linux-amd64.tgz"
    "$HOME/Downloads/ollama-darwin.zip"
  )
  
  for file in "${download_files[@]}"; do
    for f in ${file}*; do
      if [[ -e "$f" ]]; then
        info "删除 ${f}"
        rm -f "$f"
      fi
    done
  done
  
  # 删除 /opt/ollama
  if [[ -d "/opt/ollama" ]]; then
    info "删除 /opt/ollama"
    sudo rm -rf /opt/ollama
  fi
  
  # 删除 /var/lib/ollama (Linux)
  if [[ -d "/var/lib/ollama" ]]; then
    info "删除 /var/lib/ollama"
    sudo rm -rf /var/lib/ollama
  fi
  
  success "残留文件已清理"
}

# --------------------------- 卸载报告 ----------------------------------------
print_report() {
  echo ""
  echo -e "${BOLD}========================================${NC}"
  echo -e "${GREEN}  Ollama 卸载完成!${NC}"
  echo -e "${BOLD}========================================${NC}"
  echo ""
  
  info "验证卸载:"
  if command -v ollama &>/dev/null; then
    warn "Ollama 仍然存在: $(which ollama)"
    warn "请手动删除或检查是否有其他安装方式"
  else
    success "✓ Ollama 程序已删除"
  fi
  
  if [[ -d "$HOME/.ollama" ]]; then
    warn "配置目录仍存在: $HOME/.ollama"
  else
    success "✓ 配置目录已删除"
  fi
  
  echo ""
  info "如需完全重新安装 Ollama，请执行:"
  echo -e "  ${CYAN}curl -fsSL https://ollama.com/install.sh | sh${NC}"
  echo ""
}

# --------------------------- 主流程 ------------------------------------------
main() {
  echo ""
  echo -e "${BOLD}========================================${NC}"
  echo -e "${RED}  Ollama 完整卸载脚本${NC}"
  echo -e "${BOLD}========================================${NC}"
  echo ""
  
  detect_os
  
  # 显示将执行的操作
  info "即将执行的操作:"
  $UNINSTALL_ALL && echo -e "  ${YELLOW}• 停止所有 Ollama 进程${NC}"
  $UNINSTALL_ALL && echo -e "  ${YELLOW}• 卸载 Ollama 程序${NC}"
  $UNINSTALL_ALL && echo -e "  ${YELLOW}• 删除所有模型${NC}"
  $UNINSTALL_ALL && echo -e "  ${YELLOW}• 删除配置文件${NC}"
  $UNINSTALL_ALL && echo -e "  ${YELLOW}• 删除 Docker 资源${NC}"
  $UNINSTALL_ALL && echo -e "  ${YELLOW}• 删除系统服务${NC}"
  $UNINSTALL_ALL && echo -e "  ${YELLOW}• 清理残留文件${NC}"
  echo ""
  
  if $DRY_RUN; then
    info "=== 预览模式：以下操作将不会实际执行 ==="
    echo ""
  elif ! $FORCE; then
    if ! confirm "是否继续?"; then
      info "操作已取消"
      exit 0
    fi
    echo ""
  fi
  
  # 停止进程（总是执行）
  stop_processes
  echo ""
  
  # 根据选项执行
  if $UNINSTALL_ALL || $UNINSTALL_PROGRAM; then
    uninstall_program
    echo ""
  fi
  
  if $UNINSTALL_ALL || $UNINSTALL_MODELS; then
    uninstall_models
    echo ""
  fi
  
  if $UNINSTALL_ALL || $UNINSTALL_CONFIG; then
    uninstall_config
    echo ""
  fi
  
  if $UNINSTALL_ALL || $UNINSTALL_DOCKER; then
    uninstall_docker
    echo ""
  fi
  
  if $UNINSTALL_ALL || $UNINSTALL_SERVICE; then
    uninstall_service
    echo ""
  fi
  
  if $UNINSTALL_ALL; then
    cleanup_residuals
    echo ""
  fi
  
  print_report
}

# 执行
main "$@"
