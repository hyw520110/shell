#!/usr/bin/env bash
# =============================================================================
# service.sh - mihomo 服务管理脚本
# -----------------------------------------------------------------------------
# - 跨平台：Linux (systemd) + macOS (LaunchAgent)
# - 功能：状态查看、启动/停止/重启、自启管理、节点选择/切换、延迟测试
# - 依赖：mihomo 已通过 install.sh 安装
# -----------------------------------------------------------------------------
# 用法:
#   sudo ./service.sh status                  # 查看运行状态
#   sudo ./service.sh start                   # 启动服务
#   sudo ./service.sh stop                    # 停止服务
#   sudo ./service.sh restart                 # 重启服务
#   sudo ./service.sh enable                  # 开机自启
#   sudo ./service.sh disable                 # 禁用自启
#   ./service.sh log [N]                      # 查看最近 N 行日志（默认 50）
#   ./service.sh nodes                        # 列出所有节点及延迟
#   ./service.sh select [GROUP]               # 选择节点（交互式）
#   ./service.sh switch <NODE> [GROUP]        # 切换到指定节点（非交互式）
#   ./service.sh test [NODE]                  # 测试节点延迟（默认测试所有）
#   ./service.sh api                          # 显示 API 信息
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 颜色输出
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR ]${NC}  $*" >&2; }

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
SERVICE_NAME="mihomo"
BINARY_NAME="mihomo"
CONFIG_DIR="/etc/mihomo"
API_HOST="127.0.0.1"
API_PORT="9090"
API_SECRET=""
API_BASE="http://${API_HOST}:${API_PORT}"

# macOS 适配
if [ "$(uname -s)" = "Darwin" ]; then
  # 用户级安装时使用用户配置目录
  if [ -d "${HOME}/.config/mihomo" ] && [ ! -d "$CONFIG_DIR" ]; then
    CONFIG_DIR="${HOME}/.config/mihomo"
  fi
fi

CONFIG_FILE="${CONFIG_DIR}/config.yaml"

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: sudo ./service.sh [OPTIONS] COMMAND

COMMAND:
  status              查看服务运行状态
  start               启动服务
  stop                停止服务
  restart             重启服务
  enable              开启开机自启
  disable             禁用开机自启
  log [N]             查看最近 N 行日志（默认 50）
  nodes               列出所有节点及延迟
  groups              列出所有代理组
  select [GROUP]      交互式选择节点（默认组: 节点选择）
  switch NODE [GROUP] 切换到指定节点（非交互式）
  test [NODE]         测试节点延迟（默认测试所有节点）
  api                 显示 API 信息和连接测试
  reload              重新加载配置（无需重启服务）

OPTIONS:
  --help, -h          显示本帮助

示例:
  sudo ./service.sh status
  sudo ./service.sh restart
  ./service.sh nodes
  ./service.sh select                    # 交互式选择
  ./service.sh switch "香港节点-01"       # 切换节点
  ./service.sh test "香港节点-01"         # 测试单个节点
  ./service.sh test                      # 测试所有节点
EOF
}

ACTION=""
ARG1=""
ARG2=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    status|start|stop|restart|enable|disable|nodes|groups|select|switch|test|api|reload|log)
      ACTION="$1"
      shift
      # 收集剩余参数
      [ $# -ge 1 ] && ARG1="$1" && shift
      [ $# -ge 1 ] && ARG2="$1" && shift
      ;;
    *)
      error "未知参数: $1"
      usage
      exit 2
      ;;
  esac
done

[ -z "$ACTION" ] && { usage; exit 1; }

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
is_macos() { [ "$(uname -s)" = "Darwin" ]; }

# 读取 API 配置（secret）
load_api_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local secret
  secret="$(grep -E '^[[:space:]]*secret:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/^[[:space:]]*secret:[[:space:]]*//' | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")"
  [ -n "$secret" ] && API_SECRET="$secret"
  if [ -n "$API_SECRET" ]; then
    API_BASE="http://${API_HOST}:${API_PORT}?secret=${API_SECRET}"
  else
    API_BASE="http://${API_HOST}:${API_PORT}"
  fi
}

# API 请求
api_get() {
  local path="$1"
  local url="${API_BASE}${path}"
  # 优先用 curl
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$API_SECRET" ]; then
      curl -sSL --max-time 10 -H "Authorization: Bearer ${API_SECRET}" "http://${API_HOST}:${API_PORT}${path}" 2>/dev/null
    else
      curl -sSL --max-time 10 "http://${API_HOST}:${API_PORT}${path}" 2>/dev/null
    fi
  else
    error "未找到 curl 命令"
    return 1
  fi
}

api_put() {
  local path="$1"
  local data="$2"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$API_SECRET" ]; then
      curl -sSL --max-time 10 -X PUT -H "Authorization: Bearer ${API_SECRET}" -H "Content-Type: application/json" -d "$data" "http://${API_HOST}:${API_PORT}${path}" 2>/dev/null
    else
      curl -sSL --max-time 10 -X PUT -H "Content-Type: application/json" -d "$data" "http://${API_HOST}:${API_PORT}${path}" 2>/dev/null
    fi
  else
    error "未找到 curl 命令"
    return 1
  fi
}

# 需要管理员权限的操作检查
require_root() {
  if ! is_macos; then
    if [ "$(id -u)" -ne 0 ]; then
      error "此操作需要 root 权限，请使用 sudo"
      exit 1
    fi
  fi
}

# URL 编码（用于节点名称，支持 UTF-8 多字节字符）
url_encode() {
  local str="$1"
  # 优先使用 python3（正确处理 UTF-8 多字节字符）
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse, sys; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=''))" "$str"
    return
  fi
  # 回退方案：使用 jq（如果可用）
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$str" | jq -sRr @uri
    return
  fi
  # 最后回退：使用 perl
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$str" | perl -MURI::Escape -ne 'chomp; print uri_escape($_)'
    return
  fi
  # 兜底：原样输出（API 可能返回 404）
  echo "$str"
}

# JSON 简单解析（无 python3 时使用 grep/sed）
# 用法: json_get_value "key" < json_input
json_get_value() {
  local key="$1"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"?[^\"]*\"?" | sed -E "s/\"${key}\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"$//"
}

# ---------------------------------------------------------------------------
# 服务管理
# ---------------------------------------------------------------------------
cmd_status() {
  info "=== mihomo 服务状态 ==="

  if is_macos; then
    local plist="${HOME}/Library/LaunchAgents/com.mihomo.plist"
    if [ -f "$plist" ]; then
      local label
      label="$(defaults read "$plist" Label 2>/dev/null || echo 'com.mihomo')"
      if launchctl list 2>/dev/null | grep -q "$label"; then
        ok "LaunchAgent 已加载: $label"
      else
        warn "LaunchAgent 未加载"
      fi
    else
      warn "未找到 LaunchAgent: $plist"
    fi
  else
    if systemctl is-active mihomo >/dev/null 2>&1; then
      ok "systemd 服务: active (running)"
    else
      warn "systemd 服务: $(systemctl is-active mihomo 2>/dev/null || echo 'unknown')"
    fi
    if systemctl is-enabled mihomo >/dev/null 2>&1; then
      ok "开机自启: enabled"
    else
      warn "开机自启: disabled"
    fi
  fi

  echo ""
  info "=== 进程信息 ==="
  if pgrep -x "$BINARY_NAME" >/dev/null 2>&1; then
    local pid
    pid="$(pgrep -x "$BINARY_NAME" | head -1)"
    ok "进程运行中 (PID: $pid)"
    ps -p "$pid" -o pid,user,%mem,%cpu,etime,command --no-headers 2>/dev/null || true
  else
    warn "进程未运行"
  fi

  echo ""
  info "=== 端口监听 ==="
  local mixed_port api_port
  mixed_port="$(grep -E '^[[:space:]]*mixed-port:' "$CONFIG_FILE" 2>/dev/null | awk '{print $2}')"
  api_port="$(grep -E '^[[:space:]]*external-controller:' "$CONFIG_FILE" 2>/dev/null | awk -F'[:]' '{print $NF}')"
  mixed_port="${mixed_port:-7890}"
  api_port="${api_port:-9090}"

  if command -v ss >/dev/null 2>&1; then
    if ss -tlnp 2>/dev/null | grep -q ":${mixed_port} "; then
      ok "代理端口 ${mixed_port}: 监听中"
    else
      warn "代理端口 ${mixed_port}: 未监听"
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${api_port} "; then
      ok "API 端口 ${api_port}: 监听中"
    else
      warn "API 端口 ${api_port}: 未监听"
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tlnp 2>/dev/null | grep -q ":${mixed_port} "; then
      ok "代理端口 ${mixed_port}: 监听中"
    else
      warn "代理端口 ${mixed_port}: 未监听"
    fi
  fi

  echo ""
  info "=== 配置文件 ==="
  if [ -f "$CONFIG_FILE" ]; then
    ok "配置: $CONFIG_FILE ($(wc -l < "$CONFIG_FILE") 行)"
  else
    warn "配置文件不存在: $CONFIG_FILE"
  fi

  # API 连接测试
  echo ""
  info "=== API 连接 ==="
  load_api_config
  local version
  version="$(api_get '/version' 2>/dev/null || true)"
  if [ -n "$version" ]; then
    ok "API: $version"
  else
    warn "API 不可达（服务未运行或配置未启用 external-controller）"
  fi
}

cmd_start() {
  require_root
  info "启动 mihomo 服务..."
  if is_macos; then
    local plist="${HOME}/Library/LaunchAgents/com.mihomo.plist"
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist" 2>/dev/null || { error "启动失败"; exit 1; }
  else
    systemctl start mihomo || { error "启动失败"; exit 1; }
  fi
  sleep 2
  if pgrep -x "$BINARY_NAME" >/dev/null 2>&1; then
    ok "mihomo 已启动 (PID: $(pgrep -x "$BINARY_NAME" | head -1))"
  else
    error "启动后未检测到进程，请查看日志: $0 log"
    exit 1
  fi
}

cmd_stop() {
  require_root
  info "停止 mihomo 服务..."
  if is_macos; then
    local plist="${HOME}/Library/LaunchAgents/com.mihomo.plist"
    launchctl unload "$plist" 2>/dev/null || true
  else
    systemctl stop mihomo 2>/dev/null || true
  fi
  sleep 1
  if pgrep -x "$BINARY_NAME" >/dev/null 2>&1; then
    warn "进程仍在运行，强制终止..."
    pkill -TERM -x "$BINARY_NAME" 2>/dev/null || true
    sleep 2
    pkill -KILL -x "$BINARY_NAME" 2>/dev/null || true
  fi
  ok "mihomo 已停止"
}

cmd_restart() {
  require_root
  info "重启 mihomo 服务..."
  if is_macos; then
    cmd_stop
    sleep 1
    cmd_start
  else
    systemctl restart mihomo || { error "重启失败"; exit 1; }
    sleep 2
    if pgrep -x "$BINARY_NAME" >/dev/null 2>&1; then
      ok "mihomo 已重启 (PID: $(pgrep -x "$BINARY_NAME" | head -1))"
    else
      error "重启后未检测到进程"
      exit 1
    fi
  fi
}

cmd_enable() {
  require_root
  info "开启 mihomo 开机自启..."
  if is_macos; then
    local plist="${HOME}/Library/LaunchAgents/com.mihomo.plist"
    if [ -f "$plist" ]; then
      # 确保 RunAtLoad 为 true
      defaults read "$plist" RunAtLoad >/dev/null 2>&1 || true
      launchctl load "$plist" 2>/dev/null || true
      ok "LaunchAgent 已启用: $plist"
    else
      error "LaunchAgent 文件不存在: $plist"
      exit 1
    fi
  else
    systemctl enable mihomo || { error "启用失败"; exit 1; }
    ok "开机自启已启用"
  fi
}

cmd_disable() {
  require_root
  info "禁用 mihomo 开机自启..."
  if is_macos; then
    local plist="${HOME}/Library/LaunchAgents/com.mihomo.plist"
    launchctl unload "$plist" 2>/dev/null || true
    ok "LaunchAgent 已卸载"
  else
    systemctl disable mihomo || { error "禁用失败"; exit 1; }
    ok "开机自启已禁用"
  fi
}

cmd_log() {
  local lines="${ARG1:-50}"
  info "最近 ${lines} 行日志:"
  if is_macos; then
    local log_file="${CONFIG_DIR}/mihomo.log"
    [ -f "$log_file" ] || { warn "日志文件不存在: $log_file"; exit 1; }
    tail -n "$lines" "$log_file"
  else
    journalctl -u mihomo --no-pager -n "$lines"
  fi
}

# ---------------------------------------------------------------------------
# 节点管理
# ---------------------------------------------------------------------------
# 获取所有代理组
get_groups() {
  api_get '/proxies' | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for name, p in d.get("proxies", {}).items():
    ptype = p.get("type", "")
    if ptype in ("Selector", "URLTest", "Fallback", "LoadBalance"):
        now = p.get("now", "")
        all_proxies = p.get("all", [])
        print(f"{name}|{ptype}|{now}|{len(all_proxies)}")
' 2>/dev/null
}

# 获取所有节点
get_nodes() {
  api_get '/proxies' | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for name, p in d.get("proxies", {}).items():
    ptype = p.get("type", "")
    if ptype in ("Vless", "VLESS", "Trojan", "Shadowsocks", "Vmess", "ShadowsocksR", "Snell", "Http", "Socks5"):
        hist = p.get("history", [])
        delay = hist[-1].get("delay", 0) if hist else 0
        alive = p.get("alive", False)
        print(f"{name}|{ptype}|{alive}|{delay}")
' 2>/dev/null
}

cmd_groups() {
  load_api_config
  info "=== 代理组列表 ==="
  local groups
  groups="$(get_groups)"
  if [ -z "$groups" ]; then
    error "无法获取代理组（API 不可达或无 python3）"
    exit 1
  fi

  printf "%-20s %-12s %-25s %s\n" "组名" "类型" "当前节点" "节点数"
  printf "%-20s %-12s %-25s %s\n" "----" "----" "--------" "----"
  echo "$groups" | while IFS='|' read -r name ptype now count; do
    printf "%-20s %-12s %-25s %s\n" "$name" "$ptype" "$now" "$count"
  done
}

cmd_nodes() {
  load_api_config
  info "=== 节点列表 ==="
  local nodes
  nodes="$(get_nodes)"
  if [ -z "$nodes" ]; then
    error "无法获取节点列表（API 不可达或无 python3）"
    exit 1
  fi

  printf "%-25s %-12s %-8s %s\n" "节点名" "类型" "状态" "延迟"
  printf "%-25s %-12s %-8s %s\n" "-----" "----" "----" "----"
  echo "$nodes" | while IFS='|' read -r name ptype alive delay; do
    local status
    if [ "$alive" = "True" ]; then
      status="${GREEN}alive${NC}"
    else
      status="${RED}dead${NC}"
    fi
    local delay_str
    if [ "$delay" -gt 0 ] 2>/dev/null; then
      delay_str="${delay}ms"
    else
      delay_str="-"
    fi
    printf "%-25s %-12s %-8s %s\n" "$name" "$ptype" "$(echo -e "$status")" "$delay_str"
  done
}

cmd_select() {
  load_api_config
  local group="${ARG1:-节点选择}"
  info "选择节点（组: ${group}）"

  # 获取该组的所有节点
  local nodes_json
  nodes_json="$(api_get "/proxies/$(url_encode "$group")")"
  [ -z "$nodes_json" ] && { error "无法获取组: $group"; exit 1; }

  local current nodes
  current="$(echo "$nodes_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("now",""))' 2>/dev/null)"
  nodes="$(echo "$nodes_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(n) for n in d.get("all",[])]' 2>/dev/null)"

  [ -z "$nodes" ] && { error "组 $group 没有节点"; exit 1; }

  echo "当前节点: $current"
  echo ""
  echo "可用节点:"

  # 先把节点读入数组（避免管道子 shell 中 i 不累加的问题）
  local -a node_arr=()
  while IFS= read -r line; do
    [ -n "$line" ] && node_arr+=("$line")
  done <<< "$nodes"

  local total=${#node_arr[@]}
  local i
  for ((i=0; i<total; i++)); do
    local marker=""
    [ "${node_arr[$i]}" = "$current" ] && marker=" ← 当前"
    printf "  %2d) %s%s\n" "$((i+1))" "${node_arr[$i]}" "$marker"
  done

  echo ""
  read -r -p "请选择节点编号 (1-${total}): " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
    error "无效选择: $choice（有效范围 1-${total}）"
    exit 1
  fi

  local selected="${node_arr[$((choice-1))]}"
  info "切换到: $selected"
  switch_node "$group" "$selected"
}

# 切换节点（非交互式）
cmd_switch() {
  load_api_config
  local node="$ARG1"
  local group="${ARG2:-节点选择}"
  [ -z "$node" ] && { error "请指定节点名: $0 switch <NODE> [GROUP]"; exit 1; }
  info "切换节点: $node (组: $group)"
  switch_node "$group" "$node"
}

# 实际切换节点的函数
switch_node() {
  local group="$1"
  local node="$2"
  local encoded_group
  encoded_group="$(url_encode "$group")"

  local result
  result="$(api_put "/proxies/${encoded_group}" "{\"name\":\"${node}\"}" 2>/dev/null || true)"

  # 验证是否切换成功
  local current
  current="$(api_get "/proxies/${encoded_group}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("now",""))' 2>/dev/null || true)"

  if [ "$current" = "$node" ]; then
    ok "已切换到: $node"
  else
    error "切换失败，当前仍为: ${current:-未知}"
    exit 1
  fi
}

# 测试节点延迟
cmd_test() {
  load_api_config
  local node="$ARG1"

  if [ -n "$node" ]; then
    # 测试单个节点
    info "测试节点延迟: $node"
    local encoded
    encoded="$(url_encode "$node")"
    local result
    result="$(api_get "/proxies/${encoded}/delay?url=http://cp.cloudflare.com/generate_204&timeout=5000" 2>/dev/null || true)"
    if echo "$result" | grep -q '"delay"'; then
      local delay
      delay="$(echo "$result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("delay",0))' 2>/dev/null || echo 0)"
      if [ "$delay" -gt 0 ] 2>/dev/null; then
        ok "$node: ${delay}ms"
      else
        error "$node: 超时或不可达"
      fi
    else
      error "$node: 测试失败 - $result"
    fi
  else
    # 测试所有节点
    info "测试所有节点延迟..."
    local nodes
    nodes="$(get_nodes)"
    if [ -z "$nodes" ]; then
      error "无法获取节点列表"
      exit 1
    fi

    echo ""
    printf "%-25s %s\n" "节点名" "延迟"
    printf "%-25s %s\n" "-----" "----"

    echo "$nodes" | while IFS='|' read -r name ptype alive delay; do
      local encoded result new_delay
      encoded="$(url_encode "$name")"
      result="$(api_get "/proxies/${encoded}/delay?url=http://cp.cloudflare.com/generate_204&timeout=5000" 2>/dev/null || true)"
      new_delay="$(echo "$result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("delay",0))' 2>/dev/null || echo 0)"
      if [ "$new_delay" -gt 0 ] 2>/dev/null; then
        printf "%-25s %s\n" "$name" "${new_delay}ms"
      else
        printf "%-25s %s\n" "$name" "超时"
      fi
    done
  fi
}

cmd_api() {
  load_api_config
  info "=== mihomo API 信息 ==="
  echo "地址: http://${API_HOST}:${API_PORT}"
  [ -n "$API_SECRET" ] && echo "密钥: ${API_SECRET}" || echo "密钥: (无)"

  echo ""
  info "=== 连接测试 ==="
  local version
  version="$(api_get '/version' 2>/dev/null || true)"
  if [ -n "$version" ]; then
    ok "版本: $version"
  else
    error "API 不可达"
    exit 1
  fi

  echo ""
  info "=== 运行信息 ==="
  local config
  config="$(api_get '/configs' 2>/dev/null || true)"
  if [ -n "$config" ]; then
    # 通过环境变量传递 JSON，避免 stdin/引号问题
    local mode log_level port allow_lan tun_enable
    mode="$(CONFIG_JSON="$config" python3 -c 'import json,os; d=json.loads(os.environ["CONFIG_JSON"]); print(d.get("mode","unknown"))' 2>/dev/null || echo unknown)"
    log_level="$(CONFIG_JSON="$config" python3 -c 'import json,os; d=json.loads(os.environ["CONFIG_JSON"]); print(d.get("log-level","unknown"))' 2>/dev/null || echo unknown)"
    port="$(CONFIG_JSON="$config" python3 -c 'import json,os; d=json.loads(os.environ["CONFIG_JSON"]); print(d.get("mixed-port",d.get("port","unknown")))' 2>/dev/null || echo unknown)"
    allow_lan="$(CONFIG_JSON="$config" python3 -c 'import json,os; d=json.loads(os.environ["CONFIG_JSON"]); print(d.get("allow-lan","unknown"))' 2>/dev/null || echo unknown)"
    tun_enable="$(CONFIG_JSON="$config" python3 -c 'import json,os; d=json.loads(os.environ["CONFIG_JSON"]); print(d.get("tun",{}).get("enable",False))' 2>/dev/null || echo False)"
    echo "  运行模式: $mode"
    echo "  日志级别: $log_level"
    echo "  代理端口: $port"
    echo "  允许局域网: $allow_lan"
    echo "  TUN 模式: $tun_enable"
  fi
}

cmd_reload() {
  require_root
  load_api_config
  info "重新加载配置..."
  # 通过 API 热重载
  local result
  result="$(api_put '/configs?force=true' "{\"path\":\"${CONFIG_FILE}\"}" 2>/dev/null || true)"
  if [ -z "$result" ] || echo "$result" | grep -q '"code"'; then
    # API 热重载失败，回退到重启服务
    warn "API 热重载失败，尝试重启服务..."
    cmd_restart
  else
    ok "配置已重新加载"
  fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
case "$ACTION" in
  status)   cmd_status ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  enable)   cmd_enable ;;
  disable)  cmd_disable ;;
  log)      cmd_log ;;
  nodes)    cmd_nodes ;;
  groups)   cmd_groups ;;
  select)   cmd_select ;;
  switch)   cmd_switch ;;
  test)     cmd_test ;;
  api)      cmd_api ;;
  reload)   cmd_reload ;;
  *)
    error "未知命令: $ACTION"
    usage
    exit 1
    ;;
esac
