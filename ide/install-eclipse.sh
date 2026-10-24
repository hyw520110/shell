#!/bin/bash

# Eclipse IDE 一键安装 / 诊断 / 修复 / 升级脚本
#
# 典型故障场景（本脚本重点修复）：
#   用 Eclipse Installer 安装的 Eclipse 属于 "bundle pool" 安装，插件和 JRE
#   都在 ~/.p2 里；一旦 ~/.p2 被清理/删除，eclipse.ini 的 --launcher.library、
#   -vm 以及 configuration/.../bundles.info 里的路径全部失效。
#   此时双击图标毫无反应、命令行启动也静默退出（因为 dlopen 启动器库失败）。
#   这种安装无法靠改配置修好，只能"彻底删除后重装一个自包含的 EPP 包"。
#
# 升级能力（--update）：
#   * 自动探测最新正式版（按季度发布：03/06/09/12），也可指定版本
#   * 版本比较，已是最新则直接退出
#   * 旧安装先改名备份（同分区 mv，秒级），升级并冒烟测试通过后才删除
#   * 失败（含 macOS 版本不兼容）自动回滚到原版本
#   * 迁移用户资产：dropins/ 插件、-javaagent（如 lombok）及被引用的 jar

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------- 配置 ----------
ECLIPSE_VERSION="${ECLIPSE_VERSION:-}"      # 空 = 自动（安装取最新，升级取已安装的较新者）
ECLIPSE_PACKAGE="${ECLIPSE_PACKAGE:-}"      # java/jee/cpp/dsl/... 留空则自动沿用已有安装
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
ECLIPSE_INSTALL_DIR="${ECLIPSE_INSTALL_DIR:-/opt/eclipse}"
MAC_APP_PATH="${MAC_APP_PATH:-/Applications/Eclipse.app}"
MAC_ALT_APP_PATH="$HOME/Applications/Eclipse.app"
ECLIPSE_DESKTOP_FILE="/usr/share/applications/eclipse.desktop"

# 国内镜像优先，官方兜底（顺序即优先级）
MIRROR_BASES=(
    "https://mirrors.aliyun.com/eclipse"
    "https://mirrors.ustc.edu.cn/eclipse"
    "https://mirrors.cernet.edu.cn/eclipse"
    "https://mirrors.tuna.tsinghua.edu.cn/eclipse"
    "https://download.eclipse.org"
)
OFFICIAL_BASE="https://download.eclipse.org"

FORCE=0          # -f/--force  强制重装/强制升级到同版本
ASSUME_YES=0     # -y/--yes    非交互自动确认
SMOKE=1          # --no-smoke  跳过启动冒烟测试
DOCTOR=0         # --doctor    仅诊断
UPDATE=0         # --update    升级模式
PRINT_LATEST=0   # --latest    只打印最新可用版本

# 升级过程中的回滚信息
APP_BACKUP=""        # 旧安装被改名到的备份路径
APP_BACKUP_ORIG=""   # 旧安装原来的路径

# ---------- 日志 ----------
log_info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*" >&2; }

die() { log_error "$*"; exit 1; }

# ---------- 系统探测 ----------
detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *)             echo "unknown" ;;
    esac
}

# ---------- 包名/文件名 ----------
# EPP 各发行包 product id -> 下载包名
pkg_from_product() {
    case "$1" in
        org.eclipse.epp.package.java.product)       echo "java" ;;
        org.eclipse.epp.package.jee.product)        echo "jee" ;;
        org.eclipse.epp.package.cpp.product)        echo "cpp" ;;
        org.eclipse.epp.package.dsl.product)        echo "dsl" ;;
        org.eclipse.epp.package.modeling.product)   echo "modeling" ;;
        org.eclipse.epp.package.rcp.product)        echo "rcp" ;;
        org.eclipse.epp.package.scout.product)      echo "scout" ;;
        org.eclipse.epp.package.php.product)        echo "php" ;;
        org.eclipse.epp.package.javascript.product) echo "javascript" ;;
        org.eclipse.epp.package.committers.product) echo "committers" ;;
        org.eclipse.epp.package.embedcpp.product)   echo "embedcpp" ;;
        *) echo "" ;;
    esac
}

ini_next_line() {  # $1=文件 $2=独占一行的 key（-vm / --launcher.library ...）
    awk -v k="$2" '$0 == k { getline; print; exit }' "$1" 2>/dev/null || true
}

# 解析相对路径（相对 base 目录），保留不存在时的原始值
resolve_path() {  # $1=base 目录 $2=路径
    local base="$1" p="$2"
    [ -n "$p" ] || { echo ""; return; }
    case "$p" in
        /*) echo "$p" ;;
        *)
            local dir
            if dir=$(cd "$base" 2>/dev/null && cd "$(dirname "$p")" 2>/dev/null && pwd); then
                echo "$dir/$(basename "$p")"
            else
                echo "$p"
            fi
            ;;
    esac
}

# ---------- 定位已安装的 Eclipse ----------
# 输出：安装类型与主目录（macos: xxx.app；linux: 含 eclipse 的目录）
find_macos_app() {
    local c
    for c in "$MAC_APP_PATH" "$MAC_ALT_APP_PATH"; do
        if [ -d "$c" ]; then echo "$c"; return 0; fi
    done
    # LaunchServices 兜底
    if command -v mdfind &>/dev/null; then
        c=$(mdfind "kMDItemCFBundleIdentifier == 'org.eclipse.platform.ide'" 2>/dev/null | head -1 || true)
        if [ -n "$c" ] && [ -d "$c" ]; then echo "$c"; return 0; fi
    fi
    return 1
}

find_linux_home() {
    local c
    for c in "$ECLIPSE_INSTALL_DIR" "$HOME/eclipse" "/usr/lib/eclipse" "/usr/share/eclipse" "/opt/eclipse"; do
        if [ -f "$c/eclipse" ]; then echo "$c"; return 0; fi
    done
    if command -v eclipse &>/dev/null; then
        c=$(readlink -f "$(command -v eclipse)" 2>/dev/null || true)
        if [ -n "$c" ] && [ -f "$c" ]; then dirname "$c"; return 0; fi
    fi
    return 1
}

check_installed() {
    if [ "$(detect_os)" == "macos" ]; then
        find_macos_app &>/dev/null
    else
        find_linux_home &>/dev/null
    fi
}

# ---------- 健康检查（核心：判断"打不开"） ----------
# 返回 0=健康（可能含轻微提示） 2=损坏（打不开）
# 致命问题写入 PROBLEMS，轻微问题写入 NOTES
PROBLEMS=()
NOTES=()
ADD_PROBLEM() { PROBLEMS+=("$*"); }
ADD_NOTE()    { NOTES+=("$*"); }

health_check_macos() {
    local app="$1"
    local home="$app/Contents/Eclipse"
    local macos_dir="$app/Contents/MacOS"

    [ -x "$macos_dir/eclipse" ] || ADD_PROBLEM "启动器缺失或不可执行: $macos_dir/eclipse"
    if [ -f "$macos_dir/eclipse" ] && [ ! -x "$macos_dir/eclipse" ]; then
        ADD_PROBLEM "启动器没有可执行权限: $macos_dir/eclipse"
    fi
    [ -f "$home/eclipse.ini" ] || ADD_PROBLEM "eclipse.ini 缺失: $home/eclipse.ini"
    [ -f "$home/.eclipseproduct" ] || ADD_NOTE ".eclipseproduct 缺失（不致命）"

    if [ -f "$home/eclipse.ini" ]; then
        local lib vm splash
        lib=$(ini_next_line "$home/eclipse.ini" "--launcher.library")
        vm=$(ini_next_line "$home/eclipse.ini" "-vm")
        splash=$(ini_next_line "$home/eclipse.ini" "-showsplash")

        # 1) 启动器库（macOS 上缺失会静默退出，"双击没反应"的头号原因）
        if [ -n "$lib" ]; then
            local lib_path
            lib_path=$(resolve_path "$macos_dir" "$lib")
            if [ ! -e "$lib_path" ] && [ ! -e "${lib_path}.dylib" ] && [ ! -e "$lib_path/libjli.dylib" ]; then
                ADD_PROBLEM "启动器库不存在: $lib_path"
            fi
        fi

        # 2) -vm 指定的 JVM
        if [ -n "$vm" ]; then
            local vm_path
            vm_path=$(resolve_path "$macos_dir" "$vm")
            if [ ! -e "$vm_path" ]; then
                ADD_PROBLEM "eclipse.ini 指定的 JVM 不存在: $vm_path"
            fi
        fi

        # 3) splash 资源（EPP 里通常写的是 bundle 符号名，不是路径，只有像路径时才检查）
        if [ -n "$splash" ] && [[ "$splash" == */* || "$splash" == *.bmp || "$splash" == *.xpm ]]; then
            local sp
            sp=$(resolve_path "$macos_dir" "$splash")
            if [ ! -e "$sp" ]; then
                ADD_NOTE "启动画面资源缺失（不致命）: $sp"
            fi
        fi
    fi

    # 4) 插件目录：正常 EPP 有数百个插件
    local plugin_count=0
    if [ -d "$home/plugins" ]; then
        plugin_count=$(find "$home/plugins" -maxdepth 1 -name "*.jar" 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [ "$plugin_count" -lt 20 ]; then
        ADD_PROBLEM "插件目录不完整（只有 ${plugin_count} 个 jar）: $home/plugins"
    fi

    # 5) OSGi framework 是否就位（自包含安装应有 org.eclipse.osgi_*.jar）
    local osgi_local
    osgi_local=$(find "$home/plugins" -maxdepth 1 -name "org.eclipse.osgi_*.jar" 2>/dev/null | head -1 || true)
    # 6) config.ini 里的 osgi.framework 是否存在
    local cfg="$home/configuration/config.ini"
    if [ -f "$cfg" ]; then
        local fw fw_path
        fw=$(sed -n 's/^osgi.framework=file\\\?:\(.*\)$/\1/p' "$cfg" | head -1 | sed 's/\\//g')
        if [ -n "$fw" ]; then
            fw_path=$(resolve_path "$home" "$fw")
            if [ ! -e "$fw_path" ]; then
                ADD_PROBLEM "OSGi framework 不存在: $fw_path"
            fi
        fi
        # 7) bundles.info 指向的 bundle pool 是否还在
        local bi="$home/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
        if [ -f "$bi" ]; then
            local total pool_refs missing_example
            total=$(grep -vc '^#' "$bi" 2>/dev/null || true)
            pool_refs=$(grep -c '\.p2/' "$bi" 2>/dev/null || true)
            total=${total:-0}; pool_refs=${pool_refs:-0}
            if [ "$pool_refs" -gt 0 ] && [ ! -d "$HOME/.p2/pool/plugins" ]; then
                ADD_PROBLEM "bundles.info 中 ${pool_refs}/${total} 个 bundle 指向已删除的共享包池 ~/.p2/pool（Eclipse Installer 安装被清理后的典型症状）"
            fi
            missing_example=$(grep -v '^#' "$bi" 2>/dev/null | awk -F, 'NF>2 {print $3}' | while read -r p; do
                [ -e "$(resolve_path "$home" "$p")" ] || { echo "$p"; break; }
            done)
            [ -z "$missing_example" ] || ADD_PROBLEM "bundles.info 引用的文件缺失，例如: $missing_example"
        fi
    fi

    # 8) 自包含安装里 osgi 应在本地；不在本地又没包池，说明装在包池里
    if [ -z "$osgi_local" ] && [ ! -d "$HOME/.p2/pool/plugins" ]; then
        ADD_PROBLEM "本地没有 org.eclipse.osgi_*.jar，且共享包池 ~/.p2/pool 不存在"
    fi

    [ ${#PROBLEMS[@]} -eq 0 ]
}

health_check_linux() {
    local home="$1"

    [ -x "$home/eclipse" ] || ADD_PROBLEM "启动器缺失或不可执行: $home/eclipse"
    [ -f "$home/eclipse.ini" ] || ADD_PROBLEM "eclipse.ini 缺失"

    if [ -f "$home/eclipse.ini" ]; then
        local vm lib
        vm=$(ini_next_line "$home/eclipse.ini" "-vm")
        lib=$(ini_next_line "$home/eclipse.ini" "--launcher.library")
        if [ -n "$vm" ] && [ ! -e "$(resolve_path "$home" "$vm")" ]; then
            ADD_PROBLEM "eclipse.ini 指定的 JVM 不存在: $(resolve_path "$home" "$vm")"
        fi
        if [ -n "$lib" ] && [ ! -e "$(resolve_path "$home" "$lib")" ]; then
            ADD_PROBLEM "启动器库不存在: $(resolve_path "$home" "$lib")"
        fi
    fi

    local plugin_count=0
    if [ -d "$home/plugins" ]; then
        plugin_count=$(find "$home/plugins" -maxdepth 1 -name "*.jar" 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [ "$plugin_count" -lt 20 ]; then
        ADD_PROBLEM "插件目录不完整（只有 ${plugin_count} 个 jar）: $home/plugins"
    fi

    local bi="$home/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
    if [ -f "$bi" ] && grep -q '\.p2/' "$bi" 2>/dev/null && [ ! -d "$HOME/.p2/pool/plugins" ]; then
        ADD_PROBLEM "bundles.info 指向已删除的共享包池 ~/.p2/pool"
    fi

    [ ${#PROBLEMS[@]} -eq 0 ]
}

# 统一入口：设置全局 CURRENT_APP / CURRENT_HOME / HEALTH
# 返回 0=已安装（细节看 HEALTH） 1=未安装
run_health_check() {
    PROBLEMS=(); NOTES=()
    local os app

    os=$(detect_os)
    if [ "$os" == "macos" ]; then
        app=$(find_macos_app 2>/dev/null) || return 1
        CURRENT_APP="$app"
        CURRENT_HOME="$app/Contents/Eclipse"
        HEALTH=0
        health_check_macos "$app" || HEALTH=2
    else
        app=$(find_linux_home 2>/dev/null) || return 1
        CURRENT_APP="$app"
        CURRENT_HOME="$app"
        HEALTH=0
        health_check_linux "$app" || HEALTH=2
    fi
    return 0
}

print_health_report() {
    local app="$1"
    echo ""
    echo "======== Eclipse 诊断报告 ========"
    echo "系统      : $(uname -s) $(uname -r) / $(detect_arch)"
    echo "安装位置  : $app"
    echo "版本      : $(get_version)"
    if [ ${#PROBLEMS[@]} -eq 0 ]; then
        echo -e "检查结果  : ${GREEN}可用${NC}"
    else
        echo -e "检查结果  : ${RED}不可用（这就是打不开的原因）${NC}"
        local p
        for p in "${PROBLEMS[@]}"; do echo "   ✗ $p"; done
    fi
    if [ ${#NOTES[@]} -gt 0 ]; then
        local n
        for n in "${NOTES[@]}"; do echo "   ! $n"; done
    fi
    echo "=================================="
    echo ""
}

# ---------- 版本 ----------
get_version() {
    local os app home
    os=$(detect_os)
    if [ "$os" == "macos" ]; then
        app=$(find_macos_app 2>/dev/null || true)
        [ -n "$app" ] || { echo ""; return 0; }
        home="$app/Contents/Eclipse"
        if [ -f "$home/.eclipseproduct" ]; then
            sed -n 's/^version=//p' "$home/.eclipseproduct" | head -1
            return 0
        fi
        defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo ""
    else
        home=$(find_linux_home 2>/dev/null || true)
        [ -n "$home" ] || { echo ""; return 0; }
        # 优先读 .eclipseproduct，避免直接拉起 IDE（eclipse -version 在部分版本会启动工作台）
        if [ -f "$home/.eclipseproduct" ]; then
            sed -n 's/^version=//p' "$home/.eclipseproduct" | head -1
        elif [ -f "$home/readme/readme_eclipse.html" ]; then
            grep -oE 'Version [0-9]+\.[0-9]+\.[0-9]+' "$home/readme/readme_eclipse.html" | head -1
        else
            echo ""
        fi
    fi
}

# ---------- 版本比较 / 探测 ----------
# 已安装版本的季度标识（取自 config.ini 的 buildId：4.36.0.20250605-1300 -> 2025-06）
installed_release() {
    local os app home ini build d
    os=$(detect_os)
    if [ "$os" == "macos" ]; then
        app=$(find_macos_app 2>/dev/null) || return 1
        ini="$app/Contents/Eclipse/configuration/config.ini"
    else
        home=$(find_linux_home 2>/dev/null) || return 1
        ini="$home/configuration/config.ini"
    fi
    [ -f "$ini" ] || return 1
    build=$(sed -n 's/^eclipse\.buildId=//p' "$ini" | head -1)
    [ -n "$build" ] || return 1
    d=$(printf '%s\n' "$build" | grep -oE '[0-9]{8}' | head -1 || true)
    [ -n "$d" ] || return 1
    echo "${d:0:4}-${d:4:2}"
}

# 数值型版本比较：$1 >= $2 （如 12.7.6 >= 11.0）
version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, ".")
        for (i = 1; i <= (n > m ? n : m); i++) {
            xv = (i <= n) ? x[i] + 0 : 0
            yv = (i <= m) ? y[i] + 0 : 0
            if (xv > yv) exit 0
            if (xv < yv) exit 1
        }
        exit 0
    }'
}

# 季度版本比较（YYYY-MM 定长，可直接字符串比较）
release_ge() { [[ "$1" > "$2" || "$1" == "$2" ]]; }

# 候选正式版本，由近及远（Eclipse 每季度发布：03/06/09/12）
release_candidates() {
    local cy cm yy mm rel
    cy=$(date +%Y); cm=$(date +%m)
    for yy in $(seq "$cy" -1 "$((cy - 2))"); do
        for mm in 12 09 06 03; do
            rel="$yy-$mm"
            [[ "$rel" > "${cy}-${cm}" ]] && continue   # 跳过尚未发布的季度
            echo "$rel"
        done
    done
}

# 探测最新可用正式版（$1 可指定发行包，默认当前/ java）
latest_release() {
    local pkg="${1:-${ECLIPSE_PACKAGE:-java}}"
    local os arch file rel probe
    os=$(detect_os); arch=$(detect_arch)
    while read -r rel; do
        [ -n "$rel" ] || continue
        file=$(build_file_name "$rel" "$os" "$arch" "$pkg")
        probe="${OFFICIAL_BASE}$(build_rel_path "$rel" "$file")"
        if url_alive "$probe"; then
            echo "$rel"
            return 0
        fi
    done < <(release_candidates)
    return 1
}

# ---------- 下载 ----------
build_file_name() {  # $1=ver $2=os $3=arch $4=pkg -> 文件名
    local ver="$1" os="$2" arch="$3" pkg="$4"
    if [ "$os" == "macos" ]; then
        echo "eclipse-${pkg}-${ver}-R-macosx-cocoa-${arch}.dmg"
    else
        echo "eclipse-${pkg}-${ver}-R-linux-gtk-${arch}.tar.gz"
    fi
}

build_rel_path() {  # $1=ver $2=file -> /technology/epp/...
    echo "/technology/epp/downloads/release/${1}/R/$2"
}

# 探测某个 URL 是否可用（跟随重定向；range 请求比 HEAD 更可靠，部分镜像会 403 HEAD）
url_alive() {
    local code
    code=$(curl -s -L -o /dev/null -m 10 -r 0-255 -w "%{http_code}" "$1" 2>/dev/null || echo "000")
    case "$code" in
        200|206) return 0 ;;   # 真实可下载
        *)       return 1 ;;
    esac
}

pick_download_source() {
    local rel="$1" base url
    local candidates=()
    for base in "${MIRROR_BASES[@]}"; do
        url="${base}${rel}"
        if url_alive "$url"; then
            log_info "可用源: $url"
            candidates+=("$url")
            [ ${#candidates[@]} -ge 2 ] && break   # 一个主用 + 一个备用就够了
        else
            log_warn "跳过不可用源: $base"
        fi
    done
    if [ ${#candidates[@]} -eq 0 ]; then
        return 1
    fi
    printf '%s\n' "${candidates[@]}"
}

verify_artifact() {  # $1=文件 $2=os
    local f="$1" os="$2" size type
    [ -f "$f" ] || return 1
    size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "${size:-0}" -lt 100000000 ]; then
        log_warn "文件偏小 ($((size/1024/1024))MB)，可能是错误的下载结果"
        return 1
    fi
    type=$(file -b "$f" 2>/dev/null || echo "")
    if [[ "$type" == *HTML* || "$type" == *text* || "$type" == *XML* ]]; then
        log_warn "文件类型错误: $type"
        return 1
    fi
    if [ "$os" == "macos" ]; then
        hdiutil verify "$f" &>/dev/null || { log_warn "DMG 校验失败"; return 1; }
    else
        tar -tzf "$f" &>/dev/null || { log_warn "压缩包损坏"; return 1; }
    fi
    return 0
}

download_file_with_fallback() {  # $1=目标文件 $2=候选URL列表(换行分隔)
    local target="$1" urls="$2" primary mirrors=() u
    primary=$(printf '%s\n' "$urls" | head -1)
    while read -r u; do
        [ -n "$u" ] || continue
        [ "$u" == "$primary" ] && continue
        mirrors+=("$u")
    done <<< "$urls"

    if command -v adl &>/dev/null; then
        log_info "使用 adl 下载（支持断点续传 + 多源）..."
        if adl "$primary" "$(dirname "$target")" "$(basename "$target")" "${mirrors[@]+"${mirrors[@]}"}"; then
            return 0
        fi
        log_warn "adl 下载失败，尝试其他方式..."
    fi
    if command -v aria2c &>/dev/null; then
        log_info "使用 aria2c 下载..."
        local uri_args=()
        for u in "$primary" "${mirrors[@]+"${mirrors[@]}"}"; do uri_args+=("$u"); done
        if aria2c -x 16 -s 16 -c -d "$(dirname "$target")" -o "$(basename "$target")" "${uri_args[@]}"; then
            return 0
        fi
        log_warn "aria2c 下载失败，尝试 curl..."
    fi
    log_info "使用 curl 下载..."
    curl -fL --retry 5 --retry-delay 2 -C - -o "$target" "$primary"
}

# 下载（成功时把文件路径写入全局 ARTIFACT）
fetch_eclipse() {
    local os arch pkg file rel urls target
    local pkgs=()

    os=$(detect_os); arch=$(detect_arch)

    # 候选发行包：指定的包优先，java 兜底（避免某个包在该版本不存在导致整体失败）
    pkgs+=("$ECLIPSE_PACKAGE")
    [ "$ECLIPSE_PACKAGE" != "java" ] && pkgs+=("java")

    for pkg in "${pkgs[@]}"; do
        file=$(build_file_name "$ECLIPSE_VERSION" "$os" "$arch" "$pkg")
        rel=$(build_rel_path "$ECLIPSE_VERSION" "$file")
        mkdir -p "$DOWNLOAD_DIR"
        target="$DOWNLOAD_DIR/$file"

        log_step "准备 Eclipse ${ECLIPSE_VERSION} (${pkg}) for ${os}/${arch}"
        log_info "目标文件: $target"

        if [ -f "$target" ]; then
            log_info "发现已下载的安装包，校验中..."
            if verify_artifact "$target" "$os"; then
                log_info "安装包校验通过，跳过下载"
                ARTIFACT="$target"; ECLIPSE_PACKAGE="$pkg"
                return 0
            fi
            log_warn "安装包无效，删除后重新下载"
            rm -f "$target"
        fi

        log_info "正在探测下载源..."
        if ! urls=$(pick_download_source "$rel"); then
            log_warn "版本 ${ECLIPSE_VERSION} 的 ${pkg} 发行包在所有镜像上都不可用"
            continue
        fi
        if ! download_file_with_fallback "$target" "$urls"; then
            log_warn "下载 ${pkg} 失败"
            rm -f "$target"
            continue
        fi
        if ! verify_artifact "$target" "$os"; then
            log_error "下载完成但校验失败: $target"
            rm -f "$target"
            continue
        fi
        ARTIFACT="$target"; ECLIPSE_PACKAGE="$pkg"
        log_info "安装包下载完成并通过校验"
        return 0
    done

    log_error "所有候选发行包均下载失败"
    return 1
}

# ---------- macOS 安装 ----------
MOUNT_POINT=""
cleanup_mount() {
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -force &>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
    MOUNT_POINT=""
}
trap cleanup_mount EXIT INT TERM

# ---------- 备份 / 回滚 / 用户资产迁移 ----------
# 旧安装不做 rm -rf，而是同分区改名（秒级、可回滚），升级验证通过后才真正删除
backup_existing_install() {  # $1=已有安装路径
    local path="$1" ts
    [ -e "$path" ] || return 0
    ts=$(date +%Y%m%d-%H%M%S)
    APP_BACKUP="$(dirname "$path")/.$(basename "$path").bak-$ts"
    APP_BACKUP_ORIG="$path"
    log_info "备份原有安装（失败可回滚）: $APP_BACKUP"
    mv "$path" "$APP_BACKUP"
}

commit_install() {
    if [ -n "$APP_BACKUP" ] && [ -e "$APP_BACKUP" ]; then
        log_info "验证通过，删除旧版本备份"
        rm -rf "$APP_BACKUP"
    fi
    APP_BACKUP=""
    APP_BACKUP_ORIG=""
}

rollback_install() {
    [ -n "$APP_BACKUP" ] && [ -e "$APP_BACKUP" ] || return 0
    log_warn "安装/升级未通过验证，回滚到原有安装..."
    [ -n "${CURRENT_APP:-}" ] && [ -e "$CURRENT_APP" ] && rm -rf "$CURRENT_APP"
    mv "$APP_BACKUP" "$APP_BACKUP_ORIG"
    APP_BACKUP=""
    log_warn "已回滚: $APP_BACKUP_ORIG"
}

# 迁移用户资产：dropins 插件、-javaagent（lombok/jacoco 等）及其引用的 jar
restore_user_extras() {  # $1=旧安装根(Eclipse 目录) $2=新安装根
    local old="$1" new="$2" item name jar agent new_agent
    [ -d "$old" ] && [ -d "$new" ] || return 0

    # 1) dropins/ 下的用户插件
    if [ -d "$old/dropins" ]; then
        for item in "$old/dropins"/*; do
            [ -e "$item" ] || continue
            name=$(basename "$item")
            log_info "迁移 dropins 插件: $name"
            mkdir -p "$new/dropins"
            rm -rf "$new/dropins/$name"
            cp -R "$item" "$new/dropins/"
        done
    fi

    # 2) eclipse.ini 里的 -javaagent（常见于 lombok），jar 在旧目录里的一并搬过去
    [ -f "$old/eclipse.ini" ] && [ -f "$new/eclipse.ini" ] || return 0
    while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        jar="${agent#-javaagent:}"
        jar="${jar%%=*}"
        if [ -f "$jar" ]; then
            # 只处理原本位于 Eclipse 安装目录内的 jar
            case "$jar" in
                "$old"/*)
                    name=$(basename "$jar")
                    log_info "迁移 javaagent: $name"
                    cp -f "$jar" "$new/$name"
                    new_agent="-javaagent:$new/$name"
                    ;;
                *) new_agent="$agent" ;;
            esac
            if ! grep -qxF "$new_agent" "$new/eclipse.ini"; then
                # 追加到 -vmargs 段末尾（javaagent 必须位于 -vmargs 之后）
                printf '%s\n' "$new_agent" >> "$new/eclipse.ini"
                log_info "已在新 eclipse.ini 中恢复: $new_agent"
            fi
        fi
    done < <(grep -E '^-javaagent:' "$old/eclipse.ini" || true)
}

install_macos() {
    local dmg="$1" app="$MAC_APP_PATH" app_src target_dir
    local mount_point old_home min_macos cur_macos

    log_step "安装到 $app"

    # /Applications 不可写时退回到 ~/Applications
    target_dir=$(dirname "$app")
    if [ ! -w "$target_dir" ]; then
        log_warn "$target_dir 不可写，改为安装到 $MAC_ALT_APP_PATH"
        app="$MAC_ALT_APP_PATH"
        mkdir -p "$(dirname "$app")"
    fi

    mount_point=$(mktemp -d "${TMPDIR:-/tmp}/eclipse-dmg.XXXXXX")
    MOUNT_POINT="$mount_point"
    log_info "挂载安装镜像..."
    if ! hdiutil attach "$dmg" -nobrowse -noautoopen -readonly -mountpoint "$mount_point" &>/dev/null; then
        log_error "挂载 DMG 失败: $dmg"
        cleanup_mount
        return 1
    fi

    app_src=$(find "$mount_point" -maxdepth 1 -name "*.app" | head -1 || true)
    if [ -z "$app_src" ] || [ ! -d "$app_src" ]; then
        log_error "DMG 中未找到 .app"
        cleanup_mount
        return 1
    fi
    log_info "发现应用: $(basename "$app_src")"

    # 安装前先校验系统版本要求，避免装完才发现跑不起来（尤其老 macOS 装新版 Eclipse）
    min_macos=$(defaults read "$app_src/Contents/Info.plist" LSMinimumSystemVersion 2>/dev/null || true)
    cur_macos=$(sw_vers -productVersion 2>/dev/null || echo "")
    if [ -n "$min_macos" ] && [ -n "$cur_macos" ] && ! version_ge "$cur_macos" "$min_macos"; then
        log_error "该版本 Eclipse 要求 macOS >= ${min_macos}，当前系统为 ${cur_macos}，已取消安装（原安装未改动）"
        cleanup_mount
        return 1
    fi
    [ -n "$min_macos" ] && log_info "系统版本检查通过（要求 macOS >= ${min_macos}，当前 ${cur_macos}）"

    # 关键：旧安装必须整体移走，不能 cp -R 覆盖。
    # cp -R 是"合并"，旧的 eclipse.ini / configuration 会残留并继续指向失效路径。
    old_home=""
    if [ -e "$app" ]; then
        old_home="$app/Contents/Eclipse"
        backup_existing_install "$app"
    fi

    # ditto 才能正确保留符号链接、ACL 与代码签名（cp -R 会破坏签名导致"已损坏"）
    log_info "复制应用到 $(dirname "$app")..."
    if ! ditto "$app_src" "$app"; then
        log_error "复制应用失败"
        cleanup_mount
        rollback_install
        return 1
    fi
    cleanup_mount

    # 迁移用户资产（旧安装已经在备份目录里）
    if [ -n "$old_home" ] && [ -d "$old_home" ]; then
        restore_user_extras "$old_home" "$app/Contents/Eclipse"
    fi

    # 去隔离属性：否则 Gatekeeper 会拦截下载来的 App
    log_info "清除隔离属性 (quarantine)..."
    xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

    # 签名校验；失败则本地 ad-hoc 重签（macOS 15+ 对签名损坏的 App 直接拒绝启动）
    if ! codesign --verify --deep --strict "$app" &>/dev/null; then
        log_warn "代码签名校验未通过，执行 ad-hoc 重新签名..."
        codesign --force --deep --sign - "$app" &>/dev/null || log_warn "ad-hoc 签名失败（多数情况下仍可运行）"
    fi

    # 刷新 LaunchServices，修复"双击图标没反应"
    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$lsregister" ]; then
        "$lsregister" -f "$app" &>/dev/null || true
    fi

    CURRENT_APP="$app"
    CURRENT_HOME="$app/Contents/Eclipse"
    return 0
}

# ---------- Linux 安装 ----------
install_linux() {
    local tgz="$1" dir="$ECLIPSE_INSTALL_DIR" old_home=""

    if [ "$EUID" -ne 0 ] && [ ! -w "$(dirname "$dir")" ]; then
        log_warn "无权写入 $(dirname "$dir")，改为安装到 $HOME/eclipse"
        dir="$HOME/eclipse"
        ECLIPSE_INSTALL_DIR="$dir"
    fi

    log_step "安装到 $dir"
    if [ -e "$dir" ]; then
        old_home="$dir"
        backup_existing_install "$dir"
    fi
    mkdir -p "$dir"
    if ! tar -xzf "$tgz" -C "$dir"; then
        log_error "解压失败"
        rmdir "$dir" 2>/dev/null || true
        rollback_install
        return 1
    fi
    chmod +x "$dir/eclipse" 2>/dev/null || true

    [ -n "$old_home" ] && restore_user_extras "$old_home" "$dir"

    CURRENT_APP="$dir"
    CURRENT_HOME="$dir"
    create_desktop_shortcut
    return 0
}

# ---------- 快捷方式 / 启动器 ----------
create_desktop_shortcut() {
    [ -d "/usr/share/applications" ] || return 0
    local dir="$ECLIPSE_INSTALL_DIR" icon="$ECLIPSE_INSTALL_DIR/icon.xpm"
    [ -f "$icon" ] || icon="eclipse"
    log_info "创建桌面快捷方式..."
    if [ ! -w "/usr/share/applications" ]; then
        log_warn "无权写入 /usr/share/applications，跳过桌面快捷方式"
        return 0
    fi
    cat > "$ECLIPSE_DESKTOP_FILE" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Eclipse
Comment=Eclipse IDE
Exec="$dir/eclipse" %f
Icon=$icon
Terminal=false
Categories=Development;IDE;
StartupNotify=true
EOF
    chmod +x "$ECLIPSE_DESKTOP_FILE"
}

create_command_launcher() {
    local dir="/usr/local/bin" bin
    if [ ! -w "$dir" ]; then
        dir="$HOME/.local/bin"
        mkdir -p "$dir"
    fi
    bin="$dir/eclipse"
    log_info "创建命令行启动器: $bin"

    cat > "$bin" << 'EOF'
#!/bin/bash
# Eclipse 启动器（由 ide/install-eclipse.sh 生成）
self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
for candidate in \
    "${ECLIPSE_HOME:-}" \
    "/Applications/Eclipse.app/Contents/MacOS/eclipse" \
    "/Applications/Eclipse.app" \
    "$HOME/Applications/Eclipse.app/Contents/MacOS/eclipse" \
    "$HOME/Applications/Eclipse.app" \
    "/opt/eclipse/eclipse" \
    "$HOME/eclipse/eclipse"
do
    [ -n "$candidate" ] || continue
    if [ -d "$candidate" ]; then
        if [ -x "$candidate/Contents/MacOS/eclipse" ]; then
            exec "$candidate/Contents/MacOS/eclipse" "$@"
        fi
    elif [ -x "$candidate" ]; then
        exec "$candidate" "$@"
    fi
done
for candidate in /usr/lib/eclipse/eclipse /usr/share/eclipse/eclipse; do
    [ -x "$candidate" ] && exec "$candidate" "$@"
done
echo "未找到可运行的 Eclipse，请先执行 ide/install-eclipse.sh --install" >&2
exit 1
EOF
    chmod +x "$bin"

    case ":$PATH:" in
        *":$dir:"*) ;;
        *) log_warn "$dir 不在 PATH 中，请把它加入 PATH 后才能直接使用 eclipse 命令" ;;
    esac
}

# ---------- 冒烟测试：确认真的能打开 ----------
smoke_test() {
    local app="$1" os tmp log ws pid i alive=0 limit
    [ "$SMOKE" -eq 1 ] || { log_info "已跳过启动冒烟测试"; return 0; }
    os=$(detect_os)
    [ "$os" == "macos" ] || return 0   # 无 GUI 环境时 Linux 不做启动测试

    if [ -n "${SSH_TTY:-}" ]; then
        log_warn "当前是 SSH 会话，跳过图形启动冒烟测试"
        return 0
    fi

    # 首次冷启动（新装/新版本、x86 机器）可能要 1~2 分钟，默认给 180 秒
    limit="${SMOKE_TIMEOUT:-180}"

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/eclipse-smoke.XXXXXX")
    log="$tmp/client.log"; ws="$tmp/ws"
    log_info "启动冒烟测试（最多等待 ${limit} 秒，首次冷启动较慢）..."

    "$app/Contents/MacOS/eclipse" -nosplash -consolelog -data "$ws" >"$log" 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt "$limit" ]; do
        if kill -0 "$pid" 2>/dev/null; then
            # 出现 .metadata 说明 OSGi 框架真的起来了
            if [ -d "$ws/.metadata" ]; then
                alive=1; break
            fi
            if [ "$i" -gt 0 ] && [ $((i % 20)) -eq 0 ]; then
                log_info "仍在启动中（已等待 ${i}s）..."
            fi
            sleep 1; i=$((i+1))
        else
            break
        fi
    done

    if [ "$alive" -eq 1 ]; then
        log_info "冒烟测试通过：Eclipse 已成功启动"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -rf "$tmp"
        return 0
    fi

    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    log_error "冒烟测试失败，Eclipse 启动后未能进入工作台。日志如下："
    sed 's/^/    /' "$log" | head -40 >&2
    [ -f "$ws/.metadata/.log" ] && { echo "---- workspace .log ----" >&2; tail -40 "$ws/.metadata/.log" | sed 's/^/    /' >&2; }
    rm -rf "$tmp"
    return 1
}

# ---------- 主安装流程 ----------
install_eclipse() {
    local os
    os=$(detect_os)
    [ "$os" == "unknown" ] && die "不支持的系统: $(uname -s)"

    if ! command -v curl &>/dev/null; then
        die "需要 curl，请先安装"
    fi

    # 未指定版本则取最新正式版
    if [ -z "$ECLIPSE_VERSION" ]; then
        log_info "未指定版本，正在探测最新正式版..."
        ECLIPSE_VERSION=$(latest_release "${ECLIPSE_PACKAGE:-java}" || true)
        [ -n "$ECLIPSE_VERSION" ] || die "无法探测最新版本，请用 ECLIPSE_VERSION=YYYY-MM 指定"
    fi
    log_info "目标版本: ${ECLIPSE_VERSION}"

    fetch_eclipse || die "下载 Eclipse 失败，请检查网络或手动下载后放到 $DOWNLOAD_DIR"

    if [ "$os" == "macos" ]; then
        install_macos "$ARTIFACT" || die "macOS 安装失败"
    else
        install_linux "$ARTIFACT" || die "Linux 安装失败"
    fi

    create_command_launcher

    log_step "安装后校验"
    PROBLEMS=(); NOTES=()
    local rc=0
    if [ "$os" == "macos" ]; then
        health_check_macos "$CURRENT_APP" || rc=$?
    else
        health_check_linux "$CURRENT_APP" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        print_health_report "$CURRENT_APP"
        rollback_install
        log_error "安装完成，但健康检查未通过（已回滚），请把上面的报告提供给维护者"
        exit 1
    fi

    if [ "$os" == "macos" ]; then
        if ! smoke_test "$CURRENT_APP"; then
            rollback_install
            die "Eclipse 启动验证失败（已回滚到原有安装）"
        fi
    fi

    commit_install

    log_info "Eclipse IDE 安装完成: $CURRENT_APP"
    log_info "版本: $(get_version)"
    log_info "可执行: eclipse  或  open -a Eclipse"
}

# ---------- doctor ----------
run_doctor() {
    local os
    os=$(detect_os)
    PROBLEMS=()
    if ! run_health_check; then
        echo ""
        echo "未检测到 Eclipse 安装（${os}）。"
        echo "可以执行: $0 --install"
        echo ""
        return 1
    fi
    print_health_report "$CURRENT_APP"
    if [ "$HEALTH" -eq 0 ]; then
        log_info "Eclipse 可用"
        # 顺便报一下是否有新版本（探测失败不影响结果）
        local installed latest pkg
        installed=$(installed_release 2>/dev/null || true)
        pkg=$(detect_package_from_install 2>/dev/null || true)
        [ -n "$pkg" ] || pkg="java"
        latest=$(latest_release "$pkg" 2>/dev/null || true)
        if [ -n "$installed" ] && [ -n "$latest" ] && [[ "$latest" > "$installed" ]]; then
            log_info "可升级: ${installed} → ${latest}（执行 $0 --update）"
        elif [ -n "$installed" ]; then
            log_info "已是最新正式版: ${installed}"
        fi
        return 0
    fi
    log_error "Eclipse 已安装但不可用（${HEALTH}），建议执行: $0 --repair"
    return 2
}

# ---------- 升级 ----------
run_update() {
    local installed target pkg

    if ! check_installed; then
        log_error "未检测到 Eclipse 安装，请先执行: $0 --install"
        return 1
    fi

    run_health_check || true
    if [ "$HEALTH" -ne 0 ]; then
        print_health_report "$CURRENT_APP"
        log_error "当前安装已损坏（${HEALTH}），请先执行: $0 --repair 再升级"
        return 1
    fi

    # 沿用已安装的发行包（JEE 不会被降级成 Java SE）
    if [ -z "$ECLIPSE_PACKAGE" ]; then
        pkg=$(detect_package_from_install 2>/dev/null || true)
        ECLIPSE_PACKAGE="${pkg:-java}"
    fi

    installed=$(installed_release 2>/dev/null || true)

    if [ -z "$ECLIPSE_VERSION" ]; then
        log_info "正在探测最新正式版（发行包: ${ECLIPSE_PACKAGE}）..."
        target=$(latest_release "$ECLIPSE_PACKAGE" || true)
        if [ -z "$target" ]; then
            log_error "无法探测最新版本，请显式指定: $0 --update 2026-09"
            return 1
        fi
    else
        target="$ECLIPSE_VERSION"
    fi
    ECLIPSE_VERSION="$target"

    log_info "当前版本: ${installed:-未知}（$(get_version)）"
    log_info "目标版本: ${target}"
    log_info "发行包  : ${ECLIPSE_PACKAGE}"

    if [ -n "$installed" ] && [ "$FORCE" -eq 0 ] && release_ge "$installed" "$target"; then
        if [ "$installed" == "$target" ]; then
            log_info "已是最新版本（${installed}），无需升级"
        else
            log_info "当前版本 ${installed} 不低于目标 ${target}，已跳过（降级/切换请加 --force）"
        fi
        return 0
    fi

    log_info "正在确认目标版本可用性..."
    local rel file probe
    file=$(build_file_name "$target" "$(detect_os)" "$(detect_arch)" "$ECLIPSE_PACKAGE")
    rel=$(build_rel_path "$target" "$file")
    if ! probe=$(pick_download_source "$rel"); then
        log_error "目标版本 ${target} 的 ${ECLIPSE_PACKAGE} 发行包不可用，请检查版本号或换 --update <YYYY-MM>"
        return 1
    fi

    if [ "$FORCE" -eq 0 ] && [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
        if ! confirm "升级 ${installed:-?} → ${target}? (Y/n)" "Y"; then
            log_info "已取消"
            return 0
        fi
    fi

    log_step "开始升级 ${installed:-?} → ${target}（失败会自动回滚）"
    install_eclipse
}

# ---------- 帮助 ----------
show_help() {
    cat << EOF
Eclipse IDE 一键安装 / 诊断 / 修复 / 升级脚本

用法: $0 [选项]

选项:
  (无)            交互式安装（已安装且可用则直接退出）
  -i, --install   安装（若已安装且健康则跳过；损坏则重装）
  -u, --update    升级到最新正式版，或升级到指定版本：--update 2026-09
  -r, --repair    修复：删除损坏安装并重装
  -c, --check     诊断：检查安装是否健康，并提示是否有新版本
  -f, --force     强制重装 / 强制升级到同一版本
  -y, --yes       非交互，全部自动确认
      --latest    只打印当前可用的最新正式版
      --no-smoke  安装后跳过启动冒烟测试
  -v, --version   输出版本号（空表示未安装）
  -h, --help      显示帮助

环境变量:
  ECLIPSE_VERSION   Eclipse 版本（如 2024-09 / 2025-06 / 2026-09），留空 = 自动取最新
  ECLIPSE_PACKAGE   发行包，默认沿用已有安装，否则 java（java/jee/cpp/dsl/modeling/rcp/scout/php/javascript/committers/embedcpp）
  DOWNLOAD_DIR      安装包保存目录，默认 \$HOME/Downloads
  MAC_APP_PATH      macOS 安装目标，默认 /Applications/Eclipse.app
  SMOKE_TIMEOUT     启动冒烟测试超时秒数，默认 180（首次冷启动较慢）

示例:
  $0                      # 交互式
  $0 --check              # 为什么打不开？有没有新版本？
  $0 --update             # 升级到最新正式版（失败自动回滚）
  $0 --update 2026-09     # 升级到指定版本
  $0 --repair -y          # 一键修复
  $0 --latest             # 只查询最新版本号
  ECLIPSE_PACKAGE=jee $0 -i
EOF
}

# ---------- 确认 ----------
confirm() {  # $1=提示 $2=默认值 Y/N
    local prompt="$1" default="${2:-N}" ans
    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
        echo "（非交互模式，自动选择 ${default}）" >&2
        [ "$default" == "Y" ] && return 0 || return 1
    fi
    # shellcheck disable=SC2162
    read -r -p "$prompt " ans || true
    [ -z "$ans" ] && ans="$default"
    [[ "$ans" == [yY]* ]]
}

# ---------- 沿用已有安装的发行包 ----------
detect_package_from_install() {
    local ini prod p app
    if [ "$(detect_os)" == "macos" ]; then
        app=$(find_macos_app 2>/dev/null) || return 1
        ini="$app/Contents/Eclipse/eclipse.ini"
    else
        app=$(find_linux_home 2>/dev/null) || return 1
        ini="$app/eclipse.ini"
    fi
    [ -f "$ini" ] || return 1
    prod=$(ini_next_line "$ini" "-product")
    [ -n "$prod" ] || return 1
    p=$(pkg_from_product "$prod")
    [ -n "$p" ] && { echo "$p"; return 0; }
    return 1
}

# ---------- 主函数 ----------
main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help)    show_help; exit 0 ;;
            -v|--version) get_version; exit 0 ;;
            -u|--update)  UPDATE=1 ;;
            --latest)     PRINT_LATEST=1 ;;
            -i|--install) ;;
            -r|--repair)  FORCE=1 ;;
            -c|--check|--doctor) DOCTOR=1 ;;
            -f|--force)   FORCE=1 ;;
            -y|--yes)     ASSUME_YES=1 ;;
            --no-smoke)   SMOKE=0 ;;
            --update=*)   UPDATE=1; ECLIPSE_VERSION="${arg#--update=}" ;;
            [0-9][0-9][0-9][0-9]-[0-9][0-9]) ECLIPSE_VERSION="$arg" ;;
            *) log_error "未知选项: $arg"; show_help; exit 1 ;;
        esac
    done

    # 只查询最新版本
    if [ "$PRINT_LATEST" -eq 1 ]; then
        latest_release "${ECLIPSE_PACKAGE:-java}" || die "无法探测最新版本，请检查网络"
        exit 0
    fi

    # 诊断模式
    if [ "$DOCTOR" -eq 1 ]; then
        run_doctor
        exit $?
    fi

    # 升级模式
    if [ "$UPDATE" -eq 1 ]; then
        run_update
        exit $?
    fi

    # 交互模式：已安装且健康则直接退出
    if check_installed && run_health_check; then
        if [ "$HEALTH" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
            log_info "Eclipse 已安装且运行正常: $CURRENT_APP"
            log_info "版本: $(get_version)（季度版本: $(installed_release 2>/dev/null || echo 未知)）"
            log_info "升级到最新版请执行: $0 --update"
            exit 0
        fi

        if [ "$HEALTH" -eq 2 ]; then
            print_health_report "$CURRENT_APP"
            log_warn "这种损坏（尤其是指向 ~/.p2 的 Installer 安装）无法靠改配置修好，需要删除并重装自包含版本。"
        else
            log_warn "Eclipse 已安装"
        fi

        if [ "$FORCE" -eq 0 ]; then
            if ! confirm "删除现有安装并重新安装? (Y/n)" "Y"; then
                log_info "已取消"
                exit 0
            fi
        fi
    fi

    # 沿用已有安装的发行包（例如原来是 JEE，就不降级成 Java SE）
    if [ -z "$ECLIPSE_PACKAGE" ]; then
        ECLIPSE_PACKAGE=$(detect_package_from_install 2>/dev/null || true)
        [ -n "$ECLIPSE_PACKAGE" ] || ECLIPSE_PACKAGE="java"
        log_info "使用发行包: $ECLIPSE_PACKAGE"
    fi

    install_eclipse
}

main "$@"
