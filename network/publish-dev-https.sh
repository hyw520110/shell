#!/usr/bin/env bash
# Publish a development service through nginx + optional frp and request a public certificate.
# This script assumes the domain already exists. Domain registration/purchase needs a registrar API.

set -euo pipefail

DOMAIN=""
NAME=""
LOCAL_IP="127.0.0.1"
LOCAL_PORT=""
UPSTREAM_HOST=""
FRP_LOCAL_IP="127.0.0.1"
EMAIL=""
DNS_PROVIDER="manual"
PUBLIC_IP=""
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_PROXIED=false
NGINX_HOME="${HOME}/nginx"
FRP_HOME="${HOME}/frp"
REMOTE_HTTPS_PORT=443
FRP_MODE="auto"
LE_CONFIG="${HOME}/.local/share/letsencrypt/config"
LE_WORK="${HOME}/.local/share/letsencrypt/work"
LE_LOGS="${HOME}/.local/share/letsencrypt/logs"
SKIP_CERT=false
STAGING=false
NO_FRP=false
NO_RELOAD=false

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  $0 --domain DOMAIN --local-port PORT [options]

Options:
  --domain DOMAIN        Public domain, e.g. dev.example.com
  --local-port PORT      Local development service port on studio
  --local-ip IP          Local service IP, default: 127.0.0.1
  --upstream-host HOST   Host header sent to upstream. Useful when proxying to an existing local nginx.
  --name NAME            Config/proxy name, default: sanitized domain
  --email EMAIL          Let's Encrypt email. If omitted, certbot uses register-unsafely-without-email.
  --dns-provider NAME    DNS automation provider: manual, cloudflare. Default: manual
  --public-ip IP         Public IP for DNS A record, e.g. frps server IP
  --cf-api-token TOKEN   Cloudflare API token. Or set CF_API_TOKEN
  --cf-zone-id ID        Cloudflare zone ID. Optional; auto-detected when token can list zones
  --cf-proxied           Create Cloudflare proxied record. Default: DNS-only
  --frp-local-ip IP      frpc localIP for nginx 443, default: 127.0.0.1
  --remote-https-port P  Public frps HTTPS TCP port, default: 443
  --frp-mode MODE        auto, https-vhost, tcp. Default: auto
  --nginx-home DIR       Nginx home, default: ~/nginx
  --frp-home DIR         FRP home, default: ~/frp
  --letsencrypt-dir DIR  Certbot config dir, default: ~/.local/share/letsencrypt/config
  --skip-cert            Only write nginx/frp config; do not request certificate
  --staging              Use Let's Encrypt staging endpoint
  --no-frp               Do not update/restart frpc
  --no-reload            Do not reload nginx
  -h, --help             Show help

Example:
  $0 --domain dev.example.com --local-port 3000 --email admin@example.com
  $0 --domain dev.example.com --local-port 3000 --public-ip 13.229.209.133 --dns-provider cloudflare --email admin@example.com
  $0 --domain dev.example.com --local-port 80 --upstream-host localhost --public-ip 13.229.209.133 --email admin@example.com
EOF
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --domain=*) DOMAIN="${1#*=}"; shift ;;
      --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
      --local-port=*) LOCAL_PORT="${1#*=}"; shift ;;
      --local-ip) LOCAL_IP="${2:-}"; shift 2 ;;
      --local-ip=*) LOCAL_IP="${1#*=}"; shift ;;
      --upstream-host) UPSTREAM_HOST="${2:-}"; shift 2 ;;
      --upstream-host=*) UPSTREAM_HOST="${1#*=}"; shift ;;
      --name) NAME="${2:-}"; shift 2 ;;
      --name=*) NAME="${1#*=}"; shift ;;
      --email) EMAIL="${2:-}"; shift 2 ;;
      --email=*) EMAIL="${1#*=}"; shift ;;
      --dns-provider) DNS_PROVIDER="${2:-}"; shift 2 ;;
      --dns-provider=*) DNS_PROVIDER="${1#*=}"; shift ;;
      --public-ip) PUBLIC_IP="${2:-}"; shift 2 ;;
      --public-ip=*) PUBLIC_IP="${1#*=}"; shift ;;
      --cf-api-token) CF_API_TOKEN="${2:-}"; shift 2 ;;
      --cf-api-token=*) CF_API_TOKEN="${1#*=}"; shift ;;
      --cf-zone-id) CF_ZONE_ID="${2:-}"; shift 2 ;;
      --cf-zone-id=*) CF_ZONE_ID="${1#*=}"; shift ;;
      --cf-proxied) CF_PROXIED=true; shift ;;
      --frp-local-ip) FRP_LOCAL_IP="${2:-}"; shift 2 ;;
      --frp-local-ip=*) FRP_LOCAL_IP="${1#*=}"; shift ;;
      --remote-https-port) REMOTE_HTTPS_PORT="${2:-}"; shift 2 ;;
      --remote-https-port=*) REMOTE_HTTPS_PORT="${1#*=}"; shift ;;
      --frp-mode) FRP_MODE="${2:-}"; shift 2 ;;
      --frp-mode=*) FRP_MODE="${1#*=}"; shift ;;
      --nginx-home) NGINX_HOME="${2:-}"; shift 2 ;;
      --nginx-home=*) NGINX_HOME="${1#*=}"; shift ;;
      --frp-home) FRP_HOME="${2:-}"; shift 2 ;;
      --frp-home=*) FRP_HOME="${1#*=}"; shift ;;
      --letsencrypt-dir) LE_CONFIG="${2:-}"; shift 2 ;;
      --letsencrypt-dir=*) LE_CONFIG="${1#*=}"; shift ;;
      --skip-cert) SKIP_CERT=true; shift ;;
      --staging) STAGING=true; shift ;;
      --no-frp) NO_FRP=true; shift ;;
      --no-reload) NO_RELOAD=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

validate_args() {
  [[ -n "$DOMAIN" ]] || die "--domain is required"
  [[ -n "$LOCAL_PORT" ]] || die "--local-port is required"
  [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || die "--local-port must be numeric"
  [[ "$REMOTE_HTTPS_PORT" =~ ^[0-9]+$ ]] || die "--remote-https-port must be numeric"
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "--domain contains invalid characters"
  case "$DNS_PROVIDER" in
    manual|cloudflare) ;;
    *) die "Unsupported --dns-provider: ${DNS_PROVIDER}" ;;
  esac
  case "$FRP_MODE" in
    auto|https-vhost|tcp) ;;
    *) die "Unsupported --frp-mode: ${FRP_MODE}" ;;
  esac
  if [[ "$DNS_PROVIDER" != "manual" && -z "$PUBLIC_IP" ]]; then
    die "--public-ip is required when --dns-provider is not manual"
  fi
  NAME="${NAME:-$(sanitize_name "$DOMAIN")}"
  [[ -n "$NAME" ]] || die "Cannot derive --name from domain"
  [[ "$NAME" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "--name contains invalid characters"
  NGINX_HOME="${NGINX_HOME%/}"
  FRP_HOME="${FRP_HOME%/}"
  LE_CONFIG="${LE_CONFIG%/}"
  LE_WORK="${LE_CONFIG%/config}/work"
  LE_LOGS="${LE_CONFIG%/config}/logs"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

domain_parent_candidates() {
  local domain="$1"
  local rest="$domain"
  while [[ "$rest" == *.* ]]; do
    printf '%s\n' "$rest"
    rest="${rest#*.}"
  done
}

cloudflare_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local -a args=(-fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=("--data" "$data")
  curl "${args[@]}"
}

cloudflare_zone_id() {
  if [[ -n "$CF_ZONE_ID" ]]; then
    printf '%s\n' "$CF_ZONE_ID"
    return 0
  fi

  command -v jq >/dev/null 2>&1 || die "jq is required for Cloudflare DNS automation"
  local candidate response id
  while IFS= read -r candidate; do
    response="$(cloudflare_api GET "/zones?name=${candidate}&status=active")"
    id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"
    if [[ -n "$id" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done < <(domain_parent_candidates "$DOMAIN")

  die "Cannot find Cloudflare zone for ${DOMAIN}; pass --cf-zone-id explicitly"
}

upsert_cloudflare_dns() {
  [[ -n "$CF_API_TOKEN" ]] || die "Cloudflare DNS automation requires --cf-api-token or CF_API_TOKEN"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"

  local zone_id record_id payload response proxied_json
  zone_id="$(cloudflare_zone_id)"
  record_id="$(cloudflare_api GET "/zones/${zone_id}/dns_records?type=A&name=${DOMAIN}" | jq -r '.result[0].id // empty')"
  proxied_json="false"
  [[ "$CF_PROXIED" == "true" ]] && proxied_json="true"
  payload="{\"type\":\"A\",\"name\":\"$(json_escape "$DOMAIN")\",\"content\":\"$(json_escape "$PUBLIC_IP")\",\"ttl\":1,\"proxied\":${proxied_json}}"

  if [[ -n "$record_id" ]]; then
    response="$(cloudflare_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload")"
    printf '%s' "$response" | jq -e '.success == true' >/dev/null || die "Cloudflare DNS update failed: ${response}"
    log "Updated Cloudflare A record: ${DOMAIN} -> ${PUBLIC_IP}"
  else
    response="$(cloudflare_api POST "/zones/${zone_id}/dns_records" "$payload")"
    printf '%s' "$response" | jq -e '.success == true' >/dev/null || die "Cloudflare DNS create failed: ${response}"
    log "Created Cloudflare A record: ${DOMAIN} -> ${PUBLIC_IP}"
  fi
}

configure_dns() {
  case "$DNS_PROVIDER" in
    manual)
      return 0
      ;;
    cloudflare)
      upsert_cloudflare_dns
      ;;
  esac
}

find_nginx_bin() {
  if [[ -x "${NGINX_HOME}/sbin/nginx" ]]; then
    printf '%s\n' "${NGINX_HOME}/sbin/nginx"
  elif command -v nginx >/dev/null 2>&1; then
    command -v nginx
  else
    return 1
  fi
}

nginx_bin() {
  find_nginx_bin || die "nginx not found; expected ${NGINX_HOME}/sbin/nginx"
}

write_nginx_conf() {
  local cert_ready="$1"
  local proxy_host_header
  local conf_dir="${NGINX_HOME}/conf/conf.d"
  local acme_root="${NGINX_HOME}/html/.well-known-acme"
  local conf_file="${conf_dir}/dev-${NAME}.conf"
  local cert_dir="${LE_CONFIG}/live/${DOMAIN}"
  proxy_host_header="\$host"
  [[ -n "$UPSTREAM_HOST" ]] && proxy_host_header="$UPSTREAM_HOST"

  mkdir -p "$conf_dir" "$acme_root"
  if [[ -f "$conf_file" ]]; then
    cp "$conf_file" "${conf_file}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  if [[ "$cert_ready" == "true" ]]; then
    cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${acme_root};
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://${LOCAL_IP}:${LOCAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host ${proxy_host_header};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
EOF
  else
    cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${acme_root};
        default_type text/plain;
    }

    location / {
        proxy_pass http://${LOCAL_IP}:${LOCAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host ${proxy_host_header};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
EOF
  fi

  log "Wrote nginx config: $conf_file"
}

reload_nginx() {
  [[ "$NO_RELOAD" == "true" ]] && return 0
  local bin
  bin="$(nginx_bin)"
  "$bin" -t -c "${NGINX_HOME}/conf/nginx.conf"
  if pgrep -f "${bin}.*${NGINX_HOME}/conf/nginx.conf" >/dev/null 2>&1 || pgrep -f "nginx: master" >/dev/null 2>&1; then
    "$bin" -s reload -c "${NGINX_HOME}/conf/nginx.conf"
  else
    "$bin" -c "${NGINX_HOME}/conf/nginx.conf"
  fi
  log "Nginx reloaded"
}

certbot_display_cmd() {
  if command -v certbot >/dev/null 2>&1; then
    printf 'certbot'
  elif [[ -x "${HOME}/.local/bin/certbot" ]]; then
    shell_quote "${HOME}/.local/bin/certbot"
  elif command -v uvx >/dev/null 2>&1; then
    printf 'uvx certbot'
  elif [[ -x "${HOME}/.local/bin/uvx" ]]; then
    printf '%s certbot' "$(shell_quote "${HOME}/.local/bin/uvx")"
  else
    printf 'certbot'
  fi
}

run_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    certbot "$@"
  elif [[ -x "${HOME}/.local/bin/certbot" ]]; then
    "${HOME}/.local/bin/certbot" "$@"
  elif command -v uvx >/dev/null 2>&1; then
    uvx certbot "$@"
  elif [[ -x "${HOME}/.local/bin/uvx" ]]; then
    "${HOME}/.local/bin/uvx" certbot "$@"
  else
    die "certbot not found. Install certbot or uv/uvx first, or rerun with --skip-cert."
  fi
}

frpc_has_remote_port() {
  local port="$1"
  [[ -f "${FRP_HOME}/frpc.toml" ]] || return 1
  grep -Eq "^[[:space:]]*remotePort[[:space:]]*=[[:space:]]*${port}([[:space:]]|$)" "${FRP_HOME}/frpc.toml"
}

frpc_has_custom_domain() {
  local domain="$1"
  [[ -f "${FRP_HOME}/frpc.toml" ]] || return 1
  grep -Eq "customDomains[[:space:]]*=[[:space:]]*\\[.*\"${domain}\".*\\]" "${FRP_HOME}/frpc.toml"
}

frpc_server_addr() {
  local conf="${FRP_HOME}/frpc.toml"
  awk -F= '/^[[:space:]]*serverAddr[[:space:]]*=/{gsub(/[ "]/, "", $2); print $2; exit}' "$conf"
}

remote_port_is_open() {
  local host="$1"
  local port="$2"
  [[ -n "$host" ]] || return 1
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1
  else
    return 1
  fi
}

effective_frp_mode() {
  if [[ "$FRP_MODE" != "auto" ]]; then
    printf '%s\n' "$FRP_MODE"
  elif [[ "$REMOTE_HTTPS_PORT" == "443" ]]; then
    printf 'https-vhost\n'
  else
    printf 'tcp\n'
  fi
}

frpc_has_proxy_name() {
  local name="$1"
  [[ -f "${FRP_HOME}/frpc.toml" ]] || return 1
  grep -Eq "^[[:space:]]*name[[:space:]]*=[[:space:]]*\"${name}\"" "${FRP_HOME}/frpc.toml"
}

ensure_frpc_https() {
  [[ "$NO_FRP" == "true" ]] && return 0
  local conf="${FRP_HOME}/frpc.toml"
  local mode proxy_name server_addr
  [[ -f "$conf" ]] || die "frpc config not found: $conf"
  mode="$(effective_frp_mode)"
  proxy_name="dev_${NAME}_${mode}_${REMOTE_HTTPS_PORT}"

  if frpc_has_proxy_name "$proxy_name"; then
    log "frpc proxy already exists: $proxy_name"
    return 0
  fi

  if [[ "$mode" == "https-vhost" ]]; then
    if frpc_has_custom_domain "$DOMAIN"; then
      log "frpc already has HTTPS vhost customDomains entry for ${DOMAIN}"
      return 0
    fi

    cp "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
    cat >> "$conf" <<EOF

# HTTPS vhost for ${DOMAIN}: public frps :${REMOTE_HTTPS_PORT} -> studio nginx :443
[[proxies]]
name = "${proxy_name}"
type = "https"
localIP = "${FRP_LOCAL_IP}"
localPort = 443
customDomains = ["${DOMAIN}"]
transport.useEncryption = true
transport.useCompression = true
EOF
    log "Added frpc HTTPS vhost proxy: $proxy_name"
    restart_frpc
    return 0
  fi

  if frpc_has_remote_port "$REMOTE_HTTPS_PORT"; then
    log "frpc already has remotePort = ${REMOTE_HTTPS_PORT}; reuse existing mapping"
    return 0
  fi
  server_addr="$(frpc_server_addr)"
  if remote_port_is_open "$server_addr" "$REMOTE_HTTPS_PORT"; then
    die "Public ${server_addr}:${REMOTE_HTTPS_PORT} is already open but not managed by this frpc.toml. Use --remote-https-port 7443 or free public port ${REMOTE_HTTPS_PORT} first."
  fi

  cp "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
  cat >> "$conf" <<EOF

# HTTPS for ${DOMAIN}: public :${REMOTE_HTTPS_PORT} -> studio nginx :443
[[proxies]]
name = "${proxy_name}"
type = "tcp"
localIP = "${FRP_LOCAL_IP}"
localPort = 443
remotePort = ${REMOTE_HTTPS_PORT}
transport.useEncryption = true
transport.useCompression = true
EOF
  log "Added frpc HTTPS proxy: $proxy_name"
  restart_frpc
}

restart_frpc() {
  [[ "$NO_FRP" == "true" ]] && return 0
  [[ -x "${FRP_HOME}/frpc" ]] || die "frpc binary not found: ${FRP_HOME}/frpc"

  local pids
  pids="$(pgrep -f "${FRP_HOME}/frpc -c ${FRP_HOME}/frpc.toml" || true)"
  if [[ -n "$pids" ]]; then
    log "Stopping frpc: $pids"
    kill $pids
    sleep 2
  fi

  log "Starting frpc"
  "${FRP_HOME}/frpc" -c "${FRP_HOME}/frpc.toml" > "${FRP_HOME}/frpc.log" 2>&1 &
  sleep 2
  pgrep -f "${FRP_HOME}/frpc -c ${FRP_HOME}/frpc.toml" >/dev/null || {
    tail -80 "${FRP_HOME}/frpc.log" >&2 || true
    die "frpc failed to start"
  }
}

request_certificate() {
  [[ "$SKIP_CERT" == "true" ]] && return 0

  mkdir -p "$LE_CONFIG" "$LE_WORK" "$LE_LOGS"
  local acme_root="${NGINX_HOME}/html/.well-known-acme"
  local -a args=(
    certonly
    --webroot
    -w "$acme_root"
    -d "$DOMAIN"
    --agree-tos
    --non-interactive
    --config-dir "$LE_CONFIG"
    --work-dir "$LE_WORK"
    --logs-dir "$LE_LOGS"
  )

  if [[ -n "$EMAIL" ]]; then
    args+=(--email "$EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  [[ "$STAGING" == "true" ]] && args+=(--staging)

  log "Requesting certificate for ${DOMAIN}"
  run_certbot "${args[@]}"
}

print_summary() {
  local renew_cmd nginx_reload_bin
  renew_cmd="$(certbot_display_cmd) renew --config-dir $(shell_quote "$LE_CONFIG") --work-dir $(shell_quote "$LE_WORK") --logs-dir $(shell_quote "$LE_LOGS")"
  if nginx_reload_bin="$(find_nginx_bin 2>/dev/null)"; then
    renew_cmd="${renew_cmd} --deploy-hook \"$(shell_quote "$nginx_reload_bin") -s reload -c $(shell_quote "${NGINX_HOME}/conf/nginx.conf")\""
  fi

  cat <<EOF

Done.

DNS required:
  ${DOMAIN} A/AAAA -> ${PUBLIC_IP:-your frps public IP}

Public URL:
  https://${DOMAIN}$([[ "$REMOTE_HTTPS_PORT" == "443" ]] || printf ':%s' "$REMOTE_HTTPS_PORT")/

Google OAuth callback example:
  https://${DOMAIN}$([[ "$REMOTE_HTTPS_PORT" == "443" ]] || printf ':%s' "$REMOTE_HTTPS_PORT")/api/oauth/google/callback

Renew command:
  ${renew_cmd}
EOF
}

main() {
  parse_args "$@"
  validate_args

  log "Domain: ${DOMAIN}"
  log "Upstream: http://${LOCAL_IP}:${LOCAL_PORT}"
  log "Nginx home: ${NGINX_HOME}"
  log "FRP home: ${FRP_HOME}"

  configure_dns
  write_nginx_conf false
  reload_nginx

  if [[ "$SKIP_CERT" != "true" ]]; then
    request_certificate
    write_nginx_conf true
    reload_nginx
    ensure_frpc_https
  else
    warn "Skipped certificate request; HTTPS server block was not enabled"
  fi

  print_summary
}

main "$@"
