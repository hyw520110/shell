#!/bin/bash
#
# Android 手机提速 + 存储整理（只走 adb shell 权限，不需要 root）
#
# 起因：一台 Mate 9（Android 9 / EMUI 9.1，4G 内存 + 2.3G zram）越用越慢。排查下来和发热、
# CPU 限频、SD 卡速度都没关系，真正的原因是：
#   1) /data 用到 92%（ext4 接近满时写延迟上升）
#   2) 十几个缓存进程把内存吃光，反复往 zram 换页
#   3) 使用期间还有 dex2oat 在后台编译抢 CPU
# 这个脚本把那轮手工操作固化下来，能重复跑，也能只出报告。不绑品牌、不绑机型，
# 只要 Android 8~10 + adb shell 权限就能用。
#
# 用法:
#   ./optimize-android-phone.sh                      体检报告，什么都不改（默认）
#   ./optimize-android-phone.sh --auto               安全档：搬白名单媒体 + 删可再生缓存 + 提速
#   ./optimize-android-phone.sh --dry-run --auto     同样流程，但只打印不动设备
#   ./optimize-android-phone.sh --move-media         只把媒体目录搬到外置卡
#   ./optimize-android-phone.sh --include-sounds     连同通话录音一起搬（见下方警告）
#   ./optimize-android-phone.sh --purge-cache        只删可再生缓存
#   ./optimize-android-phone.sh --trim-cached        杀掉缓存进程，当场回收内存
#   ./optimize-android-phone.sh --bg-limit 12        压低 AMS 缓存进程上限（show / reset）
#   ./optimize-android-phone.sh --scan-off           关掉「始终扫描 WLAN/蓝牙」（--scan-on 恢复）
#   ./optimize-android-phone.sh --compile            未冻结的第三方应用做全量 AOT
#   ./optimize-android-phone.sh --freeze pkg         冻结单个应用（--unfreeze pkg 解冻）
#   ./optimize-android-phone.sh --uninstall-frozen   显式才会卸载已冻结应用（--auto 不含）
#   ./optimize-android-phone.sh --rollback           按 ledger 复原设置、把媒体搬回机身
#   ./optimize-android-phone.sh --help               帮助
#
# 实测做不到的事（写在这是为了让下次别再试一遍）:
#   - EMUI 9 的 pm 没有 move-storage（返回 Unknown command: move-storage），
#     「把应用装到 SD 卡」这条路走不通，只能整理数据。
#   - 写 activity_manager_constants 的 max_cached_processes 只能改到常量本身，
#     EMUI 用 mOverrideMaxCachedProcesses 覆盖，CUR_MAX_CACHED_PROCESSES 不动（脚本会实测比对）。
#     真正当场有效的是 --trim-cached：实测 MemAvailable 1.45G -> 1.86G，缓存进程 16 -> 1。
#   - 无 root 读不到 /data/data，应用私有目录只能看 dumpsys diskstats 的近似值。
#   - /sys/class/thermal/* 普通 shell 读不到，报告跳过而不是报错。

set -uo pipefail  # 只对管道返回值严格检查；报告里全是 grep，开了 -e 会被「0 匹配」误杀

# ---------------------------------------------------------------- 颜色与日志
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[信息]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[成功]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }
log_step()  { echo -e "\n${GREEN}===== $1 =====${NC}"; }
die()       { log_error "$*"; exit 1; }

# ---------------------------------------------------------------- 名单与默认值
# 可搬白名单：纯媒体或已停用应用的残留，搬走不会让应用找不到东西。
# 每一项都是「机身 /storage/emulated/0 下的相对路径」，加新项前想清楚是谁在按路径读它。
MOVE_DIRS_DEFAULT="huawei/Themes Photo backup Music Movies"
# 通话录音默认不搬：788 个文件里只有 37 条进了媒体库，华为拨号是按绝对路径自己记账的，
# 搬走文件不会丢，但拨号里的「通话记录 -> 录音」可能打不开。
MOVE_DIR_SOUNDS="Sounds"

# 硬黑名单：应用按绝对路径自记账，搬走只会得到「图片已过期 / 要重新登录 / 离线地图重下」。
FORBIDDEN_REL="Android/data Android/obb Android/media Android/stranger tencent/MicroMsg Tencent/MicroMsg alipay autonavi amap Download DCIM"

# 可再生缓存：删掉最多让应用重新下一遍，不碰登录态和聊天记录。
CACHE_DIRS="tencent/tbs diamond/download AR/.ARResource Netease/webcache TbsReaderTemp BaiduPanoSDK sensetime"

# --auto 里 bg-limit 的默认值：24 个空进程在 4G+zram 上是纯换页压力，
# 留 12 个既能秒切常用应用，又能少一半内存占用。
AUTO_BG_LIMIT=12

SERIAL=""
SD_UUID=""
DRY_RUN=0
ASSUME_YES=0
INCLUDE_SOUNDS=0
ACTION="report"
BG_LIMIT=""
TARGET_PKG=""
COMPILE_PKGS=""
MODEL=""
ANDROID=""
SD_FREE=""

LEDGER_DIR="$HOME/.android-tune"
LEDGER=""

# ledger 是制表符分隔的纯文本，人要能直接 grep 看懂（bash 3.2 也没有 JSON 工具）。
#   SET<TAB>键<TAB>原值              系统设置写前的旧值
#   MOVED<TAB>相对路径<TAB>字节<TAB>文件数
#   PURGED<TAB>相对路径<TAB>KB       不可回滚
#   UNINSTALLED<TAB>包名<TAB>-<TAB>-

# ---------------------------------------------------------------- 基础封装
usage() {
    # 直接把文件头的中文注释打出来，省得帮助文本和注释两处维护
    awk 'NR > 2 && /^set / { exit } NR > 2 && /^#/ { sub(/^# ?/, ""); print }' "$0"
    exit 0
}

TMP_DIR=""
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

sh() { adb -s "$SERIAL" shell "$@"; }
sh_trim() { sh "$@" | tr -d '\r' | tr -d ' '; }

# 设备侧写操作：dry-run 只打印
sh_run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] adb shell $*"
        return 0
    fi
    adb -s "$SERIAL" shell "$@"
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && return 0          # 预演不该被问住
    local ans
    printf "%s [y/N] " "$1"
    read ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# 只接受 /storage/... 这种绝对路径且不含 shell 元字符——它要被拼进远端命令
safe_path() {
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in *[!A-Za-z0-9/_.-]*) return 1 ;; esac
    case "$1" in *..*) return 1 ;; esac
    return 0
}

safe_pkg() { case "$1" in *[!A-Za-z0-9_.]*) return 1 ;; esac; return 0; }

in_rel_list() {  # 精确等于或作为前缀命中
    local rel="$1" item
    for item in $2; do
        [ "$rel" = "$item" ] && return 0
        case "$rel" in "$item"/*) return 0 ;; esac
    done
    return 1
}

# 目录大小（KB）。必须用 du -sk：直接 du -k 再求和会把父目录和子目录重复累加，
# 实测 /storage/emulated/0/Android 被算成 76G，而 /data 总共才 54G。
dir_kb() {
    local v
    v=$(sh "du -sk '$1' 2>/dev/null | cut -f1" | tr -d '\r')
    is_num "$v" && echo "$v" || echo ""
}

dir_files() {
    local v
    v=$(sh "find '$1' -type f 2>/dev/null | wc -l" | tr -d ' \r')
    is_num "$v" && echo "$v" || echo ""
}

dir_bytes() {
    local v
    v=$(sh "find '$1' -type f -exec stat -c %s {} + 2>/dev/null | awk '{s+=\$1} END {print s+0}'" | tr -d ' \r')
    is_num "$v" && echo "$v" || echo ""
}

kb_h() {
    is_num "$1" || { echo "-"; return; }
    echo "$1" | awk '{ if ($1>=1048576) printf "%.1fG", $1/1048576; else if ($1>=1024) printf "%.0fM", $1/1024; else printf "%dK", $1 }'
}

# ---------------------------------------------------------------- ledger
ledger_mark() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    mkdir -p "$LEDGER_DIR"
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$LEDGER"
}

# 同一把钥匙只记第一次的旧值，否则把上一轮改过的值当原值存下来就回不去了
ledger_mark_setting() {
    local key="$1" old="$2"
    if [ -f "$LEDGER" ] && grep -q "^SET	$key	" "$LEDGER"; then
        return 0
    fi
    ledger_mark SET "$key" "$old" "-"
}

# ---------------------------------------------------------------- preflight
preflight() {
    command -v adb >/dev/null 2>&1 \
        || die "找不到 adb，请先装 platform-tools（brew install android-platform-tools）"

    local devs n
    devs=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
    n=$(printf '%s\n' "$devs" | grep -c . || true)
    if [ "$n" -eq 0 ]; then
        die "没有已连接的设备（查数据线，以及手机上「允许 USB 调试」的弹窗）"
    fi
    if [ "$n" -gt 1 ] && [ -z "$SERIAL" ]; then
        die "检测到 $n 台设备，请用 --serial 指定其一：$(printf '%s ' $devs)"
    fi
    [ -z "$SERIAL" ] && SERIAL=$(printf '%s\n' "$devs" | head -1)

    MODEL=$(sh 'getprop ro.product.model' | tr -d '\r')
    ANDROID=$(sh 'getprop ro.build.version.release' | tr -d '\r')
    local rom
    rom=$(sh 'getprop ro.build.version.emui' | tr -d '\r')
    [ -n "$MODEL" ] || die "读不到设备信息，adb 连接可能断了"

    mkdir -p "$LEDGER_DIR"
    LEDGER="$LEDGER_DIR/${SERIAL}.ledger.tsv"
    touch "$LEDGER"

    log_info "设备 ${SERIAL}｜${MODEL}｜Android ${ANDROID}${rom:+｜$rom}"
    log_info "操作记录 $LEDGER"
    [ "$DRY_RUN" -eq 1 ] && log_warn "dry-run：不会向设备写入任何内容"
}

# 外置卡：/mnt/media_rw 目录本身 shell 没权限 ls（实测 Permission denied），
# 所以从 mount 表里认 vfat 公共卷；退一步再拿 /storage 下的非固定项兜底。
detect_sd() {
    local mts uuid m
    mts=$(sh 'mount 2>/dev/null')
    uuid=$(printf '%s\n' "$mts" | awk \
        '$2 == "on" && $3 ~ /^\/mnt\/media_rw\// && $4 == "type" && $5 == "vfat" { sub(/.*\//, "", $3); print $3; exit }' \
        | tr -d '\r')
    if [ -z "$uuid" ]; then
        for m in $(sh 'ls /storage/ 2>/dev/null' | tr -d '\r'); do
            case "$m" in emulated|self|combined|sdcard0|sdcard1) continue ;; esac
            uuid="$m"
            break
        done
    fi
    [ -n "$uuid" ] || { SD_UUID=""; return 1; }
    sh "test -d '/storage/$uuid'" || { SD_UUID=""; return 1; }
    SD_UUID="$uuid"
    return 0
}

# 真搬东西之前才测写：能建能删才算这张卡真能用
sd_writable() {
    local probe="/storage/$SD_UUID/.tune-write-probe"
    sh "touch '$probe' 2>/dev/null && rm -f '$probe'"
}

sd_mount() { echo "/storage/$SD_UUID"; }

sd_free_kb() {
    local v
    v=$(sh "df -k '$(sd_mount)' 2>/dev/null | awk 'NR==2 {print \$4}'" | tr -d ' \r')
    is_num "$v" && echo "$v" || echo ""
}

snapshot_line() {
    local dfk mem swap procs
    dfk=$(sh "df -k /data | awk 'NR==2 {print \$4}'" | tr -d ' \r')
    mem=$(sh 'awk "/MemAvailable/ {print \$2}" /proc/meminfo' | tr -d ' \r')
    swap=$(sh 'awk "/SwapFree/ {print \$2}" /proc/meminfo' | tr -d ' \r')
    procs=$(sh_trim 'ps -A 2>/dev/null | wc -l')
    echo "/data 可用 $(kb_h "${dfk:-0}")｜MemAvailable $(kb_h "${mem:-0}")｜SwapFree $(kb_h "${swap:-0}")｜进程 ${procs:-?}"
}

# ---------------------------------------------------------------- 报告
report_storage() {
    log_step "存储"
    sh 'df -h /data'
    echo
    sh 'dumpsys diskstats 2>/dev/null | head -6' || true
    echo
    echo "外置卡:"
    if [ -n "$SD_UUID" ]; then
        sh "df -h '$(sd_mount)' | tail -1"
        echo "  挂载 $(sd_mount)，剩余 $(kb_h "${SD_FREE:-0}")"
    else
        log_warn "没检测到外置存储卡，媒体搬移类动作会跳过"
    fi
}

report_memory() {
    log_step "内存与调度"
    sh 'grep -E "MemTotal|MemAvailable|SwapTotal|SwapFree" /proc/meminfo | tr -s " "'
    echo
    # CUR_MAX_* 才是 OOM 分层真正在用的数；max_cached_processes 只是常量本身
    sh 'dumpsys activity settings 2>/dev/null | grep -E "max_cached_processes|OverrideMax|CUR_MAX"'
    echo -n "缓存进程: "; sh_trim 'dumpsys activity oom 2>/dev/null | grep -c "cached=true"'
    echo -n "总进程数: "; sh_trim 'ps -A 2>/dev/null | wc -l'
    echo
    echo "内存占用前 8（RSS，含已换出部分的话看不全，只看趋势）:"
    sh 'ps -A -o RSS,NAME 2>/dev/null | awk "NR>1 && \$1+0>0 {printf \"%7.0fM %s\n\", \$1/1024, \$2}" | sort -rn | head -8'
    local dex
    dex=$(sh 'ps -A -o NAME 2>/dev/null | grep -c dex2oat' | tr -d ' \r')
    is_num "$dex" || dex=0
    # 后台编译一边抢 CPU 一边写 /data，正在跑的时候别做提速动作也别下结论。
    # 别用 pgrep -f：它会把「sh -c pgrep -f dex2oat」这条自己的壳也匹配进去（实测误报）
    if [ "${dex:-0}" -gt 0 ]; then
        log_warn "dex2oat 正在后台编译，此刻测出来的「卡」多半是它造成的，等它跑完再复测"
    fi
}

report_cpu() {
    log_step "CPU 频率"
    sh 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do printf "%s " "$c"; cat "$c" 2>/dev/null || echo "-"; done' \
        | paste -s - | sed 's#/sys/devices/system/cpu/##g' || true
    echo
    sh 'top -n 1 -b 2>/dev/null | head -3' || true
    local t
    t=$(sh 'cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null' | tr -d '\r')
    if is_num "$t"; then
        echo "温度节点: $t"
    else
        log_info "温度节点普通 shell 读不到（无 root），跳过"
    fi
}

# dumpsys diskstats 返回的是几组按下标对齐的并行数组，要自己对齐才能算出每个包占多少。
# 坑：字段名是复数 App Sizes: 而不是 App Size:；Other Sizes 在本机是空数组，别当依据。
report_big_apps() {
    log_step "谁在吃 /data（dumpsys diskstats 近似值，无 root 只能到这个精度）"
    TMP_DIR="${TMP_DIR:-$(mktemp -d)}"
    sh 'dumpsys diskstats' > "$TMP_DIR/diskstats.txt"
    sh 'pm list packages -3 | sed "s/package://"' > "$TMP_DIR/pkg3.txt"
    /usr/bin/python3 - "$TMP_DIR/diskstats.txt" "$TMP_DIR/pkg3.txt" <<'PY'
import re, sys
data = open(sys.argv[1], errors='ignore').read()
third = set(open(sys.argv[2]).read().split())
MB = 1048576.0

def arr(key):
    m = re.search(r'^' + re.escape(key) + r': \[(.*?)\]', data, re.M | re.S)
    return [int(x) for x in re.findall(r'\d+', m.group(1))] if m else []

def scalar(key):
    m = re.search(r'^' + re.escape(key) + r': (\d+)', data, re.M)
    return int(m.group(1)) if m else 0

names = re.search(r'Package Names: \[(.*?)\]', data, re.S)
pkgs = [p.strip().strip('"') for p in names.group(1).split(',')] if names else []
A, D, C = arr('App Sizes'), arr('App Data Sizes'), arr('Cache Sizes')
rows = []
for i, p in enumerate(pkgs):
    g = lambda a: (a[i] / MB) if i < len(a) else 0.0
    tot = g(A) + g(D) + g(C)
    if tot >= 30:
        rows.append((tot, p, g(A), g(D), g(C), p in third))
rows.sort(reverse=True)
print('%7s %7s %7s %6s  %s' % ('合计M', 'APK+odex', '数据', '缓存', '包名'))
for tot, p, a, d, c, is3 in rows[:18]:
    print('%7.0f %7.0f %7.0f %6.0f  %s%s' % (tot, a, d, c, p, '  [第三方]' if is3 else ''))
print('第三方合计 %.1fG｜全机 APK %.1fG｜全机应用数据 %.1fG｜系统缓存 %.1fM' % (
    sum(r[0] for r in rows if r[5]) / 1024,
    scalar('App Size') / MB / 1024,
    scalar('App Data Size') / MB / 1024,
    scalar('App Cache Size') / MB))
PY
    echo
    echo "机身 Android/data 前 10（往往是最大单项，但不在可搬范围内）:"
    sh 'du -k -d 1 /storage/emulated/0/Android/data 2>/dev/null | sort -rn | sed 11q'
}

report_move_candidates() {
    log_step "可搬 / 勿搬（机身 /storage/emulated/0）"
    local list="$MOVE_DIRS_DEFAULT" rel kb src
    [ "$INCLUDE_SOUNDS" -eq 1 ] && list="$list $MOVE_DIR_SOUNDS"
    echo "白名单（脚本会搬）:"
    for rel in $list; do
        src="/storage/emulated/0/$rel"
        kb=$(dir_kb "$src")
        if [ -z "$kb" ]; then
            echo "    [不存在] $rel"
        elif [ "$kb" -lt 1024 ]; then
            echo "    [太小]   $(kb_h "$kb")  $rel"
        else
            echo "    [可搬]   $(kb_h "$kb")  $rel"
        fi
    done
    [ "$INCLUDE_SOUNDS" -eq 1 ] || echo "    通话录音 Sounds 需 --include-sounds（搬完拨号里的录音列表可能打不开）"
    echo
    echo "机身一级目录（>10M 才列）:"
    local d
    for d in $(sh 'ls /storage/emulated/0/ 2>/dev/null' | tr -d '\r'); do
        kb=$(dir_kb "/storage/emulated/0/$d")
        [ -z "$kb" ] && continue
        [ "$kb" -lt 10240 ] && continue
        if in_rel_list "$d" "$FORBIDDEN_REL"; then
            echo "    [勿搬] $(kb_h "$kb")  $d"
        elif [ "$d" = "Sounds" ] && [ "$INCLUDE_SOUNDS" -eq 0 ]; then
            echo "    [条件] $(kb_h "$kb")  $d  <- 要加 --include-sounds 才搬（录音列表可能打不开）"
        elif check_move_allowed "$d"; then
            echo "    [可搬] $(kb_h "$kb")  $d"
        else
            echo "    [未列] $(kb_h "$kb")  $d  <- 不在白名单，要搬先加进 MOVE_DIRS_DEFAULT"
        fi
    done
}

check_move_allowed() {
    local rel="$1"
    in_rel_list "$rel" "$FORBIDDEN_REL" && return 1
    in_rel_list "$rel" "$MOVE_DIRS_DEFAULT $MOVE_DIR_SOUNDS" && return 0
    return 1
}

report_frozen() {
    log_step "已冻结的应用"
    local list
    list=$(sh 'pm list packages -d | sed "s/package://"' | tr -d '\r')
    [ -z "$list" ] && { echo "  无"; return 0; }
    local p apk total=0
    for p in $list; do
        apk=$(sh "pm path '$p' 2>/dev/null | head -1 | sed 's/package://' | xargs stat -c %s 2>/dev/null" | tr -d ' \r')
        is_num "$apk" || apk=0
        total=$((total + apk))
        echo "  $(kb_h $((apk / 1024)))  $p"
    done
    echo "  base.apk 合计 $(kb_h $((total / 1024)))"
    log_warn "冻结不等于释放空间：这些包连 odex 和 lib 在内占的更多（见上面 App+odex 列），"
    log_warn "要真回收得 --uninstall-frozen（本次档位默认不含）"
}

report_ui_only() {
    log_step "只有你在手机上能做的（脚本改不了）"
    echo "  1) 把相机 / 截屏的默认存储位置改到 SD 卡，否则机身 /data 几周后又满回去"
    echo "  2) 手机管家 -> 应用启动管理，关掉不该自启的应用（EMUI 自己管，adb 侧不可靠）"
    echo "  3) 别用清理大师：本机 App Cache Size 只有几 MB，pm trim-caches 榨不出东西"
    echo "  4) 高德离线地图、微信聊天记录都在 Android/data 里，脚本不碰，删前要自己确认能重下"
    echo "  5) 高德离线地图想放卡上，只能在应用内切：离线地图(下载管理) -> 「更改存储位置」-> 外置卡。"
    echo "     这个切换会真的搬数据，中途拔卡或退出会导致失败并清掉已下载的离线包（必须重新下载），"
    echo "     所以脚本一律不代劳，也不要半途用 adb 点它的按钮"
}

do_report() {
    echo "基线: $(snapshot_line)"
    report_storage
    report_memory
    report_cpu
    report_big_apps
    report_move_candidates
    report_frozen
    if [ -n "$COMPILE_PKGS" ]; then
        log_step "待编译应用"
        printf '%s\n' "$COMPILE_PKGS" | sed '/^ *$/d; s/^/  /'
    fi
    report_ui_only
    log_ok "报告结束（本次未修改设备）"
}

# ---------------------------------------------------------------- 搬媒体
# 设备侧一次 adb 调用完成广播：3 个文件实测 323ms，逐文件起 adb 会慢一个数量级
rescan_dir() {
    local root="$1" total
    [ "$DRY_RUN" -eq 1 ] && return 0
    total=$(dir_files "$root")
    is_num "$total" || total=0
    if [ "$total" -gt 1500 ]; then
        log_warn "  $total 个文件太多，逐个广播要几分钟；改用手机「文件管理」触发扫描也行"
    fi
    log_info "  重建媒体索引（$total 个文件，设备侧循环）"
    # 不广播就查不到：今天实测搬过去后媒体库 0 条，逐文件广播后 663 图 + 19 视频。
    # 扫描是异步的——广播完立刻查会少几十条，别以为是失败（脚本在这里等两秒再报数）
    sh "for f in \$(find '$root' -type f); do am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \"file://\$f\" >/dev/null 2>&1; done"
    sleep 2
    local indexed
    indexed=$(sh "content query --uri content://media/external/file --projection _data 2>/dev/null | grep -c '$root'" | tr -d ' \r')
    log_info "  媒体库里 $root 下现在有 ${indexed:-0} 条（扫描异步，稍后还会再涨一些）"
}

# 源路径已删，媒体库里那些行会变死条目（实测：相册里显示成灰掉打不开的缩略图）。
# URI 必须是单数 content://media/external/file —— 复数 external/files 会静默失败，
# 这就是上一版搬完留着 48 条死索引的原因。
rescan_drop() {
    local root="$1"
    safe_path "$root" || { log_warn "清理死索引时路径不合法，跳过 $root"; return 0; }
    [ "$DRY_RUN" -eq 1 ] && return 0
    # LIKE 里的 _ 是单字符通配，因为路径本身已被前缀锚定，多匹配只会匹配同前缀下的兄弟名字，
    # 不会误删别的卷（机身/卡前缀不同），所以够用。
    sh "content delete --uri content://media/external/file --where \"_data LIKE '$root/%'\"" >/dev/null 2>&1
    log_info "  已清掉指向 $root 的死索引"
}

move_one_dir() {
    local rel="$1"
    local src="/storage/emulated/0/$rel"
    local dst="$(sd_mount)/$rel"
    safe_path "$src" || { log_warn "$rel 路径不合法，跳过"; return 1; }
    check_move_allowed "$rel" || { log_warn "$rel 不在白名单或落在黑名单，拒绝搬"; return 1; }
    safe_path "$dst" || { log_warn "目标路径不合法，跳过"; return 1; }

    local kb files bytes free
    kb=$(dir_kb "$src")
    [ -z "$kb" ] && { log_info "$rel 不存在，跳过"; return 0; }
    [ "$kb" -lt 1024 ] && { log_info "$rel 不足 1M，不值得动"; return 0; }
    files=$(dir_files "$src")
    bytes=$(dir_bytes "$src")
    free=$(sd_free_kb)
    if [ -z "$free" ] || [ "$kb" -gt "$free" ]; then
        log_warn "$rel 需要 $(kb_h "$kb")，外置卡只剩 $(kb_h "${free:-0}")，跳过"
        return 1
    fi

    # vfat 硬限制与非法字符预检
    local big maxb
    big=$(sh "find '$src' -type f -exec stat -c '%s %n' {} + 2>/dev/null | sort -rn | head -1")
    maxb=${big%% *}
    if is_num "$maxb" && [ "$maxb" -gt 4194304000 ]; then
        log_warn "$rel 有超过 4G 的单文件（vfat 上限），跳过：${big#* }"
        return 1
    fi
    if [ "$(sh "find '$src' -type f 2>/dev/null | grep -c '[:*?<>\"|]'" | tr -d ' \r')" != "0" ]; then
        log_warn "$rel 有文件名带 vfat 非法字符，跳过"
        return 1
    fi

    log_info "${rel}：$(kb_h "$kb")，${files:-0} 个文件 -> $dst"
    confirm "  确认搬移？" || { log_info "  已取消 $rel"; return 0; }

    sh_run "mkdir -p '$dst'"
    sh_run "cp -R '$src'/. '$dst/'" || { log_error "$rel 复制失败，源目录未动"; return 1; }
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "  [dry-run] 校验 / 改名暂存 / 重建索引 / 删源 全部跳过"
        ledger_mark MOVED "$rel" "${bytes:-0}" "${files:-0}"
        return 0
    fi

    # 文件数和总字节都要一致，差一个就不删源
    local dfiles dbytes
    dfiles=$(dir_files "$dst")
    dbytes=$(dir_bytes "$dst")
    if [ "${dfiles:-0}" != "${files:-0}" ] || [ "${dbytes:-0}" != "${bytes:-0}" ]; then
        log_error "$rel 校验不过（机身 ${files:-?} 个/${bytes:-?} 字节，卡上 ${dfiles:-?} 个/${dbytes:-?} 字节），保留源目录"
        sh "rm -rf '$dst'"
        return 1
    fi

    # 改名而不是直接删：中途断电/拔线也不会丢数据
    local pending="/storage/emulated/0/.tune-pending-$(echo "$rel" | tr '/' '_')-$(date +%Y%m%d-%H%M%S)"
    sh "mv '$src' '$pending'" || { log_error "$rel 源目录改名失败，卡上那份请手工核对"; return 1; }
    log_info "  源目录改名暂存 $(basename "$pending")"
    rescan_dir "$dst"
    rescan_drop "$src"
    sh "rm -rf '$pending'" && log_ok "  $rel 完成，释放 $(kb_h "$kb")"
    ledger_mark MOVED "$rel" "${bytes:-0}" "${files:-0}"
    return 0
}

do_move_media() {
    log_step "搬媒体到外置卡"
    detect_sd || die "没检测到外置存储卡，搬移无法进行"
    if [ "$DRY_RUN" -eq 0 ] && ! sd_writable; then
        die "外置卡 $(sd_mount) 不可写：先确认不是「只读」，或在手机上把它设为存储设备"
    fi
    log_info "外置卡 $(sd_mount) 可写，剩余 $(kb_h "${SD_FREE:-0}")"
    local rel list="$MOVE_DIRS_DEFAULT"
    [ "$INCLUDE_SOUNDS" -eq 1 ] && list="$list $MOVE_DIR_SOUNDS"
    for rel in $list; do
        sh "test -d '/storage/emulated/0/$rel'" || continue
        move_one_dir "$rel" || log_warn "  $rel 未完成，机身那份仍然保留"
    done
}

# ---------------------------------------------------------------- 删缓存
do_purge_cache() {
    log_step "删可再生缓存"
    local rel kb before after total=0
    before=$(sh "df -k /data | awk 'NR==2 {print \$4}'" | tr -d ' \r')
    for rel in $CACHE_DIRS; do
        kb=$(dir_kb "/storage/emulated/0/$rel")
        [ -z "$kb" ] && continue
        [ "$kb" -lt 1024 ] && continue
        log_info "$rel $(kb_h "$kb")"
        if confirm "  删除？（应用会自己重建）"; then
            sh_run "rm -rf '/storage/emulated/0/$rel'" && ledger_mark PURGED "$rel" "$kb" "-"
            total=$((total + kb))
        fi
    done
    # 冻结应用的 Android/data：人都不用了，缓存留着只是占 /data；不碰 /data/data 里的登录态
    local p d
    for p in $(sh 'pm list packages -d | sed "s/package://"' | tr -d '\r'); do
        safe_pkg "$p" || continue
        d=$(dir_kb "/storage/emulated/0/Android/data/$p")
        [ -z "$d" ] && continue
        [ "$d" -lt 1024 ] && continue
        log_info "Android/data/$p $(kb_h "$d")（该应用已冻结）"
        if confirm "  删除？"; then
            sh_run "rm -rf '/storage/emulated/0/Android/data/$p'" && ledger_mark PURGED "Android/data/$p" "$d" "-"
            total=$((total + d))
        fi
    done
    after=$(sh "df -k /data | awk 'NR==2 {print \$4}'" | tr -d ' \r')
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[dry-run] 以上项合计 $(kb_h "$total")，真跑才会删"
    else
        log_ok "已请求删除 $(kb_h "$total")；/data 可用 $(kb_h "${before:-0}") -> $(kb_h "${after:-0}")"
    fi
}

# ---------------------------------------------------------------- 提速
do_trim_cached() {
    log_step "回收缓存进程"
    local m0 m1 c0 c1
    m0=$(sh 'awk "/MemAvailable/ {print \$2}" /proc/meminfo' | tr -d ' \r')
    c0=$(sh_trim 'dumpsys activity oom 2>/dev/null | grep -c "cached=true"')
    sh_run 'am kill-all'
    [ "$DRY_RUN" -eq 1 ] || sleep 3
    m1=$(sh 'awk "/MemAvailable/ {print \$2}" /proc/meminfo' | tr -d ' \r')
    c1=$(sh_trim 'dumpsys activity oom 2>/dev/null | grep -c "cached=true"')
    log_ok "缓存进程 ${c0:-?} -> ${c1:-?}，MemAvailable $(kb_h "${m0:-0}") -> $(kb_h "${m1:-0}")"
    log_info "缓存进程本来就是随时可重启的，不丢登录态；应用再用一会儿会重新长回去，隔一两天跑一次"
}

# 注意 dumpsys 输出是 KEY=VALUE 连写，不能用 awk 取 $2（取到的是整串）
cur_max_cached() {
    sh 'dumpsys activity settings 2>/dev/null | sed -n "s/.*CUR_MAX_CACHED_PROCESSES=\([0-9]*\).*/\1/p"' | tr -d ' \r'
}

do_bg_limit() {
    log_step "后台进程上限（activity_manager_constants: max_cached_processes）"
    local cur before after new
    cur=$(sh 'settings get global activity_manager_constants' | tr -d '\r')
    [ "$cur" = "null" ] && cur=""
    before=$(cur_max_cached)

    if [ "$BG_LIMIT" = "show" ]; then
        echo "  setting 原文: ${cur:-<空，走系统默认>}"
        sh 'dumpsys activity settings 2>/dev/null | grep -E "max_cached_processes|OverrideMax|CUR_MAX"'
        return 0
    fi
    if [ "$BG_LIMIT" = "reset" ]; then
        [ -z "$cur" ] && { log_info "本来就是默认值，无需恢复"; return 0; }
        ledger_mark_setting activity_manager_constants "$cur"
        sh_run 'settings delete global activity_manager_constants'
        log_ok "已删除自定义值，回到系统默认"
        return 0
    fi
    is_num "$BG_LIMIT" || die "--bg-limit 需要数字、show 或 reset"

    if [ -z "$cur" ]; then
        new="max_cached_processes=$BG_LIMIT"
    else
        new=$(echo "$cur" | sed -E "s/max_cached_processes=[0-9]+/max_cached_processes=$BG_LIMIT/")
        case "$new" in *max_cached_processes=*) ;; *) new="$cur max_cached_processes=$BG_LIMIT" ;; esac
    fi
    ledger_mark_setting activity_manager_constants "$cur"
    sh_run "settings put global activity_manager_constants '$new'"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[dry-run] 真跑时实测 CUR_MAX_CACHED_PROCESSES（当前 ${before:-?}）有没有跟着降，再判断这项是否被 ROM 吃掉"
        return 0
    fi
    sleep 1
    after=$(cur_max_cached)
    echo "  CUR_MAX_CACHED_PROCESSES: ${before:-?} -> ${after:-?}"
    if [ "${before:-0}" = "${after:-0}" ]; then
        # 常量写了不等于生效：EMUI 用 mOverrideMaxCachedProcesses 覆盖，必须实测比对
        log_warn "CUR_MAX_* 没变，说明这项被 ROM 自己的覆盖值吃掉了，在这台机器上收效有限"
        log_info "真正当场有效的是 --trim-cached，或开发者选项里的「后台进程限制」"
    else
        log_ok "已生效（缓存进程上限降到 ${BG_LIMIT}，切应用可能冷启动）"
    fi
}

do_scan() {
    local want="$1" key v old
    log_step "始终扫描 WLAN / 蓝牙 -> $want"
    for key in wifi_scan_always_enabled bluetooth_scan_always_enabled; do
        v=$(sh "settings get global $key" | tr -d '\r')
        [ "$v" = "null" ] && v=""
        if [ "$want" = "off" ]; then
            ledger_mark_setting "$key" "$v"
            sh_run "settings put global $key 0"
        else
            old=$(awk -F'\t' -v k="$key" '$1=="SET" && $2==k {print $3; exit}' "$LEDGER" 2>/dev/null)
            if [ -n "$old" ]; then
                sh_run "settings put global $key '$old'"
            else
                sh_run "settings delete global $key"
            fi
        fi
        [ "$DRY_RUN" -eq 1 ] || echo "  $key: ${v:-<未设置>} -> $(sh "settings get global $key" | tr -d '\r')"
    done
    log_info "关掉只是不再「没连网络也找附近网络」，省电也少被唤醒；连上网络后不影响使用"
}

do_compile() {
    log_step "全量 AOT 编译（cmd package compile -m speed -f）"
    local pkgs="$COMPILE_PKGS" p out
    if [ -z "$pkgs" ]; then
        # 只处理未冻结的第三方包：系统包 ROM 自己调过，冻着的包编了也白编
        pkgs=$(sh 'comm -23 <(pm list packages -3 | sed "s/package://" | sort) <(pm list packages -d | sed "s/package://" | sort)' | tr -d '\r')
    fi
    [ -z "$pkgs" ] && { log_info "没有可编译的第三方包"; return 0; }
    for p in $pkgs; do
        safe_pkg "$p" || { log_warn "跳过非法包名 $p"; continue; }
        printf '  %-40s ' "$p"
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[dry-run]"
            continue
        fi
        out=$(sh "cmd package compile -m speed -f '$p'" 2>&1 | tr -d '\r')
        echo "${out:-完成}"
    done
    log_warn "speed 是完整 AOT：启动更快，但 odex 变大，且这轮 CPU 会跑满几分钟——"
    log_warn "跑完别立刻测反应速度，等 dex2oat 自己结束（报告里会提示）"
}

do_freeze() {
    local mode="$1" p="$TARGET_PKG"
    [ -n "$p" ] || die "--$mode 需要包名"
    safe_pkg "$p" || die "包名不合法: $p"
    log_step "$mode $p"
    if [ "$mode" = "freeze" ]; then
        confirm "  冻结 ${p}？（应用列表里消失、不再自启，数据保留）" || return 0
        sh_run "pm disable-user --user 0 '$p'"
    else
        sh_run "pm enable '$p'"
    fi
    [ "$DRY_RUN" -eq 1 ] || log_ok "已提交，当前状态: $(sh "pm list packages -d | grep -c \"^package:$p\$\"" | tr -d ' \r') 处于冻结"
}

do_uninstall_frozen() {
    log_step "卸载已冻结应用（显式操作，--auto 不含）"
    local p list found=0
    list=$(sh 'pm list packages -d | sed "s/package://"' | tr -d '\r')
    [ -z "$list" ] && { log_info "没有已冻结的应用"; return 0; }
    for p in $list; do
        safe_pkg "$p" || continue
        found=1
        log_info "$p"
        if confirm "  从当前用户卸载？APK 才真被释放；pm install-existing $p 可恢复"; then
            sh_run "pm uninstall -k --user 0 '$p'" && ledger_mark UNINSTALLED "$p" "-" "-"
        fi
    done
    [ "$found" -eq 0 ] && log_info "冻结列表为空"
}

# ---------------------------------------------------------------- 回滚
reverse_lines() {
    awk '{a[NR]=$0} END {for (i=NR; i>0; i--) print a[i]}'
}

do_rollback() {
    log_step "按 ledger 回滚"
    [ -s "$LEDGER" ] || { log_info "没有记录，无需回滚"; return 0; }
    log_warn "PURGED 项不可回滚（删的就是可再生缓存，本来也会自己长回来）"
    detect_sd || log_warn "外置卡没插上，搬移项无法回滚"

    local key old
    for key in $(awk -F'\t' '$1=="SET" {print $2}' "$LEDGER" | sort -u); do
        old=$(awk -F'\t' -v k="$key" '$1=="SET" && $2==k {print $3; exit}' "$LEDGER")
        if [ -n "$old" ]; then
            sh_run "settings put global $key '$old'"
        else
            sh_run "settings delete global $key"
        fi
        echo "  复原 $key -> ${old:-<默认>}"
    done

    local rel src dst
    for rel in $(awk -F'\t' '$1=="MOVED" {print $2}' "$LEDGER" | reverse_lines); do
        safe_path "/storage/emulated/0/$rel" || continue
        [ -n "$SD_UUID" ] || break
        src="$(sd_mount)/$rel"
        dst="/storage/emulated/0/$rel"
        sh "test -d '$src'" || continue
        log_info "把 $rel 搬回机身"
        confirm "  确认？" || continue
        sh_run "mkdir -p '$dst'"
        if sh_run "cp -R '$src'/. '$dst/'"; then
            [ "$DRY_RUN" -eq 1 ] || sh "rm -rf '$src'"
            rescan_dir "$dst"
            rescan_drop "$src"      # 卡上那份没了，索引也得跟着清
        fi
    done

    local p
    for p in $(awk -F'\t' '$1=="UNINSTALLED" {print $2}' "$LEDGER" | sort -u); do
        safe_pkg "$p" || continue
        log_info "恢复曾被卸载的 $p"
        confirm "  pm install-existing ${p}？" && sh_run "pm install-existing '$p'"
    done
    log_ok "回滚结束（$(snapshot_line)）"
}

# ---------------------------------------------------------------- 参数与主流程
main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --report)           ACTION="report" ;;
            --auto)             ACTION="auto" ;;
            --move-media)       ACTION="move" ;;
            --purge-cache)      ACTION="purge" ;;
            --trim-cached)      ACTION="trim" ;;
            --bg-limit)
                # 带值参数：值缺失就当 show，只看不改
                ACTION="bglimit"
                [ $# -ge 2 ] || die "--bg-limit 需要数字、show 或 reset"
                BG_LIMIT="$2"; shift ;;
            --bg-limit=*)       ACTION="bglimit"; BG_LIMIT="${1#*=}" ;;
            --scan-off)         ACTION="scanoff" ;;
            --scan-on)          ACTION="scanon" ;;
            --compile)
                ACTION="compile"
                # 后面连续的非选项参数都当包名收进编译清单
                while [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; do
                    COMPILE_PKGS="$COMPILE_PKGS $2"; shift
                done ;;
            --freeze)
                ACTION="freeze"
                [ $# -ge 2 ] || die "--freeze 需要包名"
                TARGET_PKG="$2"; shift ;;
            --unfreeze)
                ACTION="unfreeze"
                [ $# -ge 2 ] || die "--unfreeze 需要包名"
                TARGET_PKG="$2"; shift ;;
            --uninstall-frozen) ACTION="uninstall" ;;
            --rollback)         ACTION="rollback" ;;
            --include-sounds)   INCLUDE_SOUNDS=1 ;;
            --dry-run)          DRY_RUN=1 ;;
            --yes)              ASSUME_YES=1 ;;
            --serial)
                [ $# -ge 2 ] || die "--serial 后面要跟序列号"
                SERIAL="$2"; shift ;;
            --help|-h)          usage ;;
            *)                  die "未知参数: $1（--help 看用法）" ;;
        esac
        shift
    done

    preflight
    detect_sd || log_info "没检测到外置存储卡：涉及媒体的动作会被跳过"
    SD_FREE=$(sd_free_kb)

    case "$ACTION" in
        report)    do_report ;;
        auto)
            # 安全档：只搬白名单、只删可再生缓存、只改能回滚的设置；绝不卸载任何应用
            log_info "动手前基线: $(snapshot_line)"
            do_move_media
            do_purge_cache
            BG_LIMIT="$AUTO_BG_LIMIT"
            do_bg_limit
            do_scan off
            do_trim_cached
            do_report
            ;;
        move)      do_move_media ;;
        purge)     do_purge_cache ;;
        trim)      do_trim_cached ;;
        bglimit)   do_bg_limit ;;
        scanoff)   do_scan off ;;
        scanon)    do_scan on ;;
        compile)   do_compile ;;
        freeze)    do_freeze freeze ;;
        unfreeze)  do_freeze unfreeze ;;
        uninstall) do_uninstall_frozen ;;
        rollback)  do_rollback ;;
        *)         die "内部错误：未知动作 $ACTION" ;;
    esac
}

main "$@"
