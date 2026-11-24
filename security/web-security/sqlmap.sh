#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/web-tools-common.sh"

readonly SQLMAP_TARGET="$WEB_TOOLS_ROOT/sqlmap"
readonly SQLMAP_LINK="$WEB_TOOLS_BIN/sqlmap"

show_help() {
  cat <<'EOF'
SQLMap 安装、更新与授权测试脚本

用法：
  install-sqlmap.sh [install] [--dry-run]
  install-sqlmap.sh update|status|uninstall
  install-sqlmap.sh test <URL> [SQLMap 参数...]
  install-sqlmap.sh test-deep <URL> [SQLMap 参数...]
  install-sqlmap.sh dbs <URL> [SQLMap 参数...]
  install-sqlmap.sh tables <URL> <数据库> [SQLMap 参数...]
  install-sqlmap.sh dump <URL> <数据库> <表> [SQLMap 参数...]

选项：
  --dry-run   只显示计划，不执行安装或扫描
  -h, --help  显示帮助

示例：
  install-sqlmap.sh install
  install-sqlmap.sh test 'https://授权目标.example/item?id=1'
  install-sqlmap.sh test 'https://授权目标.example/item?id=1' --data 'id=1'
  install-sqlmap.sh dbs 'https://授权目标.example/item?id=1'

警告：仅允许对已获得明确授权的目标进行测试。
EOF
}

die_usage() {
  web_die "$1；运行 install-sqlmap.sh --help 查看用法。"
}

is_installed() {
  [[ -f "$SQLMAP_TARGET/sqlmap.py" ]] && [[ -x "$SQLMAP_LINK" || -L "$SQLMAP_LINK" ]]
}

ensure_installed() {
  is_installed || web_die 'SQLMap 尚未安装，请先执行 install-sqlmap.sh install。'
}

print_command() {
  printf '[web-tools] 执行：'
  printf '%q ' "$@"
  printf '\n'
}

write_launcher() {
  cat > "$SQLMAP_LINK" <<EOF
#!/usr/bin/env bash
exec python3 "$SQLMAP_TARGET/sqlmap.py" "\$@"
EOF
  chmod +x "$SQLMAP_LINK"
}

install_sqlmap() {
  web_show_plan sqlmap 'SQL 注入专项测试'
  [[ "$WEB_TOOLS_DRY_RUN" -eq 1 ]] && { web_log '预演模式：未执行任何安装。'; return 0; }
  web_require_platform
  web_install_prerequisites git python3
  web_prepare

  if [[ ! -f "$SQLMAP_TARGET/sqlmap.py" ]]; then
    git clone --depth 1 https://github.com/sqlmapproject/sqlmap.git "$SQLMAP_TARGET"
  else
    web_log 'sqlmap 已存在，跳过下载。'
  fi
  write_launcher
  web_finish sqlmap
}

update_sqlmap() {
  ensure_installed
  [[ "$WEB_TOOLS_DRY_RUN" -eq 1 ]] && { web_log "预演模式：将更新 $SQLMAP_TARGET。"; return 0; }
  if [[ -d "$SQLMAP_TARGET/.git" ]]; then
    git -C "$SQLMAP_TARGET" pull --ff-only
  else
    web_die 'SQLMap 安装目录不是 Git 仓库，请执行 uninstall 后重新 install。'
  fi
  write_launcher
  web_ok 'sqlmap 更新完成。'
}

status_sqlmap() {
  if ! is_installed; then
    web_warn 'sqlmap 未安装。'
    return 1
  fi
  web_ok "sqlmap 已安装：$SQLMAP_LINK"
  [[ "$WEB_TOOLS_DRY_RUN" -eq 1 ]] || sqlmap --version 2>/dev/null || true
}

uninstall_sqlmap() {
  [[ "$WEB_TOOLS_DRY_RUN" -eq 1 ]] && {
    web_log "预演模式：将删除 $SQLMAP_TARGET 和 $SQLMAP_LINK。"
    return 0
  }
  rm -f -- "$SQLMAP_LINK"
  rm -rf -- "$SQLMAP_TARGET"
  web_ok 'sqlmap 已卸载。'
}

run_scan() {
  local mode="$1"
  shift
  local url="${1:-}"
  shift || true
  local database=""
  local table=""

  [[ -n "$url" ]] || die_usage "$mode 需要 URL"
  case "$mode" in
    tables)
      database="${1:-}"
      [[ -n "$database" ]] || die_usage 'tables 需要数据库名'
      shift
      ;;
    dump)
      database="${1:-}"
      table="${2:-}"
      [[ -n "$database" && -n "$table" ]] || die_usage 'dump 需要数据库名和表名'
      shift 2
      ;;
  esac

  local -a command_args=(sqlmap -u "$url" --batch --no-logging)
  case "$mode" in
    test) command_args+=(--level=1 --risk=1) ;;
    test-deep) command_args+=(--level=3 --risk=2) ;;
    dbs) command_args+=(--dbs) ;;
    tables) command_args+=(--tables -D "$database") ;;
    dump) command_args+=(--dump -D "$database" -T "$table") ;;
    *) die_usage "不支持的扫描模式：$mode" ;;
  esac
  command_args+=("$@")

  print_command "${command_args[@]}"
  [[ "$WEB_TOOLS_DRY_RUN" -eq 1 ]] && return 0
  ensure_installed
  echo '[警告] 仅允许对已获得明确授权的目标进行测试。'
  "${command_args[@]}"
}

main() {
  local action="install"
  local dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) show_help; return 0 ;;
      --dry-run) dry_run=1; shift ;;
      install|update|status|uninstall|test|test-deep|dbs|tables|dump)
        action="$1"
        shift
        break
        ;;
      *) die_usage "未知参数：$1" ;;
    esac
  done

  local -a remaining_args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == '--dry-run' ]]; then
      dry_run=1
    else
      remaining_args+=("$1")
    fi
    shift
  done
  set -- "${remaining_args[@]}"

  WEB_TOOLS_DRY_RUN="$dry_run"
  case "$action" in
    install) install_sqlmap ;;
    update) update_sqlmap ;;
    status) status_sqlmap ;;
    uninstall) uninstall_sqlmap ;;
    test|test-deep|dbs|tables|dump) run_scan "$action" "$@" ;;
  esac
}

main "$@"
