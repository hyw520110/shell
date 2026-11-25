#!/usr/bin/env bash
# =============================================================================
# update-proxy-nodes.sh - mihomo(Clash) 系客户端的免费节点订阅刷新脚本
# -----------------------------------------------------------------------------
# - 不绑客户端：内核是 mihomo 就能用（ClashX Meta / Clash Verge Rev / 独立 mihomo），
#   配置目录、内核二进制、控制 API 都自动探测，也可用 --client/--config/--api 指定
# - 拉取公开免费订阅（Clash YAML 或 ss/vmess/vless/... 链接列表），转成 Clash 节点并去重
# - 用一次性内核逐个真实握手测活，再结合 <配置名>.state.json 的履历增删节点：
#   测通的按延迟写入，暂时挂了的保留观察（连续失败未满 --keep-fails 轮、或无效未满 --keep-hours 小时），
#   从没用过的当新面孔保留 --keep-new 轮，两个门槛都满或上游下架的删除。--no-test 可跳过测活全量写入
# - 菜单排序：本轮测通 > 本轮不判 > 观察期 > 源未拉到 > 新面孔，
#   同层里亚洲优先、同国聚拢、组内按延迟，
#   「没用过」的新面孔只进手动菜单，不进自动测速组（免得客户端成倍多发探针）
#   同一国家默认最多先排 --per-country 个（超出的补在本层末尾，不丢节点），--prefer 可点名提权
# - 默认（standalone）生成一份独立 profile free-nodes.yaml，国内流量全部直连；
#   --proxy-only 改为精确白名单：只有 --extra-proxy 点名的域名 + github/google/openai 走节点，其余 DIRECT
# - --inject 只往主配置里写 marker 包裹的托管区块 + 独立节点文件，
#   自建节点、DNS、TUN、分流规则原样保留
# - 落盘前用 mihomo -t 校验，原子写入并保留时间戳备份
# - --install-schedule / --remove-schedule 设置或取消定时刷新（launchd，日志落 ~/.net_proxy/logs/）
# -----------------------------------------------------------------------------
# 用法:
#   ./update-proxy-nodes.sh                       # 生成独立 profile free-nodes.yaml
#   ./update-proxy-nodes.sh --dry-run             # 只看增删，不写文件
#   ./update-proxy-nodes.sh --no-test             # 跳过测活，抽到什么写什么（快）
#   ./update-proxy-nodes.sh --inject              # 注入主配置的托管区块
#   ./update-proxy-nodes.sh --install-schedule    # 每 6 小时自动刷新
#   ./update-proxy-nodes.sh --schedule-status     # 看定时任务装没装、下次何时跑
# =============================================================================

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
# launchd 日志里每一轮都追加进同一个文件，没有绝对时间就没法区分是哪一轮；
# 所以由 SCHEDULE_LOG_PREFIX 统一加时间戳，交互运行时留空，终端观感不变
# 参数: 颜色 标签 消息...
log_line() {
    local color="$1" label="$2" to_err="$3"; shift 3
    local msg="$*"
    local ts=""
    if [[ -n "$SCHEDULE_LOG_PREFIX" ]]; then
        ts="$(date '+%F %T' 2>/dev/null || echo '?') "
    fi
    if [[ "$to_err" == 1 ]]; then
        echo -e "${ts}${color}[${label}]${NC} ${msg}" >&2
    else
        echo -e "${ts}${color}[${label}]${NC} ${msg}"
    fi
}
info()    { log_line "$BLUE"   "信息" 0 "$*"; }
success() { log_line "$GREEN"  "成功" 0 "$*"; }
warn()    { log_line "$YELLOW" "警告" 0 "$*"; }
error()   { log_line "$RED"    "错误" 1 "$*"; }
die()     { error "$*"; exit 1; }

# 定时任务跑时给每行加时间戳；交互运行不设，终端输出保持原样
SCHEDULE_LOG_PREFIX="${PROXY_NODES_SCHEDULE_LOG:-}"

DEFAULT_SOURCES=(
    "https://raw.githubusercontent.com/zhuhaiuk/free-nodes/main/clash_config.yaml"
    "https://raw.githubusercontent.com/PuddinCat/BestClash/main/proxies.yaml"
    "https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/Eternity.yml"
    "https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub"
    # 这两家是 2026-11-02 实测后加的：原四源整池只有 15 个测通、最快 787ms，
    # 加完变成 45 个测通、最快 253ms。TopFree 自己聚合 16 家、2713 个节点，
    # 但它 health.json 里 connectivity_tested=false（只做过引擎校验），
    # 出境连通性全靠本脚本的隔离内核测，别信它的「健康」标记。
    # 代价是候选量约 9 倍、一轮测活从 1 分半变成 6 分半（6 小时一次的定时任务可以接受）。
    # 排在最后是有意的：同名节点由先列出的源决定显示名，放后面不动现有节点的叫法。
    "https://raw.githubusercontent.com/VPN-Subcription-Links/ClashX-V2Ray-TopFreeProxy/main/combine/clash.config.yaml"
    "https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/clash.yml"
)

MODE="${PROXY_NODES_MODE:-${CLASH_META_MODE:-standalone}}"   # standalone | inject
CLIENT="${PROXY_NODES_CLIENT:-auto}"               # auto | meta | verge | mihomo
CONFIG_FILE="${PROXY_NODES_CONFIG:-${CLASH_META_CONFIG:-}}"
FINAL_CONFIG=""
SOURCE_FAILED=0
GROUP_NAME="免费节点"
SELECT_GROUP="节点选择"
PROVIDER_NAME="free-nodes"
MIXED_PORT="${PROXY_NODES_MIXED_PORT:-${CLASH_META_MIXED_PORT:-7890}}"
SOURCES=()
INTEGRATE_LOCAL="${INTEGRATE_LOCAL:-0}"
# 名额按层级从上往下填（测通 → 本轮不判 → 暂时不通 → 源没拉到 → 没用过）。放宽到 3 天删除后
# 「暂时不通」一层会多占位置，60 个会把新面孔挤光，所以默认给到 120：保住几成新的候选
MAX_NODES="${MAX_NODES:-120}"
MIN_NODES="${MIN_NODES:-5}"
TEST_TIMEOUT="${TEST_TIMEOUT:-5000}"
CONCURRENCY="${CONCURRENCY:-16}"
KEEP_FAILS="${KEEP_FAILS:-3}"
KEEP_NEW="${KEEP_NEW:-3}"                          # 从没通过过的新节点先观察几轮，而不是一轮就删
# 删除要同时满足「连败满 KEEP_FAILS 轮」和「无效满 KEEP_HOURS 小时」，两个条件里更长的那个说了算。
# 只按轮数不安全：轮数取决于定时频率（每 6 小时一轮时 3 轮才 18 小时，改成每小时一轮就只有 3 小时），
# 按时长才真的保证「至少观察 3 天」
KEEP_HOURS="${KEEP_HOURS:-72}"
TEST_URL=""
# 测活地址必须选「只有出了境才连得上」的：用 cp.cloudflare.com 时，免费池里那些中国出口节点
# （广东省广州市+华为云 这类）也能拿到 204 被判「测通」，选中后 Google/OpenAI 一个都打不开。
# google 的 204 才是这台机器真正的用途（agy/codex），过不了它的节点就没资格进菜单
# OpenAI 可达性：google 204 能过 ≠ OpenAI 能过（OpenAI/Cloudflare 对数据中心 IP 风控更严，
# 数据中心 IP 常是 google 通但 chatgpt.com/api.openai.com 403）。codex 走 chatgpt.com，
# 所以入选测活要同时过 google 和 OpenAI 两个，只过 google 的节点进菜单后 codex 仍会 403。
# OPENAI_TEST_URL 留空 = 不做 OpenAI 检测（向后兼容）；默认非空即启用。
OPENAI_TEST_URL="${PROXY_NODES_OPENAI_TEST_URL:-https://chatgpt.com/backend-api/codex/models}"
# HEALTH_URL = 写入配置的 url-test/fallback 运行时探测地址。它决定「节点是否活着」，
# 与入选测活（TEST_URL）是两回事：入选用 google 过滤掉中国出口节点（只有真能上
# Google/OpenAI 的才进菜单），运行时用 cp.cloudflare.com 探测这些已入选的境外节点谁还
# 活着——因为入选节点都是境外节点，Cloudflare 对它们都能通，不会像 google 那样因为
# 免费节点普遍连不通 google 而让 url-test 恒失败（那等于没有自动切换）。
# 若你希望 url-test 也严格按 google 判活，把这里改回 google 即可。
HEALTH_URL="${PROXY_NODES_HEALTH_URL:-http://cp.cloudflare.com/generate_204}"
PROVIDER_INTERVAL="${PROVIDER_INTERVAL:-43200}"
KEEP_BACKUPS=5
CLASH_API="${CLASH_API:-}"                          # 留空则按探测到的客户端决定
BUNDLE_ID="${BUNDLE_ID:-com.metacubex.ClashX.Meta}"
MIHOMO_BIN="${MIHOMO_BIN:-}"
EXTRA_DIRECT=()                                     # 额外指定直连的域名后缀
NO_PROXY_FILE="${PROXY_NODES_NO_PROXY_FILE:-$HOME/.net_proxy/no_proxy}"   # 与 net_proxy.sh 共用的例外清单
EXTRA_PROXY=()                                      # 额外指定走节点的域名后缀
PROXY_FILE="${PROXY_NODES_PROXY_FILE:-$HOME/.net_proxy/proxy_domains}"   # 白名单模式下走代理的精确域名后缀清单
PROXY_ONLY="${PROXY_NODES_PROXY_ONLY:-1}"           # 1 = 精确白名单（默认，大部分直连），0 = 黑名单（默认走节点）
PER_COUNTRY="${PROXY_NODES_PER_COUNTRY:-5}"         # 同一国家最多排几个，0 为不限
PREFER="${PROXY_NODES_PREFER:-}"                    # 点名要排在最前的国家（ISO 码）
DO_TEST=1
DRY_RUN=0
FORCE=0
SET_DEFAULT=0
DO_RELOAD=0

# 定时任务：launchd 比 cron 好在到点若在睡眠，唤醒后会补跑一次；输出落 ~/.net_proxy/logs/
SCHEDULE_LABEL="com.mac.proxy-nodes-refresh"
SCHEDULE_LEGACY_LABEL="com.mac.clash-meta-refresh"
SCHEDULE_HOURS=6
SCHEDULE_ACTION=""                                  # install | remove | status
# launchd 输出默认全丢 /dev/null，定时任务跑失败只能看到退出码，完全没法排障。
# 现在落到固定文件，由 PROXY_NODES_SCHEDULE_LOG=1 告诉日志函数加时间戳
# （交互运行不设这个变量，输出照旧不带时间戳，不改变终端观感）。
SCHEDULE_LOG="${PROXY_NODES_SCHEDULE_LOG:-$HOME/.net_proxy/logs/proxy-nodes-refresh.log}"

MARK_BEGIN='# proxy-nodes-refresh:begin'
MARK_END='# proxy-nodes-refresh:end'
GENERATED_MARK='# proxy-nodes-refresh:standalone'
# 改名（clash-meta-refresh.sh → update-proxy-nodes.sh）之前写入的区块用的是另一对标记，
# 摘除时新旧都要认，否则用户主配置里的旧区块会变成删不掉的孤儿
LEGACY_MARK_BEGIN='# clash-meta-refresh:begin'
LEGACY_MARK_END='# clash-meta-refresh:end'

show_help() {
    cat <<EOF
mihomo(Clash) 系客户端的免费节点订阅刷新脚本（ClashX Meta / Clash Verge Rev / 独立 mihomo）

用法: $0 [选项]

产出模式:
  （默认）standalone    生成独立 profile，整份覆盖，不改动其它配置
  --inject              只维护主配置里 marker 包裹的托管区块 + 独立节点文件

客户端与配置目标:
  --client WHICH        meta | verge | mihomo | auto。默认 auto，按配置目录存在的顺序探测：
                        ~/.config/clash.meta → Verge Rev 的 Application Support → ~/.config/mihomo
  --config PATH         目标配置文件。standalone 默认: <客户端目录>/free-nodes.yaml
                        inject 默认: <客户端目录>/yuanhang.yaml
  --group NAME          托管代理组名。默认: $GROUP_NAME
  --select-group NAME   standalone 模式下菜单里选用的 select 组。默认: $SELECT_GROUP
  --provider-name NAME  inject 模式的 provider 名。默认: $PROVIDER_NAME
  --set-default         把该 profile 写入 ClashX Meta 的 selectConfigName（需应用已退出，只有 meta 支持）
  --reload              通过 API 通知运行中的内核重载（尽力而为，失败就在客户端手动点一次）
  --api URL             客户端 API。默认按客户端探测（meta 9090 / verge 9097 或其 unix socket）
  --bundle-id ID        --set-default / --reload 检测用的 bundle id。默认: $BUNDLE_ID

订阅来源:
  --source URL          订阅地址，可重复；一旦使用即取代内置默认源
                        Clash YAML 和 ss:// vmess:// vless:// trojan:// 等链接列表都能吃
  --integrate-local     整合同目录其他配置文件（如自建节点 yuanhang.yaml）的节点一起测活；
                        只有过 google+OpenAI 检测的才入选。当订阅源里可用节点太少/全是
                        国内节点时用它，能访问 codex 的节点会优先入选
  --openai-test-url URL 覆盖 OpenAI 可达性检测地址（默认 chatgpt.com/backend-api/codex/models）。
                        留空则不做 OpenAI 检测（只按 google 判活）
  --max-nodes N         最多写入的节点数，0 为不限。默认: $MAX_NODES
  --min-nodes N         入选节点不足 N 时放弃本轮写入，保留上一份配置。默认: $MIN_NODES

测活与增删:
  （默认）逐个真实握手：通过的写入并按延迟排序；本轮不通的看历史履历——
          以前能用过、还没连续失败满 --keep-fails 轮或没无效满 --keep-hours 小时的算「暂时挂了」，
          保留并在名字上标注；从没用过的当「新面孔」保留 --keep-new 轮；连败和时长两个门槛都满才删，
          上游下架的也要满 --keep-hours 才删（源抽风漏列一个节点不该把它清掉）
  --no-test             跳过测活，抽取到的节点全部写入（不读写履历，快，但死的混在菜单里）
  --keep-fails N        连续失败几轮才判定彻底不可用（还要同时无效满 --keep-hours 小时才真删）。
                        默认: $KEEP_FAILS
  --keep-hours N        无效满多少小时才允许删除，默认 $KEEP_HOURS 小时（=3 天）。
                        按轮数删除不看频率：每 6 小时一轮时 3 轮才 18 小时，改成每小时一轮更是只有
                        3 小时，节点会被过早清空；这个门槛把「至少观察几天」固定下来。0 为只看轮数
  --keep-new N          从没用过的节点先保留观察几轮（免费源通过率只有百分之几，
                        一轮就删会让菜单只剩几个）。默认: $KEEP_NEW
  --test-url URL        测活地址，需返回 2xx/3xx。默认: 配置里的 test-url，再回退 $HEALTH_URL
  --timeout MS          单节点超时（毫秒）。默认: $TEST_TIMEOUT
  --concurrency N       并发数。默认: $CONCURRENCY
  --health-url URL      写入健康检查/测速的地址。默认: $HEALTH_URL
  --core PATH           指定 mihomo 内核（测活与校验用）
  --extra-direct DOMAIN  额外直连的域名后缀，可重复；standalone 里展开成 DOMAIN-SUFFIX,<d>,DIRECT
                         另外会自动读 ~/.net_proxy/no_proxy（与 net_proxy.sh 同一份例外清单），
                         让「国内但 GEOSITE 没认出来」的域名（qoder.sh、deepseek.com 这类）不必绕道节点
  --extra-proxy DOMAIN  点名要走节点的域名后缀，可重复；排在 cn 直连规则之前，
                        所以 .cn 里想代理的站也能拉回节点隧道
  --proxy-only          精确白名单模式：走节点的只有 --extra-proxy 点名的精确域名后缀，
                        加 github/google/openai 保险类别，其余一律直连（默认是全局走节点）

菜单排序:
  本轮测通 > 本轮不判（出网骤降）> 观察期（暂时不通）> 源没拉到暂留 > 新面孔（从没用过）；
  同一层里先按地区（中国/港澳 → 东亚 → 东南亚 → 南亚中东中亚 → 欧洲 → 北美 → 南美 → 大洋洲 → 非洲 → 未知），
  再按国家把同一个国家排在一起，同国家内按延迟从快到慢
  --per-country N       同一国家最多排在前面 N 个，0 为不限。默认: $PER_COUNTRY
                        （超出名额的不会丢，只是挪到本国名额用完之后再连续补上，避免同一家服务商刷屏）
  --prefer CODES        点名排到最前的国家，ISO 两位码、逗号或空格分隔，如 --prefer JP,KR,SG
                        只在同一层内提权，不会把没测通的节点顶到测通的之前

其他:
  --keep-backups N      保留备份数。默认: $KEEP_BACKUPS
  --force               standalone 模式允许覆盖非本脚本生成的配置文件
  --dry-run             打印将要发生的变化，不写任何文件
  -h, --help            显示帮助

定时刷新（launchd，到点在睡眠则唤醒后补跑；输出落 ${SCHEDULE_LOG}）:
  --install-schedule    安装定时任务，默认每 $SCHEDULE_HOURS 小时一次
  --remove-schedule     取消并删除定时任务
  --schedule-status     查看是否已安装、执行路径与计划时间
  --schedule-hours N    配合 --install-schedule 改间隔小时数
                        定时任务是纯后台刷新：跑完仍需手动在客户端点一次重载

说明:
  - 履历文件与配置同名：<客户端目录>/<配置名>.state.json，
    记录每个节点指纹的连续失败次数/最后成功时间/最近延迟/整体通过率，
    用来区分暂时挂和彻底死。删掉这个文件等于从零开始判断（没测通的节点全当新面孔，重新观察 --keep-new 轮）。
  - 删除是双门槛：连败满 --keep-fails 轮并且无效满 --keep-hours（默认 72 小时＝3 天）。
    只看轮数的话观察期会跟着定时频率变（每 6 小时一轮是 18 小时，改成每小时一轮就只有 3 小时），
    时长这一层才把「至少给 3 天机会」固定下来；--keep-hours 0 退回只看轮数。
  - 本机全断网时 0 个节点测通，脚本直接放弃本轮写入，不会把好配置清空。
  - 通过率相对上一轮骤降时判定为本机出网不稳，本轮失败不记连败、不淘汰。
  - 某个订阅源整轮没拉到时，它的老节点原样保留、不计失败；所有源都拉到、且该节点也已无效满 --keep-hours，才算下架删除。
  - standalone 的节点直接内联在生成的 profile 里，头部的端口/DNS/TUN 走脚本模板；
    分流规则是国内直连（域名 + IP 两层），其余才走节点，所以国内网站不依赖节点可用性。
  - inject 模式只改动 marker 区块和 provider 文件，配置其余内容（含你自己的分流规则）原样保留，
    且托管组不会接管任何分流规则，需在客户端里选用，或自行把规则指向它。
  - 测活需要本机能够直连节点服务器；从中国大陆网络跑时结果会偏严。
EOF
}

# --- 定时任务（launchd）------------------------------------------------------
# 选 launchd 而不是 cron：到点如果机器在睡眠，唤醒后 launchd 会补跑一次，cron 直接跳过。
# plist 由脚本自己生成，这样能写进当前脚本的绝对路径，改名或挪位置后重装即可。
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCHEDULE_PLIST="$HOME/Library/LaunchAgents/$SCHEDULE_LABEL.plist"
SCHEDULE_LEGACY_PLIST="$HOME/Library/LaunchAgents/$SCHEDULE_LEGACY_LABEL.plist"

schedule_check_hours() {
    [[ "$SCHEDULE_HOURS" =~ ^[1-9][0-9]*$ && $((24 % SCHEDULE_HOURS)) -eq 0 ]] \
        || die "--schedule-hours 必须能整除 24（1/2/3/4/6/8/12/24），当前: $SCHEDULE_HOURS"
}

# 每天从凌晨 1 点半开始按间隔排，间隔能整除 24 所以相位不会天天漂移
schedule_times() {
    local h=1 out=""
    while [[ $h -lt 24 ]]; do
        out+="$h:30 "
        h=$((h + SCHEDULE_HOURS))
    done
    echo "${out% }"
}

schedule_write_plist() {
    local out="$1" h
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        echo "  <key>Label</key><string>${SCHEDULE_LABEL}</string>"
        echo '  <key>ProgramArguments</key>'
        echo '  <array>'
        echo '    <string>/bin/bash</string>'
        echo "    <string>${SELF_PATH}</string>"
        # 定时跑同步完配置后主动重载内核。Verge 的激活 profile 已由 apply_changes 同步，
        # reload_client 会 PUT /configs 指向激活 profile；不重载的话内核还在读旧 runtime 配置
        echo '    <string>--reload</string>'
        echo '  </array>'
        echo '  <key>EnvironmentVariables</key>'
        echo '  <dict>'
        # launchd 不会 source ~/.zshrc：PATH 少了 /usr/local/bin 就找不到 python3 和 mihomo 内核
        echo '    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>'
        echo '    <key>LANG</key><string>en_US.UTF-8</string>'
        # 订阅源在境外，必须经本机代理客户端才能拉到。客户端没在跑时本轮拉取会失败，
        # 脚本自己放弃写入，上一份配置原样保留，不会把好配置清空
        echo "    <key>HTTP_PROXY</key><string>http://127.0.0.1:${MIXED_PORT}</string>"
        echo "    <key>HTTPS_PROXY</key><string>http://127.0.0.1:${MIXED_PORT}</string>"
        # 定时跑时日志函数给每行加绝对时间戳（同一文件跨轮追加，没有时间戳分不清是哪一轮）
        echo '    <key>PROXY_NODES_SCHEDULE_LOG</key><string>1</string>'
        echo '  </dict>'
        echo '  <key>StartCalendarInterval</key>'
        echo '  <array>'
        h=1
        while [[ $h -lt 24 ]]; do
            echo "    <dict><key>Hour</key><integer>${h}</integer><key>Minute</key><integer>30</integer></dict>"
            h=$((h + SCHEDULE_HOURS))
        done
        echo '  </array>'
        # 输出全丢 /dev/null 的旧做法让定时任务失败后只剩一个退出码，没法定位。
        # 现在落到固定文件，--schedule-status 直接告诉你去哪看、最新一轮是什么
        echo "  <key>StandardOutPath</key><string>${SCHEDULE_LOG}</string>"
        echo "  <key>StandardErrorPath</key><string>${SCHEDULE_LOG}</string>"
        echo '</dict>'
        echo '</plist>'
    } > "$out"
}

# 卸载某个 label（没装过也当成功），可选同时删它的 plist
schedule_bootout() {
    local label="$1" plist="${2:-}"
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || die "取消 ${label} 失败"
        info "已卸载 launchd 任务: $label"
    fi
    if [[ -n "$plist" && -f "$plist" ]]; then
        rm -f "$plist"
        info "已删除: ${plist#"$HOME"/}"
    fi
    return 0
}

schedule_install() {
    schedule_check_hours
    [[ -d "$HOME/Library/LaunchAgents" ]] || mkdir -p "$HOME/Library/LaunchAgents"
    # 日志落盘，目录要先建好（launchd 不会替你建，不存在就静默收不到输出）
    mkdir -p "$(dirname "$SCHEDULE_LOG")" || warn "创建日志目录失败: $(dirname "$SCHEDULE_LOG")"
    # 改名前用旧 label 装过的先清掉，否则同一个脚本会被两份任务错开时间各跑一遍
    if [[ -f "$SCHEDULE_LEGACY_PLIST" ]]; then
        info "检测到旧版定时任务，一并迁移"
        schedule_bootout "$SCHEDULE_LEGACY_LABEL" "$SCHEDULE_LEGACY_PLIST"
    fi
    schedule_bootout "$SCHEDULE_LABEL"            # 重复安装：先卸旧的，路径改了才生效
    schedule_write_plist "$SCHEDULE_PLIST.tmp"
    plutil -lint "$SCHEDULE_PLIST.tmp" >/dev/null 2>&1 || {
        rm -f "$SCHEDULE_PLIST.tmp"; die "生成的 plist 不合法，未安装"
    }
    mv "$SCHEDULE_PLIST.tmp" "$SCHEDULE_PLIST"
    launchctl bootstrap "gui/$(id -u)" "$SCHEDULE_PLIST" 2>/dev/null \
        || die "launchctl bootstrap 失败，可用 launchctl print gui/$(id -u) 排查"
    launchctl enable "gui/$(id -u)/$SCHEDULE_LABEL" 2>/dev/null || true
    success "已安装定时任务: $SCHEDULE_LABEL"
    info "脚本: $SELF_PATH"
    info "每 ${SCHEDULE_HOURS} 小时一次（$(schedule_times)），睡眠错过会在唤醒后补跑"
    info "日志: ${SCHEDULE_LOG#"$HOME"/}（--schedule-status 会直接显示最近一轮的尾部）"
    info "定时任务里不会提示重载，跑完请在客户端里重新点一次该配置"
}

schedule_remove() {
    schedule_bootout "$SCHEDULE_LABEL" "$SCHEDULE_PLIST"
    [[ -f "$SCHEDULE_LEGACY_PLIST" ]] && schedule_bootout "$SCHEDULE_LEGACY_LABEL" "$SCHEDULE_LEGACY_PLIST"
    success "定时任务已取消"
}

schedule_status() {
    if launchctl print "gui/$(id -u)/$SCHEDULE_LABEL" >/dev/null 2>&1; then
        success "已安装: $SCHEDULE_LABEL"
    else
        info "未安装（用 --install-schedule 设置，默认每 ${SCHEDULE_HOURS} 小时）"
    fi
    [[ -f "$SCHEDULE_LEGACY_PLIST" ]] && warn "旧版任务 plist 还在: ${SCHEDULE_LEGACY_PLIST#"$HOME"/}"
    if [[ -f "$SCHEDULE_PLIST" ]]; then
        local planned
        planned=$(sed -n 's|.*<string>\(/[^<]*update-proxy-nodes.sh\)</string>.*|\1|p' "$SCHEDULE_PLIST" | head -n 1)
        if [[ -n "$planned" && "$planned" != "$SELF_PATH" ]]; then
            warn "已安装的 plist 还指向旧路径: $planned"
            warn "重新执行 --install-schedule 即可更新"
        fi
        info "计划时间: $(schedule_times)（间隔 ${SCHEDULE_HOURS} 小时）"
    fi
    # 定时任务的退出码只能告诉你「挂了」，得给最近一轮的实际输出才能定位
    schedule_show_last_run
}

# 显示定时任务最近一轮的收尾输出。launchd 本身不记退出码以外的东西，
# 全靠脚本自己把日志写进 SCHEDULE_LOG。
schedule_show_last_run() {
    local log="$SCHEDULE_LOG" mtime tail_text line
    if [[ ! -f "$log" ]]; then
        info "日志: ${log#"$HOME"/}（还没有任何一轮跑过，或 plist 还没重装成新版）"
        return 0
    fi
    mtime=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$log" 2>/dev/null || echo '?')
    # 变量名后紧跟中文全角标点时，bash 会把 UTF-8 字节当成变量名的延续字节，
    # 于是报「未绑定的变量」——所以必须用 ${mtime} 花括号界定
    info "日志: ${log#"$HOME"/}（最后写入 ${mtime}，$(wc -l <"$log" 2>/dev/null | tr -d ' ') 行）"
    # 只看尾部几行通常就够判断这一轮成没成；完整过程直接翻日志文件。
    # 日志里混着生成的 YAML 预览（缩进的空格开头），所以按时间戳前缀只留日志行，
    # 否则尾部全被配置内容占掉，看不到成败。
    # 注意：循环用的变量必须和装文本的变量分开 —— 循环一跑就把文本清成最后一行
    tail_text=$(grep -E '^[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$log" 2>/dev/null \
        | tail -n 10 | sed -e 's/^[[:space:]]*//' -e 's/\x1b\[[0-9;]*m//g')
    [[ -z "$tail_text" ]] && return 0
    while IFS= read -r line; do
        info "  $line"
    done <<< "$tail_text"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)         CONFIG_FILE="$2"; shift 2 ;;
        --client)         CLIENT="$2"; shift 2 ;;
        --group)          GROUP_NAME="$2"; shift 2 ;;
        --select-group)   SELECT_GROUP="$2"; shift 2 ;;
        --provider-name)  PROVIDER_NAME="$2"; shift 2 ;;
        --standalone)     MODE=standalone; shift ;;
        --inject)         MODE=inject; shift ;;
        --source)         SOURCES+=("$2"); shift 2 ;;
        --integrate-local) INTEGRATE_LOCAL=1; shift ;;
        --openai-test-url) OPENAI_TEST_URL="$2"; shift 2 ;;
        --max-nodes)      MAX_NODES="$2"; shift 2 ;;
        --min-nodes)      MIN_NODES="$2"; shift 2 ;;
        --test-url)       TEST_URL="$2"; shift 2 ;;
        --timeout)        TEST_TIMEOUT="$2"; shift 2 ;;
        --concurrency)    CONCURRENCY="$2"; shift 2 ;;
        --health-url)     HEALTH_URL="$2"; shift 2 ;;
        --core)           MIHOMO_BIN="$2"; shift 2 ;;
        --extra-direct)   EXTRA_DIRECT+=("$2"); shift 2 ;;
        --extra-proxy)    EXTRA_PROXY+=("$2"); shift 2 ;;
        --proxy-only)     PROXY_ONLY=1; shift ;;
        --per-country)    PER_COUNTRY="$2"; shift 2 ;;
        --prefer)         PREFER="$2"; shift 2 ;;
        --api)            CLASH_API="$2"; shift 2 ;;
        --bundle-id)      BUNDLE_ID="$2"; shift 2 ;;
        --keep-backups)   KEEP_BACKUPS="$2"; shift 2 ;;
        --provider-interval) PROVIDER_INTERVAL="$2"; shift 2 ;;
        --install-schedule)  SCHEDULE_ACTION="install"; shift ;;
        --remove-schedule)   SCHEDULE_ACTION="remove"; shift ;;
        --uninstall-schedule) SCHEDULE_ACTION="remove"; shift ;;
        --schedule-status)   SCHEDULE_ACTION="status"; shift ;;
        --schedule-hours)    SCHEDULE_HOURS="$2"; shift 2 ;;
        --set-default)    SET_DEFAULT=1; shift ;;
        --reload)         DO_RELOAD=1; shift ;;
        --test)           DO_TEST=1; shift ;;
        --no-test)        DO_TEST=0; shift ;;
        --keep-fails)     KEEP_FAILS="$2"; shift 2 ;;
        --keep-hours)     KEEP_HOURS="$2"; shift 2 ;;
        --keep-new)       KEEP_NEW="$2"; shift 2 ;;
        --force)          FORCE=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        show_help; exit 0 ;;
        *)                die "未知参数: $1（--help 查看用法）" ;;
    esac
done

# 定时任务只管 plist，不需要内核/python/配置文件，解析完参数就直接办完退出
if [[ -n "$SCHEDULE_ACTION" ]]; then
    case "$SCHEDULE_ACTION" in
        install) schedule_install ;;
        remove)  schedule_remove ;;
        status)  schedule_status ;;
        *)       die "内部错误: 未知的定时任务动作 $SCHEDULE_ACTION" ;;
    esac
    exit 0
fi

[[ "$MODE" == standalone || "$MODE" == inject ]] || die "未知模式: ${MODE}（只支持 standalone / inject）"

# 客户端相关的目录和 API 端口；只会有一个客户端在跑，auto 按下面的顺序取第一个存在的
CLIENT_DIR=""; CLIENT_API=""; CLIENT_SOCK=""; CLIENT_NAME=""
client_target() {
    case "$1" in
        meta)   CLIENT_DIR="$HOME/.config/clash.meta"
                CLIENT_API="http://127.0.0.1:9090"; CLIENT_SOCK=""; CLIENT_NAME="ClashX Meta" ;;
        verge)
                if [[ "$(uname -s)" == "Darwin" ]]; then
                    CLIENT_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
                    CLIENT_SOCK="/tmp/verge/verge-mihomo.sock"
                else
                    local cand
                    CLIENT_DIR=""
                    for cand in \
                        "$HOME/.local/share/io.github.clash-verge-rev.clash-verge-rev" \
                        "$HOME/.local/share/clash-verge" \
                        "$HOME/.config/clash-verge" \
                        "$HOME/.config/io.github.clash-verge-rev.clash-verge-rev"; do
                        [[ -d "$cand" ]] && { CLIENT_DIR="$cand"; break; }
                    done
                    [[ -n "$CLIENT_DIR" ]] || CLIENT_DIR="$HOME/.local/share/io.github.clash-verge-rev.clash-verge-rev"
                    CLIENT_SOCK="$CLIENT_DIR/verge-mihomo.sock"
                fi
                CLIENT_API="http://127.0.0.1:9097"; CLIENT_NAME="Clash Verge Rev" ;;
        mihomo) CLIENT_DIR="$HOME/.config/mihomo"
                CLIENT_API="http://127.0.0.1:9090"; CLIENT_SOCK=""; CLIENT_NAME="mihomo" ;;
        *)      return 1 ;;
    esac
    return 0
}

# 判断某个客户端当前是否在跑。auto 探测用它挑「正在用的那个」，
# 而不是「目录存在的那几个里排第一的」。
client_is_running() {
    case "$1" in
        meta)   pgrep -f "ClashX Meta" >/dev/null 2>&1 || pgrep -f "com.metacubex.ClashX" >/dev/null 2>&1 ;;
        verge)  pgrep -f "verge-mihomo|Clash Verge\.app" >/dev/null 2>&1 ;;
        mihomo) pgrep -x "mihomo" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

if [[ "$CLIENT" == auto ]]; then
    # 探测不能只看「目录在不在」：ClashX Meta 和 Clash Verge 可以同时装好，
    # 目录都在，按 meta 优先取第一个就永远写进 clash.meta/free-nodes.yaml，
    # 而实际在跑的是 Clash Verge，它读的是自己 profiles/ 下的那份副本 ——
    # 定时刷新就一直在更新一个没人读的文件。
    # 所以先认「正在运行的」，跑起来的那个才是当前客户端。
    for probe in meta verge mihomo; do
        client_target "$probe"
        [[ -d "$CLIENT_DIR" ]] || continue
        if client_is_running "$probe"; then
            CLIENT="$probe"
            break
        fi
    done
    # 没有客户端在跑时退回旧行为：按 meta > verge > mihomo 找第一个存在的
    if [[ "$CLIENT" == auto ]]; then
        for probe in meta verge mihomo; do
            client_target "$probe"
            [[ -d "$CLIENT_DIR" ]] || continue
            CLIENT="$probe"
            break
        done
    fi
    [[ "$CLIENT" != auto ]] || die "没找到 mihomo 系客户端的配置目录，请用 --client 或 --config 指定"
    [[ "$CLIENT" == meta || "$CLIENT" == verge ]] && \
        info "客户端: ${CLIENT_NAME}（${CLIENT_DIR}）"
else
    client_target "$CLIENT" || die "未知客户端: ${CLIENT}（支持 meta / verge / mihomo / auto）"
fi
[[ -n "$CLASH_API" ]] || CLASH_API="$CLIENT_API"

if [[ -z "$CONFIG_FILE" ]]; then
    if [[ "$MODE" == standalone ]]; then
        CONFIG_FILE="$CLIENT_DIR/free-nodes.yaml"
    else
        CONFIG_FILE="$CLIENT_DIR/yuanhang.yaml"
    fi
fi

[[ ${#SOURCES[@]} -gt 0 ]] || SOURCES=("${DEFAULT_SOURCES[@]}")
for v in TEST_TIMEOUT CONCURRENCY KEEP_BACKUPS PROVIDER_INTERVAL KEEP_FAILS KEEP_NEW; do
    [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "$v 必须是正整数，当前: ${!v}"
done
[[ "$MAX_NODES" =~ ^[0-9]+$ ]] || die "MAX_NODES 必须是非负整数（0 为不限），当前: ${MAX_NODES}"
# 时长门槛允许 0（=只看轮数），所以不进上面那个正整数循环
[[ "$KEEP_HOURS" =~ ^[0-9]+$ ]] || die "KEEP_HOURS 必须是非负整数（0 为只看轮数），当前: ${KEEP_HOURS}"
[[ "$MIN_NODES" =~ ^[0-9]+$ ]] || die "MIN_NODES 必须是非负整数，当前: ${MIN_NODES}"
[[ "$MAX_NODES" == 0 || "$MIN_NODES" -le "$MAX_NODES" ]] || die "--min-nodes 不能大于 --max-nodes"
# 域名例外只维护一份：~/.net_proxy/no_proxy 既被 net_proxy.sh 并进 NO_PROXY（管命令行工具），
# 也被这里并进分流规则的 DOMAIN-SUFFIX,...,DIRECT（管走系统代理的 GUI）。少了后半段，
# 「国内但没被 GEOSITE 认出来」的域名（qoder.sh、deepseek.com 这类）就会绕道节点。
# 定时任务跑的是默认参数，所以必须在这里读文件，不能只靠 --extra-direct 传参
load_domain_file() {
    local f="$1" line
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [[ -z "$line" ]] && continue
        # 网段（192.168.0.0/16）和 IPv6 不是域名后缀，本机名已被 GEOSITE,private 兜住
        [[ "$line" == *[/:]* ]] && continue
        [[ "$line" == "localhost" || "$line" == ".local" ]] && continue
        printf '%s\n' "${line#.}"
    done < "$f"
}
while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    case " ${EXTRA_DIRECT[*]-} " in *" $d "*) continue ;; esac
    EXTRA_DIRECT+=("$d")
done < <(load_domain_file "$NO_PROXY_FILE")
if [[ ${#EXTRA_DIRECT[@]} -gt 0 ]]; then
    info "直连例外: ${#EXTRA_DIRECT[@]} 条域名后缀（含 ${NO_PROXY_FILE}）"
fi
while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    case " ${EXTRA_PROXY[*]-} " in *" $d "*) continue ;; esac
    EXTRA_PROXY+=("$d")
done < <(load_domain_file "$PROXY_FILE")
if [[ ${#EXTRA_PROXY[@]} -gt 0 ]]; then
    info "走代理例外: ${#EXTRA_PROXY[@]} 条域名后缀（含 ${PROXY_FILE}）"
fi
# 域名后缀要能安全拼进规则行，空格和斜杠之类会让分流规则变形
for d in ${EXTRA_DIRECT[@]+"${EXTRA_DIRECT[@]}"} ${EXTRA_PROXY[@]+"${EXTRA_PROXY[@]}"}; do
    [[ "$d" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--extra-direct/--extra-proxy 只能是域名后缀（如 aliyuncs.com），当前: $d"
done
[[ "$PER_COUNTRY" =~ ^[0-9]+$ ]] || die "--per-country 必须是非负整数（0 为不限），当前: $PER_COUNTRY"
PREFER="$(printf '%s' "$PREFER" | tr ',' ' ' | tr '[:lower:]' '[:upper:]')"
for c in $PREFER; do
    [[ "$c" =~ ^[A-Z]{2}$ ]] || die "--prefer 只收 ISO 两位国家码（逗号或空格分隔，如 JP,KR,SG），当前: $c"
done

find_python() {
    local p
    for p in "${PYTHON:-}" python3 /usr/bin/python3 /usr/local/bin/python3; do
        [[ -n "$p" ]] || continue
        command -v "$p" >/dev/null 2>&1 && "$p" -c 'pass' 2>/dev/null && { echo "$p"; return 0; }
    done
    return 1
}

find_core() {
    local c p
    for c in "$MIHOMO_BIN" \
        "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo" \
        "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo-alpha" \
        "$HOME/.local/bin/mihomo" /usr/local/bin/mihomo /opt/homebrew/bin/mihomo \
        /usr/bin/verge-mihomo /usr/bin/verge-mihomo-alpha /usr/bin/mihomo; do
        [[ -n "$c" && -f "$c" && -x "$c" ]] && { echo "$c"; return 0; }
    done
    # -x 对目录也成立（本仓库里就有个 network/mihomo/），命令名必须走 PATH 查绝对路径再判
    for c in mihomo verge-mihomo clash; do
        p="$(command -v "$c" 2>/dev/null || true)"
        [[ -n "$p" && -f "$p" && -x "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

PY="$(find_python || true)"
[[ -n "$PY" ]] || die "找不到可用的 python3"
CORE="$(find_core || true)"
if [[ -z "$CORE" ]]; then
    if [[ "$DO_TEST" == 1 ]]; then
        die "找不到 mihomo 内核：测活和配置校验都需要它，可用 --core 指定路径，或加 --no-test"
    fi
    warn "未找到 mihomo 内核，跳过配置校验"
fi

WORK="$(mktemp -d)"
PROBE_PID=""
cleanup() {
    [[ -n "$PROBE_PID" ]] && kill "$PROBE_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" 2>/dev/null && pwd || true)"
[[ -n "$CONFIG_DIR" && -d "$CONFIG_DIR" ]] || die "配置目录不存在: $(dirname "$CONFIG_FILE")"
CONFIG_BASE="$(basename "$CONFIG_FILE" .yaml)"
# 跨轮次的节点履历（连续失败次数、最后成功时间），用来区分「暂时挂了」和「彻底死了」
STATE_FILE="$CONFIG_DIR/$CONFIG_BASE.state.json"
PROVIDER_FILE=""
PROVIDER_RELPATH=""
if [[ "$MODE" == inject ]]; then
    [[ -f "$CONFIG_FILE" ]] || die "配置文件不存在: $CONFIG_FILE"
    PROVIDER_FILE="$CONFIG_DIR/$CONFIG_BASE.$PROVIDER_NAME.yaml"
    PROVIDER_RELPATH="$(basename "$PROVIDER_FILE")"
elif [[ -f "$CONFIG_FILE" && "$FORCE" != 1 ]]; then
    # 新旧标记都认：改名之前生成的那份也是本脚本产的，不该逼用户加 --force
    grep -qE "^# (proxy-nodes|clash-meta)-refresh:standalone" "$CONFIG_FILE" \
        || die "目标文件不是本脚本生成的，拒绝整份覆盖: ${CONFIG_FILE}（确认无误可用 --force）"
fi

if [[ -z "$TEST_URL" && "$MODE" == inject && -f "$CONFIG_FILE" ]]; then
    # 只有 inject 沿用宿主配置的 test-url。standalone 下这个文件就是我们自己写的，
    # 再去读等于让上一轮的地址永久生效（曾经因此一直用 cp.cloudflare.com，
    # 把只能到国内出口的节点判成测通）
    # 不用 heredoc：/bin/bash 3.2 解析不了 $() 里套 heredoc，而 launchd 跑的就是 3.2
    TEST_URL=$(sed -n 's/^[[:space:]]*test-url:[[:space:]]*//p' "$CONFIG_FILE" | head -n 1 | tr -d '\"\047 \t\r')
fi
# 入选测活（TEST_URL）与 url-test 运行时探测（HEALTH_URL）必须分开：
# - standalone 入选用 google 过滤（只有真能上 Google/OpenAI 的节点才进菜单），
#   不能跟随 HEALTH_URL（Cloudflare）——否则中国出口节点也被判测通（见上方注释）。
# - inject 沿用宿主配置的 test-url 或 HEALTH_URL。
if [[ -z "$TEST_URL" ]]; then
    if [[ "$MODE" == standalone ]]; then
        TEST_URL="${PROXY_NODES_TEST_URL:-https://www.google.com/generate_204}"
    else
        TEST_URL="$HEALTH_URL"
    fi
fi

info "内核: ${CORE:-未找到}"
info "客户端: ${CLIENT_NAME}（${CLIENT}）"
info "模式: $MODE"
info "目标配置: $CONFIG_FILE"
if [[ "$MODE" == inject ]]; then
    info "托管组: $GROUP_NAME   provider: $PROVIDER_NAME -> $PROVIDER_RELPATH"
else
    info "代理组: ${SELECT_GROUP} -> ${GROUP_NAME}（最多 ${MAX_NODES} 个节点，0 为不限）"
    if [[ "$PROXY_ONLY" == 1 ]]; then
        info "分流: 精确白名单模式，只有 --extra-proxy 点名的域名和 github/google/openai 走节点，其余 DIRECT"
    else
        info "分流: 内网和国内直连，其余走节点"
    fi
    info "排序: 同层内亚洲靠前、同国聚拢；每国最多 ${PER_COUNTRY} 个${PREFER:+，优先 ${PREFER}}"
fi
if [[ "$DO_TEST" == 1 ]]; then
    info "测活: 每个节点真实握手（并发 ${CONCURRENCY}，超时 ${TEST_TIMEOUT}ms），测活地址 $TEST_URL"
    info "增删: 通过就写入；连续不通未满 ${KEEP_FAILS} 轮、或失效未满 ${KEEP_HOURS} 小时的按「暂时挂了」保留，"
    info "      从没用过的按「新面孔」保留 ${KEEP_NEW} 轮；两个门槛都满或上游下架则删除"
    info "兜底: 本轮通过率相对上一轮骤降时判定为本机出网问题，失败不记连败、不淘汰"
    info "履历: $STATE_FILE"
else
    info "测活: 跳过（--no-test），抽取到的节点全部写入，也不读写履历"
fi

# 订阅源候选地址：raw.githubusercontent.com 经常抖动/被重置，追加两个后备镜像
# jsDelivr 可能返回缓存的旧版本，所以只作最后兜底
candidates_for() {
    local url="$1"
    printf '%s\n' "$url"
    if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$ ]]; then
        printf 'https://gh-proxy.com/%s\n' "$url"
        printf 'https://ghproxy.net/%s\n' "$url"
        printf 'https://cdn.jsdelivr.net/gh/%s/%s@%s/%s\n' \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    fi
}

fetch_one() {
    local url="$1" out="$2" cand try n=0 tries
    while IFS= read -r cand; do
        n=$((n + 1))
        # 只有首选地址值得重试，镜像各试一次即可，否则全挂时要等很久
        tries=1; [[ $n == 1 ]] && tries=2
        for try in $(seq 1 "$tries"); do
            # 失败细节写进日志，终端只留简洁提示，避免直连被重置时的 curl 报错刷屏
            if curl -fsSL --connect-timeout 8 -m 30 "$cand" -o "$out.tmp" </dev/null 2>>"$WORK/fetch.log"; then
                mv "$out.tmp" "$out" && return 0
            fi
            rm -f "$out.tmp"
            if [[ $try -lt "$tries" ]]; then
                sleep 1
            fi
        done
    done
    return 1
}

# --- 1. 下载订阅 -------------------------------------------------------------
fetch_sources() {
    local i=0 url out
    SOURCE_FAILED=0
    : > "$WORK/sources.jsonl"
    for url in "${SOURCES[@]}"; do
        i=$((i + 1)); out="$WORK/src_$i.yaml"
        info "下载订阅 $i/${#SOURCES[@]}: $url"
        if fetch_one "$url" "$out" < <(candidates_for "$url"); then
            printf '%s\t%s\n' "$url" "$out" >> "$WORK/sources.jsonl"
        else
            warn "所有候选地址都失败，跳过: $url"
            SOURCE_FAILED=$((SOURCE_FAILED + 1))
        fi
    done
    [[ -s "$WORK/sources.jsonl" ]] || die "所有订阅源都下载失败"
    if [[ $SOURCE_FAILED -gt 0 ]]; then
        info "有 ${SOURCE_FAILED} 个订阅源本轮没拉到，其节点按履历保留（不计为失败）"
    fi
}

# --- 1b. 整合同目录其他配置（--integrate-local） ------------------------------
# 当订阅源里可用节点太少/全是国内节点时，把同目录其他 Clash 配置（如自建节点 yuanhang）
# 的节点也拉进来一起测活。只有过了 google+OpenAI 检测的才入选，付费锁定的配置
# （XSHIP182/星链）会被 localize() 过滤为国内或直接无法解析，自然进不了最终菜单。
integrate_local_sources() {
    [[ "$INTEGRATE_LOCAL" == 1 ]] || return 0
    local dir="$CONFIG_DIR" base="$CONFIG_BASE" n=0 skip
    [[ -n "$dir" && -d "$dir" ]] || { warn "整合本地配置: 配置目录不存在 $dir"; return 0; }
    info "整合本地配置: 扫描 $dir 下其他配置文件"
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        # 跳过当前生成的配置、备份、状态/履历文件、以及非 Clash 配置
        skip=""
        case "$(basename "$f")" in
            "$base.yaml"|"$base"*".bak"*|"$base"*".state.json"|"$base"*".providers.yaml"|*".state.json"|*.bak*|config.yaml|config.yml)
                skip=1 ;;
        esac
        [[ -n "$skip" ]] && continue
        # 只吃看起来像 Clash 配置的（含 proxies: 或 proxy-providers:）
        if ! grep -qE '^[[:space:]]*(proxies|proxy-providers):' "$f" 2>/dev/null; then
            continue
        fi
        n=$((n + 1))
        local out="$WORK/src_local_$n.yaml"
        cp "$f" "$out" 2>/dev/null || continue
        printf 'local://%s\t%s\n' "$(basename "$f")" "$out" >> "$WORK/sources.jsonl"
        info "  整合: $(basename "$f")"
    done < <(find "$dir" -maxdepth 1 -name '*.yaml' -o -maxdepth 1 -name '*.yml' 2>/dev/null | sort)
    [[ $n -gt 0 ]] && info "已整合 $n 个本地配置文件作为额外测活源" || info "同目录无可整合的配置文件"
}

# --- 2. 抽取 + 去重 ----------------------------------------------------------
extract_nodes() {
    WORK="$WORK" "$PY" - <<'PY' > "$WORK/nodes.jsonl"
import base64, hashlib, json, os, re, urllib.parse

# 只保留加密隧道协议：免费列表里的 http/socks5 是扫来的开放代理，
# 几乎不允许 CONNECT，留着只是白占菜单位置
ALLOWED = {
    'ss', 'shadowsocks', 'ssr', 'vmess', 'vless', 'trojan', 'hysteria', 'hysteria2',
    'anytls', 'snap', 'tuic', 'snell', 'wireguard',
}
work = os.environ['WORK']
sources = [l.rstrip('\n').split('\t', 1) for l in open(os.path.join(work, 'sources.jsonl'), encoding='utf-8') if l.strip()]

def top_level(lines):
    return [i for i, l in enumerate(lines) if re.match(r'^[A-Za-z_][\w-]*:', l)]

def proxy_blocks(text):
    """抽取 proxies: 区块下的每个节点，返回去掉一层缩进的原始 YAML 文本。"""
    lines = text.splitlines()
    tops = top_level(lines)
    found = []
    for i, ln in enumerate(lines):
        if ln.rstrip() == 'proxies:' and i in tops:
            stop = next((k for k in tops if k > i), len(lines))
            cur = None
            item_ind = None
            for sub in lines[i + 1:stop]:
                st = sub.lstrip()
                ind = len(sub) - len(st)
                if st.startswith('- ') or st == '-':
                    # 只有和第一个列表项同缩进的 - 才是新节点。更深的是 alpn/requests
                    # 这类嵌套列表，之前一律当新节点，等于把节点拦腰切断，后半截变成
                    # 没有 key 的孤儿行，整份测活配置直接 Parse config error
                    if item_ind is None:
                        item_ind = ind
                    elif ind > item_ind:
                        if cur:
                            cur.append((ind, st))
                        continue
                    if cur:
                        found.append(cur)
                    cur = [(ind, st[2:] if st.startswith('- ') else '')]
                elif cur and sub.strip():
                    cur.append((ind, st))
            if cur:
                found.append(cur)
    out = []
    for blk in found:
        base = blk[0][0]
        inner = min((ind for ind, _ in blk[1:]), default=base + 2)
        rendered = [blk[0][1]]
        for ind, txt in blk[1:]:
            rendered.append(' ' * max(0, ind - inner) + txt)
        out.append('\n'.join(rendered))
    return out

def field(block, name):
    m = re.search(r'^%s:\s*(.*)$' % name, block, re.M)
    return m.group(1).strip().strip('"\'') if m else ''

def block_body(blk):
    """节点自带的 name 行删掉（本脚本统一改名/去重），连它的多行续行一起删。
    只删首行会把 "name: >-" 的正文留成孤儿行，同样炸掉整份配置。"""
    rows, dropping = [], False
    for row in blk.splitlines():
        if row[:1] != ' ' and re.match(r'^name:', row):
            dropping = True
            continue
        if dropping:
            if row[:1] == ' ' or not row.strip():
                continue
            dropping = False
        rows.append(row)
    return rows

def looks_parseable(rows):
    """兜底结构自检：顶层只能出现 "key: 值" 和跟在空值 key 后面的 "- 项"。
    上游格式再野，最坏只是丢掉这一个节点，不该让一次性内核起不来。"""
    prev = ''
    for i, row in enumerate(rows):
        if not row.strip():
            continue
        if i and row[:1] == ' ':
            continue                       # 缩进的子层，交给内核自己判
        if row.startswith('- ') or row == '-':
            if prev not in ('key', 'list'):
                return False
            prev = 'list'
            continue
        m = re.match(r'^([A-Za-z_][\w.\-]*):(.*)$', row)
        if not m:
            return False
        prev = 'key' if not m.group(2).strip() else 'kv'
    return True


# 上游节点名多以 ISO 国家代码开头（"US - zhuhai.uk"、"us|e623|..."），换成中文好辨认
COUNTRY = {
    'CN': '中国', 'HK': '中国香港', 'MO': '中国澳门', 'TW': '中国台湾',
    'JP': '日本', 'KR': '韩国', 'SG': '新加坡', 'MY': '马来西亚', 'TH': '泰国',
    'VN': '越南', 'PH': '菲律宾', 'ID': '印度尼西亚', 'KH': '柬埔寨', 'MM': '缅甸',
    'LA': '老挝', 'NP': '尼泊尔', 'LK': '斯里兰卡', 'BD': '孟加拉', 'PK': '巴基斯坦',
    'IN': '印度', 'MN': '蒙古', 'KP': '朝鲜', 'BN': '文莱', 'BT': '不丹', 'MV': '马尔代夫',
    'KZ': '哈萨克斯坦', 'UZ': '乌兹别克斯坦', 'GE': '格鲁吉亚',
    'AM': '亚美尼亚', 'AZ': '阿塞拜疆', 'IL': '以色列', 'IR': '伊朗', 'IQ': '伊拉克',
    'LB': '黎巴嫩', 'SY': '叙利亚', 'YE': '也门', 'TR': '土耳其', 'AE': '阿联酋',
    'SA': '沙特', 'QA': '卡塔尔', 'KW': '科威特', 'BH': '巴林', 'OM': '阿曼', 'JO': '约旦',
    'US': '美国', 'CA': '加拿大', 'MX': '墨西哥', 'GT': '危地马拉', 'PA': '巴拿马',
    'CR': '哥斯达黎加', 'DO': '多米尼加', 'CU': '古巴', 'CO': '哥伦比亚', 'VE': '委内瑞拉',
    'BR': '巴西', 'AR': '阿根廷', 'CL': '智利', 'PE': '秘鲁', 'EC': '厄瓜多尔',
    'GB': '英国', 'UK': '英国', 'IE': '爱尔兰', 'NL': '荷兰', 'BE': '比利时', 'LU': '卢森堡',
    'FR': '法国', 'DE': '德国', 'AT': '奥地利', 'CH': '瑞士', 'IT': '意大利', 'ES': '西班牙',
    'PT': '葡萄牙', 'GR': '希腊', 'SE': '瑞典', 'NO': '挪威', 'FI': '芬兰', 'DK': '丹麦',
    'IS': '冰岛', 'PL': '波兰', 'CZ': '捷克', 'SK': '斯洛伐克', 'HU': '匈牙利',
    'RO': '罗马尼亚', 'BG': '保加利亚', 'HR': '克罗地亚', 'RS': '塞尔维亚', 'SI': '斯洛文尼亚',
    'BA': '波黑', 'AL': '阿尔巴尼亚', 'MK': '北马其顿', 'MD': '摩尔多瓦', 'UA': '乌克兰',
    'BY': '白俄罗斯', 'RU': '俄罗斯', 'LV': '拉脱维亚', 'LT': '立陶宛', 'EE': '爱沙尼亚',
    'ME': '黑山', 'XK': '科索沃',
    'MT': '马耳他', 'CY': '塞浦路斯', 'AU': '澳大利亚', 'NZ': '新西兰', 'FJ': '斐济',
    'EG': '埃及', 'ZA': '南非', 'NG': '尼日利亚', 'KE': '肯尼亚', 'ET': '埃塞俄比亚',
    'DZ': '阿尔及利亚', 'MA': '摩洛哥', 'TN': '突尼斯', 'AO': '安哥拉',
    'XX': '未知地区',
}

# 中文名反查 ISO：不少上游的节点名直接就是中文（"意大利-1.2.3.4-0120"），
# 按名字长度倒序比对，避免「中国香港」被「中国」抢先命中
CN_NAME = sorted(((v, k) for k, v in COUNTRY.items() if k != 'XX'), key=lambda kv: -len(kv[0]))

# 国内节点常直接写省市名（"广东省广州市+华为云"、"上海电信CN2"），不带「中国」前缀，
# 单独列一份，命中就认 CN；同样按长度倒序，避免「内蒙」抢在「内蒙古」之前
CN_PLACE = sorted((
    '黑龙江', '内蒙古', '宁夏', '新疆', '广西', '西藏', '香港', '澳门', '台湾',
    '北京', '上海', '天津', '重庆', '广东', '广州', '深圳', '珠海', '东莞', '佛山',
    '江苏', '南京', '苏州', '浙江', '杭州', '宁波', '山东', '青岛', '济南', '河北',
    '河南', '湖北', '武汉', '湖南', '长沙', '山西', '陕西', '西安', '安徽', '福建',
    '厦门', '江西', '辽宁', '大连', '沈阳', '吉林', '成都', '四川', '云南', '昆明',
    '贵州', '贵阳', '海南', '南宁', '柳州', '石家庄', '郑州', '合肥', '福州', '南昌',
    '太原', '兰州', '西宁', '银川', '乌鲁木齐', '呼和浩特', '哈尔滨', '长春',
), key=len, reverse=True)

# 上游很爱用国旗 emoji 打头（"🇯🇵日本 - 东京"、"🇺🇸US-1.2.3.4-0112"），国旗是两个
# 区域指示符拼出来的，减掉码点基址就是 ISO 两位码；这类节点在聚合源里占大头，
# 认不出来就会被排成「未知地区」沉底，菜单里就看不见亚洲节点了
FLAG = re.compile('[\U0001F1E6-\U0001F1FF]{2}')

def flag_iso(name):
    m = FLAG.search(name)
    if not m:
        return ''
    return ''.join(chr(65 + ord(c) - 0x1F1E6) for c in m.group(0))

def localize(name):
    """节点名统一成中文前缀开头，同时尽量给出 ISO 两位码，供后面按国家分组排序。"""
    iso = flag_iso(name)
    if iso in COUNTRY:
        return name, iso            # 带国旗的名字本身已经能看出国家，原文留着更好认
    m = re.match(r'([A-Za-z]{2})(?=[\s\-_|·:：/]|$)', name)
    if m:
        cn = COUNTRY.get(m.group(1).upper())
        if cn:
            return cn + name[m.end():], m.group(1).upper()
    for cn, iso in CN_NAME:
        if name.startswith(cn):
            return name, iso
    for place in CN_PLACE:
        if name.startswith(place):
            return name, 'CN'
    return name, 'XX'

def yq(val):
    """链接里的值可能有中文、冒号、井号，统一加引号；纯数字保持裸值以适配 int 字段。"""
    s = '' if val is None else str(val)
    if re.fullmatch(r'-?\d+', s):
        return s
    return json.dumps(s, ensure_ascii=False)

def norm_net(n):
    return {'websocket': 'ws', 'h2': 'http'}.get(n, n)

def reality_sid(val):
    """REALITY short-id 必须是偶数长度的十六进制串（0-16 位），否则内核直接 fatal。"""
    s = re.sub(r'[^0-9a-fA-F]', '', '' if val is None else str(val))
    if len(s) > 16:
        s = s[:16]
    if len(s) % 2:
        s = s[:-1]
    return s

def sanitize_short_id(block):
    """YAML 订阅里的 reality-opts.short-id 可能非法；清洗后写回，非法为空则删掉该行。"""
    out = []
    for ln in block.splitlines():
        m = re.match(r'^(\s*)short-id:\s*(.*)$', ln)
        if not m:
            out.append(ln)
            continue
        sid = reality_sid(m.group(2).strip().strip('"\''))
        if sid:
            out.append('%sshort-id: %s' % (m.group(1), json.dumps(sid)))
    return '\n'.join(out)

def transport_opts(net, path, host, alpn):
    if net == 'grpc':
        return ['grpc-opts:', '  grpc-service-name: %s' % yq(path)] if path else []
    if net not in ('ws', 'http'):
        return []
    rows = ['ws-opts:' if net == 'ws' else 'h2-opts:']
    if path:
        rows.append('  path: %s' % yq(path))
    headers = []
    if host:
        headers.append('    Host: %s' % yq(host))
    if alpn:
        # ws-opts/h2-opts 的 headers 是 map[string]string，ALPN 只能是逗号拼接的字符串
        headers.append('    ALPN: %s' % yq(alpn))
    if headers:
        rows.append('  headers:')
        rows += headers
    return rows if len(rows) > 1 else []

def unpad(s):
    return s + '=' * (-len(s) % 4)


def b64(s):
    try:
        return base64.b64decode(unpad(s)).decode('utf-8', 'replace')
    except Exception:
        return ''


def parse_link(line):
    """把 ss:// vmess:// vless:// trojan:// hysteria2:// 等链接转成 Clash 节点字段。"""
    m = re.match(r'^([A-Za-z0-9+.-]+)://(.+)$', line.strip())
    if not m:
        return None
    scheme, rest = m.group(1).lower(), m.group(2).strip()
    name = ''
    if '#' in rest:
        rest, frag = rest.split('#', 1)
        name = urllib.parse.unquote(frag).strip()
    params = {}
    if '?' in rest:
        rest, qs = rest.split('?', 1)
        params = {k.lower(): v[0] for k, v in urllib.parse.parse_qs(qs, keep_blank_values=False).items()}
    if not params:
        qs = re.search(r'[?&]([A-Za-z0-9_]+=[^&]+)', rest)
        if qs:
            params = {k.lower(): v[0] for k, v in urllib.parse.parse_qs(qs.group(0)[1:], keep_blank_values=False).items()}
            rest = rest.split('?' + qs.group(0)[1:], 1)[0].rstrip('?&')
    if scheme not in ('ss', 'shadowsocks', 'u2', 'vmess', 'vless', 'trojan', 'hysteria', 'hysteria2', 'anytls', 'tuic'):
        return None
    if scheme == 'vmess':
        try:
            cfg = json.loads(b64(rest))
        except Exception:
            return None
        host, port = str(cfg.get('add') or ''), str(cfg.get('port') or '')
        net = norm_net(str(cfg.get('net') or 'tcp').lower())
        rows = ['type: vmess', 'uuid: %s' % cfg.get('id'),
                'alterId: %d' % int(cfg.get('aid') or 0), 'cipher: %s' % (cfg.get('scy') or 'auto'),
                'server: %s' % yq(host), 'port: %s' % yq(port)]
        if net != 'tcp':
            rows.append('network: %s' % yq(net))
        rows += transport_opts(net, cfg.get('path'), cfg.get('host'), cfg.get('alpn'))
        if str(cfg.get('tls') or '').lower() in ('tls', 'true'):
            rows.append('tls: true')
            rows.append('servername: %s' % yq(cfg.get('sni') or cfg.get('host') or host))
        rows.append('udp: true')
        return name or str(cfg.get('ps') or ''), 'vmess', host, port, rows
    if '@' in rest:
        cred, ep = rest.rsplit('@', 1)
    else:
        dec = b64(rest)
        if '@' not in dec:
            return None
        cred, ep = dec.rsplit('@', 1)
    if not re.fullmatch(r'\S+:\d{1,5}', ep):
        return None
    host, port = ep.rsplit(':', 1)
    ntype = {'shadowsocks': 'ss', 'u2': 'ss', 'hysteria': 'hysteria2'}.get(scheme, scheme)
    if ntype == 'ss':
        method, password = (cred.split(':', 1) if ':' in cred else b64(cred).split(':', 1))
        if not method or not password:
            return None
        rows = ['type: ss', 'server: %s' % yq(host), 'port: %s' % yq(port),
                'cipher: %s' % yq(method.lower()), 'password: %s' % yq(password)]
        plugin = params.get('plugin') or ''
        if plugin.startswith('obfs-local'):
            opts = dict(p.split('=', 1) for p in plugin.split(';')[1:] if '=' in p)
            rows += ['plugin: obfs', 'plugin-opts:', '  mode: %s' % yq(opts.get('obfs', 'http'))]
            if opts.get('obfs-host'):
                rows.append('  host: %s' % yq(opts['obfs-host']))
        return name, ntype, host, port, rows
    rows = ['type: %s' % ntype, 'server: %s' % yq(host), 'port: %s' % yq(port)]
    net = norm_net((params.get('type') or params.get('network') or 'tcp').lower())
    if ntype == 'vless':
        rows.append('uuid: %s' % yq(cred))
        rows.append('encryption: %s' % yq(params.get('encryption') or 'none'))
        flow = params.get('flow')
        if flow:
            rows.append('flow: %s' % yq(flow))
        sec = (params.get('security') or 'none').lower()
        if sec in ('tls', 'reality'):
            rows.append('tls: true')
        if sec == 'reality':
            rows.append('client-fingerprint: %s' % yq(params.get('fp') or 'chrome'))
            rows.append('reality-opts:')
            rows.append('  public-key: %s' % yq(params.get('pbk') or params.get('publickey') or ''))
            sid = reality_sid(params.get('sid') or params.get('shortid') or '')
            if sid:
                rows.append('  short-id: %s' % json.dumps(sid))
    elif ntype == 'tuic':
        uuid, _, password = cred.partition(':')
        rows += ['uuid: %s' % yq(uuid), 'password: %s' % yq(password)]
    else:
        rows.append('password: %s' % yq(cred))
    if ntype in ('hysteria2', 'anytls'):
        updown = lambda k: ('%s Mbps' % params[k]) if params.get(k, '').isdigit() else None
        for key in ('up', 'down'):
            val = updown(key)
            if val:
                rows.append('%s: %s' % (key, yq(val)))
    if ntype == 'hysteria2' and params.get('obfs'):
        rows += ['obfs: %s' % yq(params['obfs']), 'obfs-password: %s' % yq(params.get('obfs-password') or params.get('obfs-passwd') or '')]
    if net != 'tcp':
        rows.append('network: %s' % yq(net))
    rows += transport_opts(net, params.get('path'), params.get('host'), params.get('alpn'))
    sni = params.get('sni') or params.get('peer')
    if sni:
        rows.append('servername: %s' % yq(sni))
    insecure = any(params.get(k) in ('1', 'true') for k in ('insecure', 'allowinsecure', 'allow_insecure'))
    if insecure and ntype != 'ss':
        rows.append('skip-cert-verify: true')
    rows.append('udp: true')
    return name, ntype, host, port, rows


def link_lines(text):
    """链接型订阅：先按行找 scheme://，整份 base64 的也解开再找。"""
    lines = [l.strip() for l in re.split(r'[\r\n]+', text) if l.strip()]
    links = [l for l in lines if re.match(r'^[A-Za-z0-9+.-]+://', l)]
    if links or 'proxies:' in text:
        return links
    blob = ''.join(lines)
    if len(blob) > 64 and re.fullmatch(r'[A-Za-z0-9+/=_-]+', blob):
        links = [l.strip() for l in b64(blob).splitlines()
                 if re.match(r'^[A-Za-z0-9+.-]+://', l.strip())]
    return links

seen_ep, used_names, nodes = set(), set(), []
skip = {'no-name': 0, 'bad-type': 0, 'bad-endpoint': 0, 'bad-link': 0, 'bad-block': 0, 'dup': 0}

def add(raw_name, ntype, server, port, block):
    """YAML 区块和链接转换结果都汇到这里：校验、去重、统一改名。"""
    block = sanitize_short_id(block)
    name, cc = localize(raw_name)
    name = name.strip()
    ntype = ntype.lower()
    if not name:
        skip['no-name'] += 1; return
    if ntype not in ALLOWED:
        skip['bad-type'] += 1; return
    if not re.fullmatch(r'\d+', port) or not (1 <= int(port) <= 65535) or \
       not re.fullmatch(r'[A-Za-z0-9_.\-:@\[\]]+', server):
        skip['bad-endpoint'] += 1; return
    # CDN 上同一个 IP:443 常挂着多个 SNI/路径完全不同的节点，去重键要带上它们
    sni = re.search(r'^servername:\s*(.+)$', block, re.M)
    pth = re.search(r'^\s*path:\s*(.+)$', block, re.M)
    ep = (ntype, server.lower(), port, sni.group(1).strip('"\'').lower() if sni else '',
          pth.group(1).strip('"\'') if pth else '')
    if ep in seen_ep:
        skip['dup'] += 1; return
    seen_ep.add(ep)
    base, k = name, 2
    while name in used_names:
        name = f'{base} ({k})'
        k += 1
    used_names.add(name)
    fp = hashlib.sha1('|'.join(ep).encode('utf-8')).hexdigest()[:12]
    nodes.append({'name': name, 'type': ntype, 'server': server, 'port': port, 'fp': fp,
                  'cc': cc, 'block': block, 'source': url})

for url, path in sources:
    try:
        text = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    for blk in proxy_blocks(text):
        rows = block_body(blk)               # 顺带删掉节点自带的 name 行
        if not looks_parseable(rows):
            skip['bad-block'] += 1
            continue
        add(field(blk, 'name'), field(blk, 'type'), field(blk, 'server'), field(blk, 'port'),
            '\n'.join(rows))
    for ln in link_lines(text):
        parsed = parse_link(ln)
        if not parsed:
            skip['bad-link'] += 1
            continue
        lname, ntype, host, port, rows = parsed
        add(lname or f'{ntype.upper()} {host}', ntype, host, port, '\n'.join(rows))

json.dump({'skipped': skip, 'total': len(nodes)},
          open(os.path.join(work, 'nodes.stats.json'), 'w'))
for nd in nodes:
    print(json.dumps(nd, ensure_ascii=False))
PY
    local total stats
    total=$(wc -l < "$WORK/nodes.jsonl" | tr -d ' ')
    stats=$("$PY" -c "import json;d=json.load(open('$WORK/nodes.stats.json'))['skipped'];print(', '.join(f'{k} {v}' for k,v in d.items() if v))")
    success "抽取到 $total 个节点"
    [[ -n "$stats" ]] && info "已丢弃: $stats"
    [[ "$total" -gt 0 ]] || die "没有可注入的节点"
}

pick_port() {
    "$PY" -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# 访问本机 API（测活内核 / 客户端）必须直连：走了 http_proxy 会被 7890 那个死代理吃掉，
# 表现为"内核启动超时"这种假故障。用环境变量比 --noproxy '*' 好写，bash 3.2 也不会解析错
curl_local() {
    NO_PROXY='*' no_proxy='*' curl "$@"
}
# --- 3. 隔离内核测活 ---------------------------------------------------------
probe_nodes() {
    local probe_dir="$WORK/probe"
    mkdir -p "$probe_dir"
    local mp ec
    mp="$(pick_port)"; ec="$(pick_port)"

    WORK="$WORK" MP="$mp" EC="$ec" "$PY" - <<'PY'
import json, os
work = os.environ['WORK']
nodes = [json.loads(l) for l in open(os.path.join(work, 'nodes.jsonl'), encoding='utf-8') if l.strip()]
alias_map = {}
lines = ['mixed-port: ' + os.environ['MP'],
         'external-controller: 127.0.0.1:' + os.environ['EC'],
         'allow-lan: false', 'mode: rule', 'log-level: silent',
         'profile:', '  store-selected: false', 'proxies:']
for i, n in enumerate(nodes, 1):
    alias = f'p{i:03d}'
    alias_map[alias] = n['name']
    lines.append(f'  - name: "{alias}"')
    for extra in n['block'].splitlines():
        lines.append('    ' + extra)
lines += ['proxy-groups:', '  - name: ALL', '    type: select', '    proxies:']
lines += [f'      - "{a}"' for a in alias_map]
lines += ['rules:', '  - MATCH,ALL']
json.dump(alias_map, open(os.path.join(work, 'nodes.alias.json'), 'w'), ensure_ascii=False)
open(os.path.join(work, 'probe', 'config.yaml'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PY

    info "启动一次性内核测活（代理端口 ${mp}，API ${ec}，不影响已在运行的客户端）"
    ( cd "$probe_dir" && exec "$CORE" -d "$probe_dir" -f "$probe_dir/config.yaml" ) >"$WORK/probe.log" 2>&1 &
    PROBE_PID=$!
    local waited=0
    until curl_local -fsS -m 2 "http://127.0.0.1:$ec/version" >/dev/null 2>&1; do
        kill -0 "$PROBE_PID" 2>/dev/null || die "测活内核启动失败: $(tr '\n' ' ' < "$WORK/probe.log" | tail -c 300)"
        sleep 0.5
        waited=$((waited + 1))
        [[ $waited -gt 60 ]] && die "测活内核启动超时"
    done

    local enc_url enc_openai a pids=() google_ok
    enc_url=$("$PY" -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$TEST_URL")
    local do_openai=0
    [[ -n "$OPENAI_TEST_URL" ]] && do_openai=1
    local enc_openai_url=""
    [[ $do_openai -eq 1 ]] && enc_openai_url=$("$PY" -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$OPENAI_TEST_URL")
    : > "$WORK/raw_delays.tsv"
    : > "$WORK/raw_openai.tsv"
    for a in $("$PY" -c "import json; print(' '.join(json.load(open('$WORK/nodes.alias.json'))))"); do
        (
            r=$(curl_local -sS -m $((TEST_TIMEOUT / 1000 + 8)) "http://127.0.0.1:${ec}/proxies/$a/delay?url=$enc_url&timeout=${TEST_TIMEOUT}" 2>/dev/null || true)
            printf '%s\t%s\n' "$a" "${r//$'\n'/ }" >> "$WORK/raw_delays.tsv"
        ) &
        pids+=("$!")
        # 只等 curl 任务；裸 wait 会连测活内核一起等，导致自锁
        while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$((CONCURRENCY + 1))" ]]; do sleep 0.2; done
    done
    for a in "${pids[@]}"; do wait "$a" 2>/dev/null || true; done

    # 两阶段：只有 google 通（delay>0）的节点才值得测 OpenAI。多数免费节点连 google 都
    # 不通，跳过它们能省下一半测活时间（每个失败节点省一个超时周期）。
    if [[ $do_openai -eq 1 ]]; then
        google_ok=$(WORK="$WORK" "$PY" -c "
import json, os, re
work = os.environ['WORK']
ok = []
for ln in open(os.path.join(work, 'raw_delays.tsv'), encoding='utf-8', errors='replace'):
    a, _, body = ln.rstrip('\n').partition('\t')
    m = re.search(r'\"delay\"\s*:\s*(\d+)', body)
    if m and int(m.group(1)) > 0:
        ok.append(a)
print(' '.join(ok))" )
        pids=()
        if [[ -n "$google_ok" ]]; then
            for a in $google_ok; do
                (
                    ro=$(curl_local -sS -m $((TEST_TIMEOUT / 1000 + 8)) "http://127.0.0.1:${ec}/proxies/$a/delay?url=$enc_openai_url&timeout=${TEST_TIMEOUT}" 2>/dev/null || true)
                    printf '%s\t%s\n' "$a" "${ro//$'\n'/ }" >> "$WORK/raw_openai.tsv"
                ) &
                pids+=("$!")
                while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$((CONCURRENCY + 1))" ]]; do sleep 0.2; done
            done
            for a in "${pids[@]}"; do wait "$a" 2>/dev/null || true; done
        fi
    fi

    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=""

    WORK="$WORK" "$PY" - > "$WORK/probe.summary" <<'PY'
import json, os, re
work = os.environ['WORK']
delays = {}
for ln in open(os.path.join(work, 'raw_delays.tsv'), encoding='utf-8', errors='replace'):
    alias, _, body = ln.rstrip('\n').partition('\t')
    m = re.search(r'"delay"\s*:\s*(\d+)', body) or re.search(r'^\[\["[^"]*",\s*(\d+)\]\]$', body.strip())
    if m and int(m.group(1)) > 0:
        delays[alias] = int(m.group(1))
# OpenAI 检测：有 OpenAI 检测结果时，以 OpenAI 为准（OpenAI 通即入选）。
# 理由：codex 走 chatgpt.com，能访问 OpenAI 的节点才是 codex 能用的；google 检测会误杀
# 「openai 通但 google 超时」的节点（如 BY_23、p209 台湾中华电信——它们能访问 OpenAI）。
# 国内节点访问 OpenAI 会超时，OpenAI 检测天然排除大陆出口，无需再靠 google 过滤。
# delay API 握手：即使返回 403/404 也算「通」（能到达服务器），只有超时/连接失败才不算。
openai_ok = set()
openai_path = os.path.join(work, 'raw_openai.tsv')
openai_used = False
if os.path.exists(openai_path):
    for ln in open(openai_path, encoding='utf-8', errors='replace'):
        alias, _, body = ln.rstrip('\n').partition('\t')
        m = re.search(r'"delay"\s*:\s*(\d+)', body) or re.search(r'^\[\["[^"]*",\s*(\d+)\]\]$', body.strip())
        if m and int(m.group(1)) > 0:
            openai_ok.add(alias)
    # 有 OpenAI 检测结果时以 OpenAI 为准：重建 delays 为 OpenAI 通的节点
    if openai_ok:
        delays = {a: d for a, d in delays.items() if a in openai_ok}
        openai_used = True
# 无 OpenAI 检测（或 OpenAI 全不通）时回退到 google 结果
alive = sorted(delays.items(), key=lambda kv: kv[1])
with open(os.path.join(work, 'alive.tsv'), 'w', encoding='utf-8') as f:
    for alias, d in alive:
        f.write(f'{alias}\t{d}\n')
total = len(json.load(open(os.path.join(work, 'nodes.alias.json'))))
print(f'{len(alive)}\t{total}\t{alive[0][1] if alive else 0}\t{alive[-1][1] if alive else 0}')
PY

    local s rest; s="$(cat "$WORK/probe.summary")"
    local alive total lo hi
    alive="${s%%$'\t'*}"; rest="${s#*$'\t'}"
    total="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    lo="${rest%%$'\t'*}"; hi="${rest#*$'\t'}"
    success "测活通过 $alive/${total}（最快 ${lo}ms，最慢 ${hi}ms）"
    [[ "$alive" -gt 0 ]] || die "本轮没有一个节点测通，多半是本机出网有问题（不是节点全死了）；未做任何修改"
}

# --- 4. 结合历史履历增删节点 -------------------------------------------------
select_nodes() {
    local purge=1
    [[ $SOURCE_FAILED -eq 0 ]] || purge=0
    WORK="$WORK" MAX_NODES="$MAX_NODES" DO_TEST="$DO_TEST" KEEP_FAILS="$KEEP_FAILS" \
    KEEP_NEW="$KEEP_NEW" KEEP_HOURS="$KEEP_HOURS" \
    PURGE="$purge" STATE_FILE="$STATE_FILE" PER_COUNTRY="$PER_COUNTRY" PREFER_TXT="$PREFER" \
    "$PY" - <<'PY' > "$WORK/final.jsonl"
import json, os, time

# 地区优先级：亚洲靠前，认不出地区的排最后。同一个区域内按下面列出的先后分组，
# 组内再按 ISO 码，保证每次生成的菜单顺序一致，且同一个国家的节点总在一起
REGION_ROWS = (
    'CN HK MO TW',                                # 中国 / 港澳 / 台湾
    'JP KR KP',                                   # 东亚
    'SG MY TH VN PH ID KH MM LA BN',              # 东南亚
    'IN PK BD NP LK BT MV KZ UZ MN GE AM AZ IR IQ IL LB SY TR AE SA QA KW BH OM JO YE',  # 南亚 / 中亚 / 中东
    'GB UK IE NL BE LU FR DE AT CH IT ES PT GR SE NO FI DK IS PL CZ SK HU '
    'RO BG HR RS SI BA AL MK ME XK MD UA BY RU LV LT EE MT CY',      # 欧洲
    'US CA MX GT PA CR DO CU',                    # 北美
    'CO VE BR AR CL PE EC',                       # 南美
    'AU NZ FJ',                                   # 大洋洲
    'EG ZA NG KE ET DZ MA TN AO',                 # 非洲
)
REGION = {}
for _rank, _codes in enumerate(REGION_ROWS):
    for _c in _codes.split():
        REGION[_c] = _rank
REGION.setdefault('XX', len(REGION_ROWS))

# --prefer 点名的国家直接提到最前（按点名的先后），没点名的仍按上面的地区表
PREFERRED = {c: i for i, c in enumerate(os.environ.get('PREFER_TXT', '').replace(',', ' ').split())}

def region_key(n):
    cc = n.get('cc') or 'XX'
    if cc in PREFERRED:
        return (0, PREFERRED[cc], 0)
    return (1, REGION.get(cc, len(REGION_ROWS)), cc)

def capped_pick(items, cap, limit):
    """按已排好的顺序取节点。cap>0 时每个国家先只取 cap 个，避免同一家服务商刷屏；
    名额没用完再把溢出的补回来（补的时候同国依然连续），所以不会平白少写节点。"""
    out, count, overflow = [], {}, []
    for r in items:
        cc = r.get('cc') or 'XX'
        if cap and count.get(cc, 0) >= cap:
            overflow.append(r)
            continue
        count[cc] = count.get(cc, 0) + 1
        out.append(r)
        if limit and len(out) >= limit:
            return out
    for r in overflow:
        out.append(r)
        if limit and len(out) >= limit:
            break
    return out

work = os.environ['WORK']
max_nodes = int(os.environ['MAX_NODES'])
per_country = int(os.environ['PER_COUNTRY'])
keep_fails = int(os.environ['KEEP_FAILS'])
keep_hours = int(os.environ['KEEP_HOURS'])
keep_new = int(os.environ['KEEP_NEW'])
purge = os.environ['PURGE'] == '1'
testing = os.environ['DO_TEST'] == '1'
now = int(time.time())
nodes = [json.loads(l) for l in open(os.path.join(work, 'nodes.jsonl'), encoding='utf-8') if l.strip()]
report = {'alive': 0, 'watch': 0, 'held': 0, 'carry': 0, 'new': 0, 'drop_streak': 0,
          'drop_never': 0, 'drop_gone': 0, 'suspect': 0, 'rate': 0.0, 'prev_rate': 0.0}

old, baseline = {}, None
if testing and os.path.exists(os.environ['STATE_FILE']):
    try:
        data = json.load(open(os.environ['STATE_FILE'], encoding='utf-8'))
        old = {r['fp']: r for r in data.get('nodes', []) if r.get('fp')}
        if data.get('pass_rate') is not None:
            baseline = float(data['pass_rate'])
    except Exception:
        old, baseline = {}, None

if not testing:
    # 不测活就没有可用性依据，也无从更新履历：按订阅源轮流取，避免大源把其它源挤光
    buckets = {}
    for n in nodes:
        buckets.setdefault(n['source'], []).append(n)
    order = []
    while any(buckets.values()):
        for b in buckets.values():
            if b:
                order.append(b.pop(0))
    order = sorted(order, key=region_key)
    picked = [{'name': n['name'], 'block': n['block']}
              for n in capped_pick(order, per_country, max_nodes)]
else:
    alias = json.load(open(os.path.join(work, 'nodes.alias.json'), encoding='utf-8'))
    by_name = {n['name']: n for n in nodes}
    delay = {}
    for ln in open(os.path.join(work, 'alive.tsv'), encoding='utf-8'):
        a, _, d = ln.rstrip('\n').partition('\t')
        n = by_name.get(alias.get(a, ''))
        if n:
            delay[n['fp']] = int(d)

    rate = len(delay) / max(1, len(nodes))
    # 通过率相对上一轮骤降：几乎一定是本机出网抽风，而不是几百个节点同时死掉。
    # 这种轮次不记连败也不淘汰，否则两三轮的抖动就能把履历清空。
    if baseline is None:
        suspect, new_rate = len(nodes) >= 20, rate        # 没有基线（比如老履历），本轮只记录不淘汰
    else:
        suspect = len(nodes) >= 20 and baseline >= 0.3 and rate < baseline * 0.4
        new_rate = baseline if suspect else rate
    report.update(suspect=int(suspect), rate=round(rate, 3), prev_rate=round(baseline or 0, 3))

    alive_l, watch_l, held_l, carried_l, new_l, seen = [], [], [], [], [], set()
    for n in nodes:
        seen.add(n['fp'])
        rec = dict(old.get(n['fp']) or {})
        rec.update(fp=n['fp'], name=n['name'], block=n['block'], cc=n.get('cc') or 'XX')
        rec.setdefault('first_seen', now)
        rec.setdefault('ok_count', 0)
        rec.setdefault('fail_streak', 0)
        rec['last_delay'] = delay.get(n['fp'], rec.get('last_delay', 0))
        # 已经无效多久：按最后一次测通算，从没测通过的按第一次见到算。这个是每轮现算的派生值，
        # 不写进履历，否则下一轮读到的是上一轮的时刻
        dead_hours = int((now - (rec.get('last_alive') or rec.get('first_seen') or now)) / 3600)
        # 时长门槛为 0 表示只看轮数，此时一律算「已经够久」，不让它变成永远不删
        old_enough = keep_hours <= 0 or dead_hours >= keep_hours
        if n['fp'] in delay:
            rec.pop('untested', None)
            rec.update(fail_streak=0, ok_count=rec['ok_count'] + 1, last_alive=now)
            alive_l.append(rec)
        elif suspect and rec['ok_count']:
            # 判定为本机出网问题，本轮失败不算节点头上：连败数不动，也不加"暂时不通"标记
            held_l.append(rec)
        elif rec['ok_count'] and (rec['fail_streak'] + 1 < keep_fails or not old_enough):
            # 以前能用、这轮不通：当作暂时挂了，留在菜单里并标注出来
            rec['fail_streak'] += 1
            rec['stale'] = True
            watch_l.append(rec)
        elif rec['ok_count']:
            report['drop_streak'] += 1          # 连败满 keep_fails 轮、无效也满 keep_hours 小时，才判彻底不可用
        elif suspect or rec['fail_streak'] + 1 < keep_new or not old_enough:
            # 从没通过过：先当新面孔留着，否则几百个候选全测不通时菜单会空得只剩几个；
            # 判定为本机出网问题的轮次连观察轮数也不记
            if not suspect:
                rec['fail_streak'] += 1
            rec['untested'] = True
            new_l.append(rec)
        else:
            report['drop_never'] += 1          # 没用过满 keep_new 轮、也满 keep_hours 小时，淘汰
    for fp, rec in old.items():
        if fp in seen:
            continue
        # 上游这次没列出该节点：订阅全拉到了才算下架，否则只是某个源没拉到，原样留着。
        # 刚测通不久就消失的多半是源在抽风，同样给满 keep_hours 再删
        gone_hours = int((now - (rec.get('last_alive') or rec.get('first_seen') or now)) / 3600)
        if purge and (keep_hours <= 0 or gone_hours >= keep_hours):
            report['drop_gone'] += 1
        else:
            carried_l.append(rec)
    # 排序：本轮测通 > 本轮不判 > 观察期 > 源没拉到暂留 > 没用过的新面孔，
    # 同层里按地区→国家聚拢→延迟
    pool = ([(0, r) for r in alive_l] + [(1, r) for r in held_l] +
            [(2, r) for r in watch_l] + [(3, r) for r in carried_l] +
            [(4, r) for r in new_l])
    pool.sort(key=lambda t: (t[0],) + region_key(t[1]) +
                            (t[1].get('last_delay') or 10 ** 9, t[1]['name']))
    # 每国名额按「层」分别限制：测通节点超出名额的，补在测通层末尾，
    # 不会掉到「暂时不通」的节点后面，分层顺序因此仍然成立
    picked = []
    for _tier in range(5):
        items = [r for t, r in pool if t == _tier]
        if not items:
            continue
        room = max_nodes - len(picked) if max_nodes else 0
        picked += capped_pick(items, per_country, room)
        if max_nodes and len(picked) >= max_nodes:
            break
    written = {r['fp'] for r in picked}
    json.dump({'updated': now, 'keep_fails': keep_fails, 'keep_hours': keep_hours,
               'pass_rate': round(new_rate, 3),
               'nodes': [{k: v for k, v in r.items() if k not in ('stale', 'untested')}
                         for r in picked]},
              open(os.path.join(work, 'state.new.json'), 'w', encoding='utf-8'),
              ensure_ascii=False, indent=1)
    report['alive'] = sum(1 for r in alive_l if r['fp'] in written)
    report['watch'] = sum(1 for r in watch_l if r['fp'] in written)
    report['held'] = sum(1 for r in held_l if r['fp'] in written)
    report['carry'] = sum(1 for r in carried_l if r['fp'] in written)
    report['new'] = sum(1 for r in new_l if r['fp'] in written)

used_names = set()
for r in picked:
    # 本轮没测通的节点在名字上做标记，菜单里一眼能看出哪个是暂时挂了、哪个是从没用过
    if r.get('untested'):
        disp = r['name'] + '（没用过）'
    elif r.get('stale'):
        disp = r['name'] + '（暂时不通）'
    else:
        disp = r['name']
    # 同名不同服在免费列表里很常见（多个源都写「俄罗斯+V2CROSS.COM」这种标签），
    # 而 mihomo 要求节点名唯一，撞名会让整份配置在校验阶段直接失败
    if disp in used_names:
        i = 2
        while '%s #%d' % (disp, i) in used_names:
            i += 1
        disp = '%s #%d' % (disp, i)
    used_names.add(disp)
    print(json.dumps({'name': disp, 'block': r['block'],
                      'untested': 1 if r.get('untested') else 0}, ensure_ascii=False))

json.dump({'picked': len(picked), 'report': report},
          open(os.path.join(work, 'picked.json'), 'w'), ensure_ascii=False)
PY
    local picked rep line drop_desc
    picked=$("$PY" -c "import json;print(json.load(open('$WORK/picked.json'))['picked'])")
    info "本轮入选 ${picked} 个节点"
    # keep-hours 为 0 时只看轮数，摘要里就别再写「失效满 0 小时」这种废话
    if [[ "$KEEP_HOURS" == 0 ]]; then
        drop_desc="连续失败满 ${KEEP_FAILS} 轮"
    else
        drop_desc="连续失败满 ${KEEP_FAILS} 轮并且无效满 ${KEEP_HOURS} 小时"
    fi
    if [[ "$DO_TEST" == 1 ]]; then
        rep=$("$PY" -c "
import json
r = json.load(open('$WORK/picked.json'))['report']
print('写入：测通 %d、观察期 %d、本轮不判 %d、源未拉到暂留 %d、新面孔 %d；'
      '淘汰（${drop_desc}）：用过 %d、没用过 %d、上游下架 %d' %
      (r['alive'], r['watch'], r['held'], r['carry'], r['new'],
       r['drop_streak'], r['drop_never'], r['drop_gone']))
if r['suspect']:
    if r['prev_rate']:
        print('通过率只有 %.0f%%（上一轮 %.0f%%），判定为本机出网不稳而不是节点集体失效：'
              '本轮失败不记连败、不淘汰' % (r['rate'] * 100, r['prev_rate'] * 100))
    else:
        print('履历里还没有通过率基线，本轮只记录不判定：失败节点不记连败、不淘汰')")
        while IFS= read -r line; do
            case "$line" in
                通过率* | 履历里*) warn "$line" ;;
                *) info "$line" ;;
            esac
        done <<< "$rep"
    fi
    [[ "$picked" -gt 0 ]] || die "没有节点入选，未做任何修改"
    if [[ "$picked" -lt "$MIN_NODES" ]]; then
        die "入选 ${picked} 个，低于 --min-nodes ${MIN_NODES}：本轮放弃写入，保留上一份配置"
    fi
}

render_provider() {
    WORK="$WORK" OUT="$WORK/provider.yaml" "$PY" - <<'PY'
import json, os
work = os.environ['WORK']
nodes = [json.loads(l) for l in open(os.path.join(work, 'final.jsonl'), encoding='utf-8') if l.strip()]
lines = ['proxies:']
for n in nodes:
    lines.append(f"  - name: {json.dumps(n['name'], ensure_ascii=False)}")
    for extra in n['block'].splitlines():
        lines.append('    ' + extra)
open(os.environ['OUT'], 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PY
}

# --- 5. standalone: 生成整份独立 profile ------------------------------------
render_standalone() {
    # 空数组在 bash 3.2 + set -u 下 "${arr[@]}" 会炸，要用 ${arr[@]+...} 形式
    # 这一段全是命令前的环境变量赋值，中间不能插注释或以反斜杠续行的其它语句
    WORK="$WORK" OUT="$WORK/config.final" GROUP_NAME="$GROUP_NAME" SELECT_GROUP="$SELECT_GROUP" \
    MIXED_PORT="$MIXED_PORT" HEALTH_URL="$HEALTH_URL" GENERATED_MARK="$GENERATED_MARK" \
    EXTRA_DIRECT_TXT="$(printf '%s ' "${EXTRA_DIRECT[@]+"${EXTRA_DIRECT[@]}"}")" \
    EXTRA_PROXY_TXT="$(printf '%s ' "${EXTRA_PROXY[@]+"${EXTRA_PROXY[@]}"}")" PROXY_ONLY="$PROXY_ONLY" \
    SOURCES_TXT="$(printf '%s ' "${SOURCES[@]}")" "$PY" - <<'PY'
import datetime, json, os

work = os.environ['WORK']
group, sel = os.environ['GROUP_NAME'], os.environ['SELECT_GROUP']
health = os.environ['HEALTH_URL']
nodes = [json.loads(l) for l in open(os.path.join(work, 'final.jsonl'), encoding='utf-8') if l.strip()]

lines = [
    os.environ['GENERATED_MARK'],
    '# 由 update-proxy-nodes.sh 生成，请勿手工编辑：下次刷新会整份覆盖',
    '# 生成时间: %s' % datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    '# 订阅来源: %s' % os.environ['SOURCES_TXT'].strip(),
    f"mixed-port: {os.environ['MIXED_PORT']}",
    'allow-lan: false',
    'mode: rule',
    'log-level: warning',
    'unified-delay: true',
    'tcp-concurrent: true',
    'profile:',
    '  store-selected: true',
    # TUN 默认关：ClashX Meta / Clash Verge 都有自己的 TUN 开关并会改写这一段，我们写
    # enable: true 只会让裸跑 mihomo 的人在没有 root 时报错。dns-hijack 必须是 ip:port
    # 形式（之前写裸 IP，内核报 "parse dns-hijack url error: not an ip:port"）
    'tun:',
    '  enable: false',
    '  stack: system',
    '  dns-hijack:',
    '    - "any:53"',
    'dns:',
    '  enable: true',
    '  ipv6: false',
    '  enhanced-mode: fake-ip',
    '  fake-ip-range: 198.18.0.1/16',
    '  default-nameserver: [119.29.29.29, 223.5.5.5]',
    '  nameserver: ["https://223.6.6.6/dns-query", "https://doh.pub/dns-query"]',
    # 国内域名不参与 fake-ip，才能拿到真实 IP 让 GEOIP,CN 判对；内网主机同理
    '  fake-ip-filter: ["*.local", "+.cn", "+.com.cn"]',
    f'test-url: {json.dumps(health, ensure_ascii=False)}',
    'proxies:',
]
for n in nodes:
    lines.append(f"  - name: {json.dumps(n['name'], ensure_ascii=False)}")
    for extra in n['block'].splitlines():
        lines.append('    ' + extra)

lines += ['proxy-groups:', f'- name: {json.dumps(sel, ensure_ascii=False)}', '  type: select', '  proxies:',
          f'    - {json.dumps(group, ensure_ascii=False)}',
          f'    - {json.dumps(group + "_backup", ensure_ascii=False)}']
# 菜单里直接列出每个节点，可手动固定；最后一项 DIRECT 作直连兜底
lines += [f'    - {json.dumps(n["name"], ensure_ascii=False)}' for n in nodes]
lines += ['    - DIRECT']
lines += [f'- name: {json.dumps(group, ensure_ascii=False)}', '  type: url-test', '  proxies:']
# 自动测速组只放验证过的节点：客户端会按 interval 反复探测组内每个节点，
# 把几百个「没用过」的候选也塞进去等于每天多发几倍探针，它们只留在上面的菜单里供手动挑
tested = [n for n in nodes if not n.get('untested')] or nodes
lines += [f'    - {json.dumps(n["name"], ensure_ascii=False)}' for n in tested]
lines += [f'  url: {json.dumps(health, ensure_ascii=False)}', '  interval: 300', '  tolerance: 50', '  lazy: false']
# 兜底组：url-test 快（interval 300 内反复测速切换），fallback 慢但保命——url-test 里所有
# 成员都超时后，fallback 会依次切到下一个成员继续测活，不会卡死在「最后一个也死了」。
# 节点选择里两个组都列出，用户可手动切；fallback 引用与 url-test 相同的已验证节点集合。
lines += [f'- name: {json.dumps(group + "_backup", ensure_ascii=False)}', '  type: fallback', '  proxies:']
lines += [f'    - {json.dumps(n["name"], ensure_ascii=False)}' for n in tested]
lines += [f'  url: {json.dumps(health, ensure_ascii=False)}', '  interval: 300', '  tolerance: 50', '  lazy: false']
# 分流：国内/内网一律直连，节点死活只影响境外流量。域名规则在前（fake-ip 模式下 GEOIP
# 可能拿到假地址），GEOSITE 名称由内核校验，缺失会在 mihomo -t 阶段直接失败
extra_direct = os.environ['EXTRA_DIRECT_TXT'].split()
extra_proxy = os.environ['EXTRA_PROXY_TXT'].split()
# 内网永远直连；--extra-proxy 点名的域排在 cn 之前，所以 .cn 里想走代理的站也能拉过来
rules = ['  - GEOSITE,private,DIRECT', '  - GEOIP,private,DIRECT,no-resolve']
rules += ['  - DOMAIN-SUFFIX,%s,%s' % (d, sel) for d in extra_proxy]
rules += ['  - GEOSITE,cn,DIRECT', '  - GEOIP,CN,DIRECT']
rules += ['  - DOMAIN-SUFFIX,%s,DIRECT' % d for d in extra_direct]
if os.environ['PROXY_ONLY'] == '1':
    # 精确白名单：走节点的 = --extra-proxy 点名的精确域名后缀（已在上面 extra_proxy 展开成
    # DOMAIN-SUFFIX）加下面几个保险类别（只匹配这些域，不误伤其他），其余一律直连。
    # 注意：不要加 geolocation-!cn / category-ai-!cn —— 它们会吞掉全部非大陆域名，
    # 与「大部分直连」相悖；类别名由内核在 mihomo -t 阶段校验，缺失会直接报错不会静默失效
    rules += ['  - GEOSITE,%s,%s' % (c, sel) for c in ('github', 'google', 'openai')]
    rules += ['  - MATCH,DIRECT']
else:
    rules += ['  - MATCH,%s' % sel]
lines += ['rules:'] + rules
open(os.environ['OUT'], 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(f'节点 {len(nodes)} 个')
PY
}

# --- 6. inject: 在主配置里维护托管区块 ---------------------------------------
patch_config() {
    WORK="$WORK" CONFIG_FILE="$CONFIG_FILE" OUT="$WORK/config.patched" \
    PROVIDER_NAME="$PROVIDER_NAME" PROVIDER_RELPATH="$PROVIDER_RELPATH" GROUP_NAME="$GROUP_NAME" \
    HEALTH_URL="$HEALTH_URL" PROVIDER_INTERVAL="$PROVIDER_INTERVAL" \
    MARK_BEGIN="$MARK_BEGIN" MARK_END="$MARK_END" \
    LEGACY_MARK_BEGIN="$LEGACY_MARK_BEGIN" LEGACY_MARK_END="$LEGACY_MARK_END" "$PY" - <<'PY'
import json, os, re

work = os.environ['WORK']
# 改名前写入的区块用另一对标记，摘除时新旧都认，否则会留下删不掉的孤儿区块
BEGINS = [os.environ['MARK_BEGIN'], os.environ['LEGACY_MARK_BEGIN']]
ENDS = [os.environ['MARK_END'], os.environ['LEGACY_MARK_END']]
begin, end = BEGINS[0], ENDS[0]
PROVIDER_NAME = os.environ['PROVIDER_NAME']
PROVIDER_RELPATH = os.environ['PROVIDER_RELPATH']
GROUP_NAME = os.environ['GROUP_NAME']
HEALTH_URL = os.environ['HEALTH_URL']
PROVIDER_INTERVAL = os.environ['PROVIDER_INTERVAL']
lines = open(os.environ['CONFIG_FILE'], encoding='utf-8', errors='replace').read().splitlines()

# 先摘掉上一轮的托管区块，保证幂等；区块不完整就中止，避免破坏用户配置
def tag_of(s, marks):
    for m in marks:
        if s.startswith(m + ' '):
            return s[len(m):].strip()
    return None

out, skip_tag = [], None
for ln in lines:
    s = ln.strip()
    if skip_tag is None:
        found = tag_of(s, BEGINS)
        if found is not None:
            skip_tag = found
            continue
    if skip_tag is not None:
        if tag_of(s, ENDS) == skip_tag:
            skip_tag = None
        continue
    out.append(ln)
if skip_tag is not None:
    raise SystemExit(f'托管区块缺少 {skip_tag} 的结束标记，已中止以免破坏配置')
lines = out
while lines and not lines[-1].strip():
    lines.pop()

def tops():
    return [i for i, l in enumerate(lines) if re.match(r'^[A-Za-z_][\w-]*:', l)]

def span(key):
    for i in tops():
        if lines[i].rstrip() == f'{key}:':
            return i, next((k for k in tops() if k > i), len(lines))
    return None

def insert_into(key, block, indent_if_new):
    """把 block 追加到顶层 key 的末尾；key 不存在则在文件末尾新建。"""
    loc = span(key)
    if loc is None:
        lines.append(f'{key}:')
        pad = ' ' * indent_if_new
        lines.extend(pad + ln for ln in block)
        return '新建'
    start, stop = loc
    indent = next((len(lines[k]) - len(lines[k].lstrip())
                   for k in range(start + 1, stop) if lines[k].strip()), indent_if_new)
    pos = start
    for k in range(start + 1, stop):
        if lines[k].strip():
            pos = k
        elif k < stop - 1:
            break
    pad = ' ' * indent
    for offset, ln in enumerate(block, 1):
        lines.insert(pos + offset, pad + ln)
    return '追加'

provider_block = [
    f'{begin} provider',
    f'{PROVIDER_NAME}:',
    '  type: file',
    f'  path: {json.dumps(os.environ["PROVIDER_RELPATH"], ensure_ascii=False)}',
    '  format: yaml',
    f'  interval: {os.environ["PROVIDER_INTERVAL"]}',
    '  health-check:',
    '    enable: true',
    f'    url: {json.dumps(os.environ["HEALTH_URL"], ensure_ascii=False)}',
    '    interval: 600',
    f'{end} provider',
]
group_block = [
    f'{begin} group',
    f'- name: {json.dumps(os.environ["GROUP_NAME"], ensure_ascii=False)}',
    '  type: url-test',
    '  use:',
    f'    - {PROVIDER_NAME}',
    f'  url: {json.dumps(os.environ["HEALTH_URL"], ensure_ascii=False)}',
    '  interval: 300',
    '  tolerance: 50',
    '  lazy: true',
    f'{end} group',
]

a = insert_into('proxy-providers', provider_block, 2)
b = insert_into('proxy-groups', group_block, 0)
open(os.environ['OUT'], 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(f'proxy-providers: {a} | proxy-groups: {b}')
PY
}

# --- 7. 校验并落盘 -----------------------------------------------------------
validate_config() {
    [[ -n "$CORE" ]] || { warn "未找到内核，跳过配置校验"; return 0; }
    local vdir="$WORK/validate"
    rm -rf "$vdir"; mkdir -p "$vdir"
    # 把同目录的 geo / rule-provider 一并镜像过来，避免校验因缺文件误报
    local f
    for f in "$CONFIG_DIR"/*; do
        [[ -f "$f" ]] && ln -sf "$f" "$vdir/$(basename "$f")"
    done
    cp "$FINAL_CONFIG" "$vdir/config.yaml"
    if [[ "$MODE" == inject ]]; then
        cp "$WORK/provider.yaml" "$vdir/$PROVIDER_RELPATH"
    fi
    if ! "$CORE" -t -d "$vdir" -f "$vdir/config.yaml" >"$WORK/validate.log" 2>&1; then
        sed -n '1,25p' "$WORK/validate.log" >&2
        die "生成的配置未通过内核校验，已中止（原配置未改动）"
    fi
    success "配置校验通过"
}

apply_changes() {
    if [[ "$DRY_RUN" == 1 ]]; then
        validate_config
        if [[ "$MODE" == inject ]]; then
            info "provider 预览（前 12 行）:"
            head -12 "$WORK/provider.yaml" | sed 's/^/    /'
            echo
            info "主配置差异:"
            diff -u "$CONFIG_FILE" "$FINAL_CONFIG" | tail -n +3 | sed 's/^/    /' || true
        else
            info "生成配置预览（前 20 行）:"
            head -20 "$FINAL_CONFIG" | sed 's/^/    /'
            info "共 $(wc -l < "$FINAL_CONFIG" | tr -d ' ') 行，$(grep -c '^  - name:' "$FINAL_CONFIG") 个节点"
        fi
        warn "--dry-run: 未写入任何文件"
        return 0
    fi

    validate_config

    if [[ "$MODE" == inject ]]; then
        # provider 是独立新文件，先落盘，主配置引用它才有内容可读
        cp "$WORK/provider.yaml" "$PROVIDER_FILE.tmp" && mv "$PROVIDER_FILE.tmp" "$PROVIDER_FILE"
        success "已写入节点文件: $PROVIDER_RELPATH"
    fi

    local backup=""
    if [[ -f "$CONFIG_FILE" ]]; then
        backup="$CONFIG_FILE.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$CONFIG_FILE" "$backup"
    fi
    mv "$FINAL_CONFIG" "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    if [[ "$MODE" == inject ]]; then
        success "已更新主配置: $CONFIG_FILE"
    else
        success "已生成独立 profile: $CONFIG_FILE"
    fi

    # Verge Rev 不读 CLIENT_DIR/free-nodes.yaml，只读 profiles/<激活uid>.yaml。
    # 成品要再同步进激活 profile，否则刷新完界面还停在旧配置（今天 07:39 的定时刷新
    # 就写到了 Application Support/free-nodes.yaml，而激活 profile 还停在 11-02）。
    if [[ "$CLIENT" == verge ]]; then
        local vp
        vp="$(verge_active_profile || true)"
        if [[ -n "$vp" ]]; then
            cp "$CONFIG_FILE" "$vp.tmp" && mv "$vp.tmp" "$vp"
            success "已同步到激活 profile: $(basename "$vp")"
        else
            warn "未找到 Verge 激活 profile（profiles.yaml 无 current），请手动点一次该配置"
        fi
    fi
    if [[ -f "$WORK/state.new.json" ]]; then
        cp "$WORK/state.new.json" "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
        info "已更新履历: $(basename "$STATE_FILE")（$(grep -c '"fp":' "$STATE_FILE") 个节点）"
    fi
    if [[ -n "$backup" ]]; then
        success "已备份: $(basename "$backup")"
    fi

    ls -1t "$CONFIG_FILE.bak-"* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
        [[ -n "$old" ]] && rm -f "$old" && info "清理旧备份: $(basename "$old")"
    done
}

set_default_profile() {
    if [[ "$CLIENT" != meta ]]; then
        warn "--set-default 只有 ClashX Meta 支持（写 selectConfigName），${CLIENT_NAME} 请在客户端里手动选配置"
        return 0
    fi
    if pgrep -f "$BUNDLE_ID" >/dev/null 2>&1; then
        die "$BUNDLE_ID 正在运行，写 selectConfigName 会在退出时被覆盖。请先完全退出应用，或改用 --reload"
    fi
    defaults write "$BUNDLE_ID" selectConfigName "$CONFIG_BASE"
    success "已将 $CONFIG_BASE 设为 ClashX Meta 默认配置"
}

# 客户端 API 可能设了 secret；Verge Rev 默认关掉 TCP 端口，只留一个 unix socket
api_secret() {
    local s=""
    if [[ -f "$CONFIG_FILE" ]]; then
        s=$(sed -n 's/^[[:space:]]*secret:[[:space:]]*//p' "$CONFIG_FILE" | head -n 1 | tr -d '\"\047 \t\r')
    fi
    # set-your-secret 是模板里的占位值，等于没设
    if [[ -n "$s" && "$s" != set-your-secret ]]; then echo "$s"; fi
    return 0
}

# Verge Rev 默认不开 TCP API 端口，只留一个 unix socket。这个路径有两层坑：
# 一是客户端落盘配置里的 external-controller-unix 指向会话临时目录，内核重装后就失效；
# 二是真正在用的那个由内核命令行 -ext-ctl-unix 直接给出，且路径里可能带空格
# （/Library/Application Support/...），按空格切命令行会把它截断。
# 所以优先信命令行，配置只作退回。
verge_unix_socket() {
    local pid proc_args sock=""
    # 1) 最权威：内核自己带出来的 -ext-ctl-unix
    #    取标志位之后的「剩余整行」而不是第一个空白前的片段 —— 路径里可能带空格
    #    （/Library/Application Support/...），按空白截断会把真实路径截掉。
    for pid in $(pgrep -f 'verge-mihomo' 2>/dev/null | head -n 3 || true); do
        proc_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
        [[ "$proc_args" == *verge-mihomo* && "$proc_args" == *-ext-ctl-unix* ]] || continue
        sock=$(printf '%s' "$proc_args" | sed -n 's/.*-ext-ctl-unix[[:space:]]\{1,\}//p')
        sock="${sock%"${sock##*[![:space:]]}"}"
        if [[ -n "$sock" && -S "$sock" ]]; then
            printf '%s' "$sock"
            return 0
        fi
    done
    # 2) 退回：客户端落盘配置里的声明（内核重启后可能已失效）
    local dir="${CLIENT_DIR:-}" p
    [[ -n "$dir" ]] || return 1
    for p in "$dir/clash-verge.yaml" "$dir/verge.yaml"; do
        [[ -f "$p" ]] || continue
        while IFS= read -r sock; do
            sock="${sock#"${sock%%[![:space:]]*}"}"; sock="${sock%"${sock##*[![:space:]]}"}"
            [[ -z "$sock" || ! -S "$sock" ]] && continue
            printf '%s' "$sock"
            return 0
        done < <(sed -n 's/^[[:space:]]*external-controller-unix:[[:space:]]*//p' "$p" | tr -d "'\"")
    done
    return 1
}

# Verge Rev 的「当前激活的 profile」——就是 profiles.yaml 里 current 指向的那个 uid。
# 脚本写的 CONFIG_FILE（CLIENT_DIR/free-nodes.yaml）只是落盘副本，Verge 根本不读它，
# 内核实际加载的是 profiles/<uid>.yaml 合并生成的 runtime 配置。要真正让 Verge 用上，
# 必须把成品同步进激活 profile，否则定时刷新一直在更新一份没人读的文件。
verge_active_profile() {
    local dir="${CLIENT_DIR:-}" uid
    [[ -n "$dir" ]] || return 1
    uid=$(sed -n 's/^current:[[:space:]]*//p' "$dir/profiles.yaml" 2>/dev/null | head -n 1 | tr -d '"' | tr -d ' ')
    [[ -n "$uid" ]] || return 1
    printf '%s' "$dir/profiles/$uid.yaml"
    return 0
}

reload_client() {
    local secret auth url body http via live_sock=""
    secret="$(api_secret)"
    auth=""
    [[ -z "$secret" ]] || auth="Authorization: Bearer $secret"

    # 客户端写死在 CLIENT_SOCK 的路径往往早就失效了，重载前现探一次真实 socket
    [[ "$CLIENT" == verge ]] && live_sock="$(verge_unix_socket || true)"

    via="tcp"
    if curl_local -fsS -m 3 "$CLASH_API/version" ${auth:+-H "$auth"} >/dev/null 2>&1; then
        url="$CLASH_API"
    elif [[ -n "$CLIENT_SOCK" && -S "$CLIENT_SOCK" ]] &&\
        curl_local -fsS -m 3 --unix-socket "$CLIENT_SOCK" "http://localhost/version" ${auth:+-H "$auth"} >/dev/null 2>&1; then
        url="$CLIENT_SOCK"
        via="unix"
    elif [[ -n "$live_sock" ]] &&\
        curl_local -fsS -m 3 --unix-socket "$live_sock" "http://localhost/version" ${auth:+-H "$auth"} >/dev/null 2>&1; then
        url="$live_sock"
        via="unix"
        info "内核 API: ${CLIENT_NAME} 的 socket 在 ${live_sock}"
    else
        warn "内核 API 不可达（${CLASH_API}${CLIENT_SOCK:+，也没有 ${CLIENT_SOCK}}），请在 ${CLIENT_NAME} 里重新点一次该配置"
        return 0
    fi

    # 重要事实（实测验证）：Verge 内核只接受 PUT /configs 的 path 落在它自己的
    # home 目录（/Library/Application Support/clash-verge-service/users/501/runtime）内，
    # 之外的路径一律 400「path is not subpath of home directory」。而那个 runtime 目录
    # root 所有、无 sudo 密码，脚本根本写不进去。所以对 verge 做 PUT 重载必然失败，
    # 唯一可靠途径是把成品同步进激活 profile 后由用户在 GUI 里点一次该配置
    # （Verge 会重新合并生成 runtime/config.yaml）。ClashX Meta 才用 API PUT 重载。
    if [[ "$CLIENT" == verge ]]; then
        local vp
        vp="$(verge_active_profile || true)"
        if [[ -n "$vp" && -f "$vp" ]]; then
            info "${CLIENT_NAME} 的激活 profile 已更新，请在窗口里重新点一次该配置以合并生效"
        fi
        return 0
    fi

    body="{\"path\":\"$CONFIG_FILE\"}"
    if [[ "$via" == unix ]]; then
        http=$(curl_local -sS -m 8 -o /dev/null -w '%{http_code}' --unix-socket "$url" -X PUT "http://localhost/configs" ${auth:+-H "$auth"} -H 'Content-Type: application/json' -d "$body" || echo 000)
    else
        http=$(curl_local -sS -m 8 -o /dev/null -w '%{http_code}' -X PUT "$CLASH_API/configs" ${auth:+-H "$auth"} -H 'Content-Type: application/json' -d "$body" || echo 000)
    fi
    if [[ "$http" =~ ^2 ]]; then
        success "已请求内核重载（${CLIENT_NAME}，${via}）"
        [[ "$CLIENT" == meta ]] || info "界面上可能还要再点一次才会切过去"
    else
        warn "API 重载未生效（HTTP ${http}），请在 ${CLIENT_NAME} 里重新点一次该配置"
    fi
}

main() {
    fetch_sources
    integrate_local_sources
    extract_nodes
    if [[ "$DO_TEST" == 1 ]]; then
        probe_nodes
    fi
    select_nodes
    local note
    if [[ "$MODE" == standalone ]]; then
        FINAL_CONFIG="$WORK/config.final"
        note="$(render_standalone)" || die "生成独立 profile 失败"
        [[ -s "$FINAL_CONFIG" ]] || die "未能生成独立 profile"
        info "profile 内容: $note"
    else
        FINAL_CONFIG="$WORK/config.patched"
        render_provider
        note="$(patch_config)" || die "生成托管区块失败"
        [[ -s "$FINAL_CONFIG" ]] || die "未能生成修补后的配置"
        info "托管区块: $note"
    fi
    apply_changes
    if [[ "$SET_DEFAULT" == 1 ]]; then
        set_default_profile
    fi
    if [[ "$DO_RELOAD" == 1 ]]; then
        reload_client
    fi
    success "完成"
}

main "$@"
