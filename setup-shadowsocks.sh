#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SS_PORT="${SS_PORT:-8388}"
SS_METHOD="${SS_METHOD:-chacha20-ietf-poly1305}"
SS_PASSWORD="${SS_PASSWORD:-}"
SS_NODE_NAME="${SS_NODE_NAME:-vps-ss}"
SS_CONFIG="/etc/shadowsocks-libev/config.json"
SS_SERVICE="shadowsocks-custom"
SS_OUTPUT="/root/shadowsocks-client-info.txt"
FORCE="${FORCE:-0}"
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP:-}"

log() {
  printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2
}

warn() {
  printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

validate_port() {
  [[ "$SS_PORT" =~ ^[0-9]+$ ]] || die "SS_PORT must be a number."
  (( SS_PORT >= 1 && SS_PORT <= 65535 )) || die "SS_PORT must be between 1 and 65535."
}

validate_ipv4() {
  local ip="$1"
  local octet
  local -a octets
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
}

validate_inputs() {
  validate_port
  [[ "$SS_METHOD" =~ ^[A-Za-z0-9._-]+$ ]] || die "SS_METHOD contains invalid characters."
  [[ "$SS_NODE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "SS_NODE_NAME must use letters, numbers, dots, underscores, or hyphens."
  if [[ -n "$SS_PASSWORD" && ! "$SS_PASSWORD" =~ ^[A-Za-z0-9._~@%+=:,/-]+$ ]]; then
    die "SS_PASSWORD contains unsupported characters. Use letters, numbers, and ._~@%+=:,/-"
  fi
}

ensure_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run this script as root, for example: sudo bash setup-shadowsocks.sh"
}

ensure_supported_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS. This script supports Ubuntu/Debian only."
  # shellcheck disable=SC1091
  source /etc/os-release

  local os_family="${ID:-} ${ID_LIKE:-}"
  if [[ "$os_family" != *ubuntu* && "$os_family" != *debian* ]]; then
    die "Unsupported OS '${PRETTY_NAME:-unknown}'. This script supports Ubuntu/Debian only."
  fi

  command -v apt-get >/dev/null 2>&1 || die "apt-get was not found. This script supports Ubuntu/Debian only."
  command -v systemctl >/dev/null 2>&1 || die "systemctl was not found. Please run this on a normal Ubuntu/Debian VPS with systemd."
}

prepare_existing_config() {
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"

  if [[ ! -f "$SS_CONFIG" && ! -f "/etc/systemd/system/${SS_SERVICE}.service" ]]; then
    return
  fi

  if [[ "$FORCE" != "1" ]]; then
    die "$SS_CONFIG or ${SS_SERVICE}.service already exists. Re-run with FORCE=1 to back it up and rebuild."
  fi

  warn "Existing Shadowsocks config found. FORCE=1 enabled, backing up and rebuilding."
  systemctl disable --now "$SS_SERVICE" >/dev/null 2>&1 || true
  [[ -f "$SS_CONFIG" ]] && cp -a "$SS_CONFIG" "${SS_CONFIG}.bak.${timestamp}"
  [[ -f "/etc/systemd/system/${SS_SERVICE}.service" ]] && cp -a "/etc/systemd/system/${SS_SERVICE}.service" "/etc/systemd/system/${SS_SERVICE}.service.bak.${timestamp}"
}

install_packages() {
  log "Installing Shadowsocks and helper tools..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y shadowsocks-libev curl ca-certificates openssl qrencode
}

detect_public_ipv4() {
  local ip=""

  if [[ -n "$SERVER_PUBLIC_IP" ]]; then
    validate_ipv4 "$SERVER_PUBLIC_IP" || die "SERVER_PUBLIC_IP is not a valid IPv4 address."
    printf '%s' "$SERVER_PUBLIC_IP"
    return
  fi

  log "Detecting public IPv4 address..."
  ip="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  if ! validate_ipv4 "$ip"; then
    ip="$(curl -4fsS --max-time 10 https://ifconfig.me/ip || true)"
  fi
  validate_ipv4 "$ip" || die "Could not detect public IPv4. Re-run with SERVER_PUBLIC_IP=x.x.x.x."

  printf '%s' "$ip"
}

ensure_password() {
  if [[ -z "$SS_PASSWORD" ]]; then
    SS_PASSWORD="$(openssl rand -hex 16)"
  fi
}

write_config() {
  install -d -m 755 /etc/shadowsocks-libev
  cat >"$SS_CONFIG" <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${SS_PORT},
  "password": "${SS_PASSWORD}",
  "timeout": 300,
  "method": "${SS_METHOD}",
  "mode": "tcp_and_udp",
  "fast_open": false
}
EOF
  chmod 600 "$SS_CONFIG"
}

write_service() {
  cat >"/etc/systemd/system/${SS_SERVICE}.service" <<EOF
[Unit]
Description=Shadowsocks-libev Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ss-server -c ${SS_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

open_firewall_port_if_needed() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log "Allowing Shadowsocks port ${SS_PORT} in UFW..."
    ufw allow "${SS_PORT}/tcp"
    ufw allow "${SS_PORT}/udp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log "Allowing Shadowsocks port ${SS_PORT} in firewalld..."
    firewall-cmd --add-port="${SS_PORT}/tcp" --permanent
    firewall-cmd --add-port="${SS_PORT}/udp" --permanent
    firewall-cmd --reload
  fi
}

start_service() {
  log "Starting Shadowsocks service..."
  systemctl enable --now "$SS_SERVICE"
}

make_ss_uri() {
  local server_ip="$1"
  local userinfo
  local encoded

  userinfo="${SS_METHOD}:${SS_PASSWORD}"
  encoded="$(printf '%s' "$userinfo" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
  printf 'ss://%s@%s:%s#%s' "$encoded" "$server_ip" "$SS_PORT" "$SS_NODE_NAME"
}

write_client_info() {
  local server_ip="$1"
  local ss_uri="$2"

  cat >"$SS_OUTPUT" <<EOF
Shadowsocks

Server: ${server_ip}
Port: ${SS_PORT}
Method: ${SS_METHOD}
Password: ${SS_PASSWORD}

Shadowrocket URI:
${ss_uri}

Clash/Mihomo proxy snippet:
proxies:
  - name: "${SS_NODE_NAME}"
    type: ss
    server: ${server_ip}
    port: ${SS_PORT}
    cipher: ${SS_METHOD}
    password: "${SS_PASSWORD}"
    udp: true
EOF
  chmod 600 "$SS_OUTPUT"
}

print_results() {
  local ss_uri="$1"

  log "Shadowsocks is ready."
  printf '\nShadowrocket URI:\n%s\n\n' "$ss_uri"

  if command -v qrencode >/dev/null 2>&1; then
    printf 'QR code:\n'
    printf '%s' "$ss_uri" | qrencode -t ansiutf8 || true
    printf '\n'
  fi

  printf 'Client info saved to: %s\n' "$SS_OUTPUT"
  printf 'Server config: %s\n\n' "$SS_CONFIG"
  warn "If your VPS provider has an external firewall, also allow TCP and UDP port ${SS_PORT} there."
}

main() {
  ensure_root
  validate_inputs
  ensure_supported_os
  prepare_existing_config
  install_packages
  ensure_password

  local server_ip
  local ss_uri
  server_ip="$(detect_public_ipv4)"

  log "Using ${server_ip}:${SS_PORT} with method ${SS_METHOD}."
  write_config
  write_service
  open_firewall_port_if_needed
  start_service
  ss_uri="$(make_ss_uri "$server_ip")"
  write_client_info "$server_ip" "$ss_uri"
  print_results "$ss_uri"
}

main "$@"
