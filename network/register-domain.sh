#!/usr/bin/env bash
# 开发环境域名辅助脚本。
# 支持免费开发入口，并保留 Cloudflare Registrar 付费购买的显式确认流程。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER="cloudflare-registrar"
DOMAIN=""
QUERY=""
LIMIT=5
ROOTDOMAIN="${DNSHE_ROOTDOMAIN:-}"
REGISTER=false
YES=false
DRY_RUN=false
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-${ACCOUNT_ID:-}}"
CF_API_TOKEN="${CLOUDFLARE_API_TOKEN:-${CF_API_TOKEN:-}}"
DNSHE_API_KEY="${DNSHE_API_KEY:-}"
DNSHE_API_SECRET="${DNSHE_API_SECRET:-}"
DNSHE_API_ENDPOINT="${DNSHE_API_ENDPOINT:-https://api005.dnshe.com/index.php?m=domain_hub}"
DNSHE_LIST_ACTION="${DNSHE_LIST_ACTION:-list}"
DNSHE_REGISTER_ACTION="${DNSHE_REGISTER_ACTION:-register}"
DNSHE_RECORD_ACTION="${DNSHE_RECORD_ACTION:-add_record}"
DNSHE_RECORD_HOST="${DNSHE_RECORD_HOST:-@}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"
DUCKDNS_CONFIG="${DUCKDNS_CONFIG:-${SCRIPT_DIR}/duck.sh}"
FREEDNS_UPDATE_URL="${FREEDNS_UPDATE_URL:-}"
PUBLISH=false
LOCAL_IP="127.0.0.1"
LOCAL_PORT=""
PUBLIC_IP="${PUBLIC_FRPS_IP:-${FRPS_PUBLIC_IP:-${PUBLIC_IP:-}}}"
EMAIL=""
BACKGROUND=false
TUNNEL_LOG=""
PUBLISH_SCRIPT="${PUBLISH_SCRIPT:-${SCRIPT_DIR}/publish-dev-https.sh}"

log() { printf '[信息] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

public_ip_placeholder() {
  if [[ -n "$PUBLIC_IP" ]]; then
    printf '%s\n' "$PUBLIC_IP"
  else
    printf '${PUBLIC_FRPS_IP}\n'
  fi
}

usage() {
  local public_ip_example
  public_ip_example="$(public_ip_placeholder)"
  cat <<EOF
用法:
  $0 --provider dnshe --domain NAME[.us.ci] --rootdomain us.ci --register --yes [--public-ip IP] [--publish --local-port PORT]
  $0 --provider duckdns --domain NAME[.duckdns.org] --duckdns-token TOKEN --public-ip IP [--publish --local-port PORT]
  $0 --provider freedns --domain DOMAIN --freedns-update-url URL [--publish --local-port PORT]
  $0 --provider trycloudflare --local-port PORT [--background]
  $0 --provider digitalplat --domain NAME.dpdns.org
  $0 --provider euorg --domain NAME.eu.org
  $0 --provider cloudflare-registrar --domain DOMAIN [--register --yes]
  $0 --provider cloudflare-registrar --search QUERY [--limit N]

推荐选择:
  trycloudflare        最快：随机 HTTPS 地址，不需要域名、DNS、frp、证书；适合临时 OAuth/Webhook 调试。
  dnshe                推荐自动化：支持免费子域注册和 DNS 记录 API，适合 CI/CD 和开发环境。
  duckdns              推荐：免费固定 *.duckdns.org 子域；适合长期开发环境，配合 frp/nginx/Let's Encrypt。
  freedns              可用：使用 FreeDNS 后台给出的 Direct URL 更新已有免费子域。
  digitalplat          向导模式：免费域名需在 DigitalPlat Dashboard 申请并配置自定义 NS。
  euorg                向导模式：免费子域需先配置 nameserver，再提交人工审核。
  cloudflare-registrar 付费：查询/购买正式域名，必须显式 --register --yes。

通用参数:
  --provider NAME      服务商: dnshe, duckdns, freedns, trycloudflare, digitalplat, euorg, cloudflare-registrar
  --domain DOMAIN      域名或子域名
  --rootdomain DOMAIN  DNSHE 根域，例如 us.ci、de5.net、cc.cd、bot.cd
  --publish            DNS 更新后调用 publish-dev-https.sh 配置 nginx + frp + 证书
  --dry-run            只显示将执行的动作，不修改 DNS、不调用发布脚本
  --local-port PORT    本机服务端口；--publish 和 trycloudflare 需要
  --local-ip IP        trycloudflare 转发目标 IP，默认: 127.0.0.1
  --public-ip IP       公网 frps IP；也可设置 PUBLIC_FRPS_IP 或 FRPS_PUBLIC_IP
  --email EMAIL        Let's Encrypt 邮箱，传给 publish-dev-https.sh
  --publish-script P   publish-dev-https.sh 路径
  -h, --help           显示帮助

DNSHE 参数:
  --rootdomain DOMAIN  DNSHE 根域；也可设置 DNSHE_ROOTDOMAIN
  --register --yes     创建免费子域。DNSHE 会消耗账号免费域名额度，仍要求显式确认。
  --search QUERY       搜索当前账号下已有子域

DuckDNS 参数:
  --duckdns-token T    DuckDNS token；也可设置 DUCKDNS_TOKEN
  DUCKDNS_CONFIG       默认读取同目录 duck.sh，可从 DuckDNS update URL 解析 domains/token

FreeDNS 参数:
  --freedns-update-url URL
                       FreeDNS Dynamic DNS 页面的 Direct URL；也可设置 FREEDNS_UPDATE_URL

TryCloudflare 参数:
  --background         后台启动 cloudflared 并打印生成的 URL
  --tunnel-log FILE    后台日志路径，默认: ~/.local/state/dev-domain/trycloudflare-PORT.log

Cloudflare Registrar 参数:
  --search QUERY       按关键词搜索可注册域名
  --limit N            搜索数量，默认: 5
  --register           购买域名
  --yes                与 --register 配合使用，确认付费且不可逆

环境变量:
  PUBLIC_FRPS_IP 或 FRPS_PUBLIC_IP
  DNSHE_API_KEY
  DNSHE_API_SECRET
  DNSHE_ROOTDOMAIN
  DNSHE_API_ENDPOINT
  DNSHE_LIST_ACTION / DNSHE_REGISTER_ACTION / DNSHE_RECORD_ACTION
  DUCKDNS_TOKEN
  DUCKDNS_CONFIG
  FREEDNS_UPDATE_URL
  CLOUDFLARE_ACCOUNT_ID or ACCOUNT_ID
  CLOUDFLARE_API_TOKEN or CF_API_TOKEN

示例:
  export PUBLIC_FRPS_IP='你的公网 frps 服务器 IP'
  export DNSHE_API_KEY='你的 DNSHE API Key'
  export DNSHE_API_SECRET='你的 DNSHE API Secret'
  $0 --provider dnshe --domain my-dev --rootdomain us.ci --register --yes --public-ip "${public_ip_example}" --publish --local-port 3000 --email admin@example.com
  $0 --provider duckdns --domain yuanhangzhe --public-ip "${public_ip_example}" --dry-run
  $0 --provider duckdns --public-ip "${public_ip_example}" --publish --local-port 3000 --email admin@example.com
  $0 --provider freedns --domain app.example.mooo.com --freedns-update-url 'https://freedns.afraid.org/dynamic/update.php?...'
  $0 --provider trycloudflare --local-port 3000 --background
  $0 --provider cloudflare-registrar --search "sense ai dev" --limit 10
  $0 --provider cloudflare-registrar --domain example.dev --register --yes
EOF
}

guide() {
  local public_ip_example
  public_ip_example="$(public_ip_placeholder)"
  cat <<EOF
开发环境域名配置指南

推荐顺序:
  1. 临时公网 HTTPS: trycloudflare
     不需要域名注册、DNS、frp、证书。适合 Google OAuth 回调、Webhook、临时演示。
     命令:
       $0 --provider trycloudflare --local-port 3000 --background

  2. 自动化免费子域: DNSHE
     DNSHE 支持免费子域注册和 DNS 记录 API，适合脚本化创建 A 记录并衔接 frp/nginx/证书。
     需要先在 DNSHE Client Area 创建 API Key 和 Secret。
     命令:
       export PUBLIC_FRPS_IP='你的公网 frps 服务器 IP'
       export DNSHE_API_KEY='你的 DNSHE API Key'
       export DNSHE_API_SECRET='你的 DNSHE API Secret'
       $0 --provider dnshe --domain my-dev --rootdomain us.ci --register --yes --public-ip "${public_ip_example}" --publish --local-port 3000 --email admin@example.com

  3. 固定免费子域: DuckDNS
     需要在 https://www.duckdns.org 登录后添加子域并复制 token。
     适合长期开发入口，DNS 指向公网 frps 服务器，再由 publish-dev-https.sh 配置 nginx/frp/证书。
     如果同目录存在 duck.sh，脚本会自动读取其中的 domains/token。
     命令:
       export PUBLIC_FRPS_IP='你的公网 frps 服务器 IP'
       $0 --provider duckdns --public-ip "${public_ip_example}" --dry-run
       $0 --provider duckdns --public-ip "${public_ip_example}" --publish --local-port 3000 --email admin@example.com

  4. 已有 FreeDNS 免费子域
     需要先在 https://freedns.afraid.org 创建子域，并复制 Dynamic DNS 的 Direct URL。
     命令:
       export PUBLIC_FRPS_IP='你的公网 frps 服务器 IP'
       export FREEDNS_UPDATE_URL='https://freedns.afraid.org/dynamic/update.php?...'
       $0 --provider freedns --domain app.example.mooo.com --public-ip "${public_ip_example}" --publish --local-port 3000 --email admin@example.com

  5. DigitalPlat 免费域名
     支持 qzz.io、dpdns.org、us.kg、xx.kg、qd.je 等公开命名空间，但注册通常需要登录 Dashboard 并配置自定义 nameserver。
     脚本提供配置向导，不自动模拟网页注册。
     命令:
       $0 --provider digitalplat --domain my-dev.dpdns.org

  6. EU.org 免费子域
     EU.org 要求先配置 nameserver，再提交申请并等待人工审核；不适合自动注册。
     命令:
       $0 --provider euorg --domain my-dev.eu.org

  7. 正式付费域名: Cloudflare Registrar
     只适合需要正式域名时使用。购买动作必须加 --register --yes。
     命令:
       export CLOUDFLARE_ACCOUNT_ID='你的账号 ID'
       export CLOUDFLARE_API_TOKEN='你的 API token'
       $0 --provider cloudflare-registrar --search 'my dev app' --limit 10

当前开发服务器建议:
  公网 frps 服务器 IP: 设置 PUBLIC_FRPS_IP 或执行时传入 --public-ip
  studio 本机服务: 使用 --local-port 指向实际项目端口，例如 3000、5173、8080
  已有 frp/nginx/证书链路: 使用 --publish 自动调用 publish-dev-https.sh

查看完整参数:
  $0 --help
EOF
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"
}

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    guide
    exit 0
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider) PROVIDER="${2:-}"; shift 2 ;;
      --provider=*) PROVIDER="${1#*=}"; shift ;;
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --domain=*) DOMAIN="${1#*=}"; shift ;;
      --rootdomain) ROOTDOMAIN="${2:-}"; shift 2 ;;
      --rootdomain=*) ROOTDOMAIN="${1#*=}"; shift ;;
      --search) QUERY="${2:-}"; shift 2 ;;
      --search=*) QUERY="${1#*=}"; shift ;;
      --limit) LIMIT="${2:-}"; shift 2 ;;
      --limit=*) LIMIT="${1#*=}"; shift ;;
      --register) REGISTER=true; shift ;;
      --yes|-y) YES=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --publish) PUBLISH=true; shift ;;
      --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
      --local-port=*) LOCAL_PORT="${1#*=}"; shift ;;
      --local-ip) LOCAL_IP="${2:-}"; shift 2 ;;
      --local-ip=*) LOCAL_IP="${1#*=}"; shift ;;
      --public-ip) PUBLIC_IP="${2:-}"; shift 2 ;;
      --public-ip=*) PUBLIC_IP="${1#*=}"; shift ;;
      --email) EMAIL="${2:-}"; shift 2 ;;
      --email=*) EMAIL="${1#*=}"; shift ;;
      --publish-script) PUBLISH_SCRIPT="${2:-}"; shift 2 ;;
      --publish-script=*) PUBLISH_SCRIPT="${1#*=}"; shift ;;
      --duckdns-token) DUCKDNS_TOKEN="${2:-}"; shift 2 ;;
      --duckdns-token=*) DUCKDNS_TOKEN="${1#*=}"; shift ;;
      --freedns-update-url) FREEDNS_UPDATE_URL="${2:-}"; shift 2 ;;
      --freedns-update-url=*) FREEDNS_UPDATE_URL="${1#*=}"; shift ;;
      --background) BACKGROUND=true; shift ;;
      --tunnel-log) TUNNEL_LOG="${2:-}"; shift 2 ;;
      --tunnel-log=*) TUNNEL_LOG="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done
}

validate_common() {
  command -v curl >/dev/null 2>&1 || die "缺少 curl"
  [[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit 必须是数字"
  case "$PROVIDER" in
    cloudflare|cloudflare-registrar) PROVIDER="cloudflare-registrar" ;;
    dnshe|duckdns|freedns|trycloudflare|digitalplat|euorg) ;;
    *) die "不支持的 --provider: ${PROVIDER}" ;;
  esac
  if [[ "$PUBLISH" == "true" ]]; then
    [[ -n "$LOCAL_PORT" ]] || die "--publish 需要指定 --local-port"
    [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || die "--local-port 必须是数字"
    [[ -x "$PUBLISH_SCRIPT" ]] || die "发布脚本不可执行: $PUBLISH_SCRIPT"
  fi
}

detect_public_ip() {
  local ip
  ip="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsS --max-time 10 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "无法自动探测公网 IPv4，请显式传入 --public-ip"
  printf '%s\n' "$ip"
}

cf_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local -a args=(-fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(--data "$data")
  curl "${args[@]}"
}

validate_cloudflare_registrar() {
  if [[ -z "$DOMAIN" && -z "$QUERY" ]]; then
    die "Cloudflare Registrar 需要使用 --domain 或 --search"
  fi
  if [[ -n "$DOMAIN" && -n "$QUERY" ]]; then
    die "--domain 和 --search 只能二选一"
  fi
  [[ -n "$ACCOUNT_ID" ]] || die "缺少 CLOUDFLARE_ACCOUNT_ID 或 ACCOUNT_ID。仅查询/购买 Cloudflare Registrar 域名时需要。运行 $0 查看免费开发域名指南。"
  [[ -n "$CF_API_TOKEN" ]] || die "缺少 CLOUDFLARE_API_TOKEN 或 CF_API_TOKEN。仅查询/购买 Cloudflare Registrar 域名时需要。"
  command -v jq >/dev/null 2>&1 || die "缺少 jq"
  if [[ "$REGISTER" == "true" && "$YES" != "true" ]]; then
    die "--register 会产生付费购买且不可逆；确认价格后请加 --register --yes"
  fi
  if [[ "$PUBLISH" == "true" && -z "$PUBLIC_IP" ]]; then
    die "cloudflare-registrar 配合 --publish 时需要 --public-ip"
  fi
}

search_domains() {
  local encoded response
  encoded="$(urlencode "$QUERY")"
  response="$(cf_api GET "/accounts/${ACCOUNT_ID}/registrar/domain-search?q=${encoded}&limit=${LIMIT}")"
  printf '%s\n' "$response" | jq .
}

check_domain_raw() {
  cf_api POST "/accounts/${ACCOUNT_ID}/registrar/domain-check" "{\"domains\":[\"$(json_escape "$DOMAIN")\"]}"
}

register_domain() {
  local response
  log "正在购买 ${DOMAIN}。这可能会从 Cloudflare 账号默认付款方式扣费。"
  response="$(cf_api POST "/accounts/${ACCOUNT_ID}/registrar/registrations" "{\"domain_name\":\"$(json_escape "$DOMAIN")\"}")"
  printf '%s\n' "$response" | jq .
}

publish_domain() {
  local dns_provider="$1"
  local publish_ip="${2:-}"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] 将调用发布脚本: ${PUBLISH_SCRIPT}"
    log "[dry-run] 发布域名: ${DOMAIN}"
    log "[dry-run] 本机端口: ${LOCAL_PORT}"
    [[ -n "$publish_ip" ]] && log "[dry-run] 公网 IP: ${publish_ip}"
    return 0
  fi
  log "开始发布 ${DOMAIN}，调用脚本: ${PUBLISH_SCRIPT}"
  local -a args=(
    --domain "$DOMAIN"
    --local-port "$LOCAL_PORT"
    --dns-provider "$dns_provider"
  )
  [[ -n "$publish_ip" ]] && args+=(--public-ip "$publish_ip")
  [[ -n "$EMAIL" ]] && args+=(--email "$EMAIL")
  if [[ "$dns_provider" == "cloudflare" ]]; then
    CF_API_TOKEN="$CF_API_TOKEN" "$PUBLISH_SCRIPT" "${args[@]}"
  else
    "$PUBLISH_SCRIPT" "${args[@]}"
  fi
}

run_cloudflare_registrar() {
  validate_cloudflare_registrar

  if [[ -n "$QUERY" ]]; then
    search_domains
    return 0
  fi

  local check_response registrable price currency
  check_response="$(check_domain_raw)"
  printf '%s\n' "$check_response" | jq .
  registrable="$(printf '%s\n' "$check_response" | jq -r '.result.domains[0].registrable // false')"
  price="$(printf '%s\n' "$check_response" | jq -r '.result.domains[0].pricing.registration_cost // empty')"
  currency="$(printf '%s\n' "$check_response" | jq -r '.result.domains[0].pricing.currency // empty')"

  if [[ "$registrable" != "true" ]]; then
    die "${DOMAIN} 当前不可注册"
  fi

  log "${DOMAIN} 可以注册。注册价格: ${price:-未知} ${currency:-}"

  if [[ "$REGISTER" == "true" ]]; then
    register_domain
  else
    log "当前仅检查可用性。若要购买，请执行: $0 --provider cloudflare-registrar --domain ${DOMAIN} --register --yes"
  fi

  if [[ "$PUBLISH" == "true" ]]; then
    publish_domain cloudflare "$PUBLIC_IP"
  fi
}

dnshe_parts() {
  local domain="$DOMAIN"
  local root="$ROOTDOMAIN"
  local sub=""

  [[ -n "$domain" ]] || die "dnshe 需要指定 --domain，例如: --domain my-dev --rootdomain us.ci"
  if [[ -n "$root" ]]; then
    root="${root#.}"
    sub="${domain%.$root}"
    [[ "$sub" != "$domain" || "$domain" != *.* ]] || sub="$domain"
  elif [[ "$domain" == *.* ]]; then
    sub="${domain%%.*}"
    root="${domain#*.}"
  else
    die "dnshe 使用短名称时需要指定 --rootdomain，例如: --domain my-dev --rootdomain us.ci"
  fi

  sub="$(sanitize_name "$sub")"
  [[ -n "$sub" ]] || die "DNSHE 子域不能为空"
  [[ -n "$root" ]] || die "DNSHE 根域不能为空"
  [[ "$sub" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "DNSHE 子域必须是 1-63 位小写字母、数字或连字符"
  [[ "$root" =~ ^[A-Za-z0-9.-]+$ ]] || die "DNSHE 根域包含非法字符"
  printf '%s\n%s\n' "$sub" "$root"
}

dnshe_api() {
  local action="$1"
  shift
  local -a args=(
    --get "$DNSHE_API_ENDPOINT"
    --data-urlencode "action=${action}"
    --data-urlencode "key=${DNSHE_API_KEY}"
    --data-urlencode "secret=${DNSHE_API_SECRET}"
  )
  while [[ $# -gt 0 ]]; do
    args+=(--data-urlencode "$1")
    shift
  done
  curl -fsS "${args[@]}"
}

dnshe_response_ok() {
  local response="$1"
  if command -v jq >/dev/null 2>&1 && printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$response" | jq -e '(.success == true) or (.code == 0) or (.status == "success") or (.msg == "success")' >/dev/null 2>&1
    return $?
  fi
  printf '%s' "$response" | grep -Eiq 'success|ok|成功'
}

print_response() {
  local response="$1"
  if command -v jq >/dev/null 2>&1 && printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$response" | jq .
  else
    printf '%s\n' "$response"
  fi
}

run_dnshe() {
  [[ -n "$DNSHE_API_KEY" ]] || die "缺少 DNSHE_API_KEY。请在 DNSHE Client Area 创建 API Key。"
  [[ -n "$DNSHE_API_SECRET" ]] || die "缺少 DNSHE_API_SECRET。请在 DNSHE Client Area 创建 API Secret。"

  if [[ -n "$QUERY" ]]; then
    log "正在查询 DNSHE 当前账号域名，关键词: ${QUERY}"
    print_response "$(dnshe_api "$DNSHE_LIST_ACTION" "keyword=${QUERY}" "limit=${LIMIT}")"
    return 0
  fi

  local parts sub root full_domain response
  parts="$(dnshe_parts)"
  sub="$(printf '%s\n' "$parts" | sed -n '1p')"
  root="$(printf '%s\n' "$parts" | sed -n '2p')"
  full_domain="${sub}.${root}"
  DOMAIN="$full_domain"

  if [[ "$REGISTER" == "true" ]]; then
    [[ "$YES" == "true" ]] || die "DNSHE 创建免费子域会占用账号额度；确认后请加 --register --yes"
    log "正在通过 DNSHE 创建免费子域: ${full_domain}"
    response="$(dnshe_api "$DNSHE_REGISTER_ACTION" "domain=${sub}" "rootdomain=${root}")"
    print_response "$response"
    dnshe_response_ok "$response" || warn "DNSHE 注册响应未识别为成功，请根据上方返回内容确认。"
  else
    log "未指定 --register；不会创建 DNSHE 子域。若需要创建，请加 --register --yes。"
  fi

  if [[ -n "$PUBLIC_IP" || "$PUBLISH" == "true" ]]; then
    PUBLIC_IP="${PUBLIC_IP:-$(detect_public_ip)}"
    log "正在通过 DNSHE 写入 A 记录: ${full_domain} -> ${PUBLIC_IP}"
    response="$(dnshe_api "$DNSHE_RECORD_ACTION" "domain=${sub}" "rootdomain=${root}" "record_name=${DNSHE_RECORD_HOST}" "record_type=A" "record_value=${PUBLIC_IP}" "value=${PUBLIC_IP}" "ip=${PUBLIC_IP}")"
    print_response "$response"
    dnshe_response_ok "$response" || warn "DNSHE A 记录响应未识别为成功，请根据上方返回内容确认。必要时可通过 DNSHE_RECORD_ACTION 覆盖 action 名。"
  fi

  if [[ "$PUBLISH" == "true" ]]; then
    publish_domain manual "$PUBLIC_IP"
  else
    log "完成 DNSHE 配置。需要发布本机服务时可追加: --publish --local-port 3000 --email admin@example.com"
  fi
}

run_digitalplat() {
  local public_ip_example
  public_ip_example="$(public_ip_placeholder)"
  [[ -z "$QUERY" ]] || die "digitalplat 当前为配置向导模式，不支持 --search"
  [[ "$REGISTER" == "false" ]] || die "digitalplat 当前不支持脚本自动注册；请使用 Dashboard 申请域名"
  cat <<EOF
DigitalPlat 免费域名配置向导

适用场景:
  DigitalPlat/DigitalPlat FreeDomain 提供 qzz.io、dpdns.org、us.kg、xx.kg、qd.je 等免费命名空间。
  注册通常需要登录 Dashboard 申请域名，并将 DNS 托管到你自己的 nameserver 或支持的 DNS 服务。

建议步骤:
  1. 打开 DigitalPlat Dashboard，申请域名: ${DOMAIN:-my-dev.dpdns.org}
  2. DNS 记录添加 A 记录:
       主机记录: @ 或你的子域前缀
       记录值: ${public_ip_example}
  3. 本机发布服务:
       export PUBLIC_FRPS_IP='你的公网 frps 服务器 IP'
       ${PUBLISH_SCRIPT} --domain ${DOMAIN:-my-dev.dpdns.org} --public-ip "\${PUBLIC_FRPS_IP}" --local-port 3000 --dns-provider manual --email admin@example.com

说明:
  该 provider 不模拟网页登录，不保存账号密码，不自动提交注册表单。
  如果 DigitalPlat 后续提供稳定公开 API，可用环境变量和脚本函数继续扩展为自动注册。
EOF
}

run_euorg() {
  local public_ip_example
  public_ip_example="$(public_ip_placeholder)"
  [[ -z "$QUERY" ]] || die "euorg 当前为配置向导模式，不支持 --search"
  [[ "$REGISTER" == "false" ]] || die "EU.org 需要人工审核，不支持脚本自动注册；请按向导提交申请"
  cat <<EOF
EU.org 免费子域配置向导

适用场景:
  EU.org 免费子域适合长期项目，但申请前通常需要先准备可用 nameserver，并等待人工审核。

建议步骤:
  1. 先准备 DNS 托管服务，例如 Cloudflare、HE.net DNS、DigitalPlat DNS 或其他权威 DNS。
  2. 在 DNS 托管服务中添加域名 zone: ${DOMAIN:-my-dev.eu.org}
  3. 添加 A 记录:
       主机记录: @
       记录值: ${public_ip_example}
  4. 到 EU.org 提交申请，并填写上一步准备好的 nameserver。
  5. 审核通过、DNS 生效后发布本机服务:
       export PUBLIC_FRPS_IP='你的公网 frps 服务器 IP'
       ${PUBLISH_SCRIPT} --domain ${DOMAIN:-my-dev.eu.org} --public-ip "\${PUBLIC_FRPS_IP}" --local-port 3000 --dns-provider manual --email admin@example.com

说明:
  EU.org 不是即时注册 API 服务，脚本只输出可执行配置步骤。
EOF
}

duckdns_domain() {
  local name="${DOMAIN%.duckdns.org}"
  name="$(sanitize_name "$name")"
  [[ -n "$name" ]] || die "duckdns 需要指定 --domain"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "DuckDNS 名称必须是 1-63 位小写字母、数字或连字符"
  printf '%s.duckdns.org\n' "$name"
}

load_duckdns_config() {
  [[ -r "$DUCKDNS_CONFIG" ]] || return 0
  local config domain token
  config="$(sed -n '1,80p' "$DUCKDNS_CONFIG")"
  if [[ -z "$DOMAIN" ]]; then
    domain="$(printf '%s\n' "$config" | sed -n 's/.*[?&]domains=\([^&" ]*\).*/\1/p' | head -1)"
    if [[ -n "$domain" ]]; then
      DOMAIN="${domain%%,*}"
      log "已从 ${DUCKDNS_CONFIG} 读取 DuckDNS 域名: ${DOMAIN}.duckdns.org"
    fi
  fi
  if [[ -z "$DUCKDNS_TOKEN" ]]; then
    token="$(printf '%s\n' "$config" | sed -n 's/.*[?&]token=\([^&" ]*\).*/\1/p' | head -1)"
    if [[ -n "$token" ]]; then
      DUCKDNS_TOKEN="$token"
      log "已从 ${DUCKDNS_CONFIG} 读取 DuckDNS token"
    fi
  fi
}

run_duckdns() {
  load_duckdns_config
  [[ -n "$DOMAIN" ]] || die "duckdns 需要指定 --domain，例如: --domain yuanhangzhe，或提供可读取的 DUCKDNS_CONFIG=${DUCKDNS_CONFIG}"
  [[ -n "$DUCKDNS_TOKEN" ]] || die "缺少 --duckdns-token 或 DUCKDNS_TOKEN。请在 https://www.duckdns.org 登录后复制 token。"
  [[ -z "$QUERY" ]] || die "duckdns 不支持 --search"
  [[ "$REGISTER" == "false" ]] || die "duckdns 不支持 --register；添加/更新子域由 DuckDNS token 完成"

  DOMAIN="$(duckdns_domain)"
  PUBLIC_IP="${PUBLIC_IP:-$(detect_public_ip)}"
  local subdomain response
  subdomain="${DOMAIN%.duckdns.org}"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] 将更新 DuckDNS: ${DOMAIN} -> ${PUBLIC_IP}"
    if [[ "$PUBLISH" == "true" ]]; then
      publish_domain manual "$PUBLIC_IP"
    fi
    return 0
  fi
  log "正在更新 DuckDNS: ${DOMAIN} -> ${PUBLIC_IP}"
  response="$(curl -fsS "https://www.duckdns.org/update?domains=$(urlencode "$subdomain")&token=$(urlencode "$DUCKDNS_TOKEN")&ip=$(urlencode "$PUBLIC_IP")")"
  [[ "$response" == "OK" ]] || die "DuckDNS 更新失败: ${response}"
  log "DuckDNS 更新成功: https://${DOMAIN}"
  log "DNS 生效后可访问该域名；如使用 --publish，会继续配置 nginx/frp/证书。"

  if [[ "$PUBLISH" == "true" ]]; then
    publish_domain manual "$PUBLIC_IP"
  fi
}

run_freedns() {
  [[ -n "$DOMAIN" ]] || die "freedns 需要指定 --domain"
  [[ -n "$FREEDNS_UPDATE_URL" ]] || die "缺少 --freedns-update-url 或 FREEDNS_UPDATE_URL。请在 FreeDNS Dynamic DNS 页面复制 Direct URL。"
  [[ -z "$QUERY" ]] || die "freedns 不支持 --search"
  [[ "$REGISTER" == "false" ]] || die "freedns 不支持 --register；请先在 FreeDNS 后台创建子域"
  if [[ "$PUBLISH" == "true" && -z "$PUBLIC_IP" && "$FREEDNS_UPDATE_URL" != *'address='* ]]; then
    die "--publish 需要 --public-ip，除非 --freedns-update-url 已包含 address="
  fi

  log "正在更新 FreeDNS 动态 DNS: ${DOMAIN}"
  local response update_url
  update_url="$FREEDNS_UPDATE_URL"
  if [[ -n "$PUBLIC_IP" && "$update_url" != *'address='* ]]; then
    case "$update_url" in
      *\?*) update_url="${update_url}&address=$(urlencode "$PUBLIC_IP")" ;;
      *) update_url="${update_url}?address=$(urlencode "$PUBLIC_IP")" ;;
    esac
  fi
  response="$(curl -fsS "$update_url")"
  printf '%s\n' "$response"
  log "FreeDNS 更新请求完成；请根据上方 FreeDNS 返回内容确认是否成功。"

  if [[ "$PUBLISH" == "true" ]]; then
    publish_domain manual "$PUBLIC_IP"
  fi
}

cloudflared_bin() {
  if command -v cloudflared >/dev/null 2>&1; then
    command -v cloudflared
  elif [[ -x "$HOME/.local/bin/cloudflared" ]]; then
    printf '%s\n' "$HOME/.local/bin/cloudflared"
  else
    return 1
  fi
}

install_cloudflared() {
  local os arch asset url tmp_dir archive bin
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}/${arch}" in
    Darwin/arm64) asset="cloudflared-darwin-arm64.tgz" ;;
    Darwin/x86_64) asset="cloudflared-darwin-amd64.tgz" ;;
    Linux/x86_64) asset="cloudflared-linux-amd64" ;;
    Linux/aarch64|Linux/arm64) asset="cloudflared-linux-arm64" ;;
    *) die "当前平台不支持自动安装 cloudflared: ${os}/${arch}" ;;
  esac

  url="https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}"
  mkdir -p "$HOME/.local/bin"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  log "正在安装 cloudflared 到 ${HOME}/.local/bin"
  log "下载地址: ${url}"
  if [[ "$asset" == *.tgz ]]; then
    archive="${tmp_dir}/${asset}"
    curl -fL "$url" -o "$archive"
    tar -xzf "$archive" -C "$tmp_dir"
    bin="$(find "$tmp_dir" -type f -name cloudflared -perm -u+x | head -1)"
    [[ -n "$bin" ]] || bin="$(find "$tmp_dir" -type f -name cloudflared | head -1)"
    [[ -n "$bin" ]] || die "cloudflared 压缩包中未找到可执行文件"
    cp "$bin" "$HOME/.local/bin/cloudflared"
  else
    curl -fL "$url" -o "$HOME/.local/bin/cloudflared"
  fi
  chmod +x "$HOME/.local/bin/cloudflared"
  "$HOME/.local/bin/cloudflared" --version
}

extract_trycloudflare_url() {
  local log_file="$1"
  grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$log_file" | tail -1 || true
}

run_trycloudflare() {
  [[ -n "$LOCAL_PORT" ]] || die "trycloudflare 需要指定 --local-port"
  [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || die "--local-port 必须是数字"
  [[ "$PUBLISH" == "false" ]] || die "trycloudflare 不需要 --publish；Cloudflare 会直接提供 HTTPS 地址"
  [[ -z "$DOMAIN" ]] || warn "trycloudflare 会忽略 --domain；Cloudflare 会分配随机 trycloudflare.com 地址"
  local bin target
  bin="$(cloudflared_bin || true)"
  if [[ -z "$bin" ]]; then
    install_cloudflared
    bin="$(cloudflared_bin)" || die "cloudflared 安装完成后仍未找到可执行文件"
  fi
  target="http://${LOCAL_IP}:${LOCAL_PORT}"
  if [[ -f "$HOME/.cloudflared/config.yaml" || -f "$HOME/.cloudflared/config.yml" ]]; then
    warn "检测到 ~/.cloudflared/config.yaml 或 config.yml；Quick Tunnel 启动失败时请临时改名后重试"
  fi

  if [[ "$BACKGROUND" == "true" ]]; then
    TUNNEL_LOG="${TUNNEL_LOG:-${HOME}/.local/state/dev-domain/trycloudflare-${LOCAL_PORT}.log}"
    mkdir -p "$(dirname "$TUNNEL_LOG")"
    : > "$TUNNEL_LOG"
    log "后台启动 Cloudflare Quick Tunnel: ${target}"
    nohup "$bin" tunnel --url "$target" >"$TUNNEL_LOG" 2>&1 &
    local pid="$!"
    local url=""
    for _ in {1..40}; do
      url="$(extract_trycloudflare_url "$TUNNEL_LOG")"
      [[ -n "$url" ]] && break
      sleep 0.5
    done
    if [[ -n "$url" ]]; then
      log "隧道进程 PID: ${pid}"
      log "公网 HTTPS 地址: ${url}"
      log "日志文件: ${TUNNEL_LOG}"
    else
      warn "隧道已启动，PID: ${pid}，但暂未解析到 URL。请查看日志: ${TUNNEL_LOG}"
    fi
  else
    log "前台启动 Cloudflare Quick Tunnel: ${target}"
    exec "$bin" tunnel --url "$target"
  fi
}

main() {
  parse_args "$@"
  validate_common

  case "$PROVIDER" in
    cloudflare-registrar) run_cloudflare_registrar ;;
    dnshe) run_dnshe ;;
    duckdns) run_duckdns ;;
    freedns) run_freedns ;;
    trycloudflare) run_trycloudflare ;;
    digitalplat) run_digitalplat ;;
    euorg) run_euorg ;;
  esac
}

main "$@"
