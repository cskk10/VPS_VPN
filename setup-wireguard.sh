#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET_PREFIX="${WG_SUBNET_PREFIX:-10.8.0}"
WG_SERVER_ADDRESS="${WG_SUBNET_PREFIX}.1/24"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1, 8.8.8.8}"
CLIENTS_DIR="${CLIENTS_DIR:-/root/wireguard-clients}"
WG_CONFIG="/etc/wireguard/${WG_INTERFACE}.conf"
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

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_port() {
  [[ "$WG_PORT" =~ ^[0-9]+$ ]] || die "WG_PORT must be a number."
  (( WG_PORT >= 1 && WG_PORT <= 65535 )) || die "WG_PORT must be between 1 and 65535."
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

validate_client_name() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
}

require_client_name() {
  local name="$1"
  validate_client_name "$name" || die "Client name '$name' is invalid. Use letters, numbers, dots, underscores, or hyphens."
}

ensure_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run this script as root, for example: sudo bash setup-wireguard.sh"
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
}

ensure_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl was not found. Please run this on a normal Ubuntu/Debian VPS with systemd."
}

install_packages() {
  log "Installing WireGuard and helper tools..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y wireguard qrencode iptables curl ca-certificates iproute2
}

detect_default_interface() {
  local iface
  iface="$(ip -4 route list default 2>/dev/null | awk '{print $5; exit}')"
  [[ -n "$iface" ]] || die "Could not detect the default network interface."
  printf '%s' "$iface"
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

  if ! validate_ipv4 "$ip"; then
    if [[ -t 0 ]]; then
      read -r -p "Public IPv4 could not be detected. Enter server public IPv4: " ip
      ip="$(trim "$ip")"
      validate_ipv4 "$ip" || die "Invalid public IPv4 address."
    else
      die "Could not detect public IPv4. Re-run with SERVER_PUBLIC_IP=x.x.x.x."
    fi
  fi

  printf '%s' "$ip"
}

collect_clients_from_env() {
  local raw_name
  local name
  local -a raw_clients
  IFS=',' read -r -a raw_clients <<< "${CLIENTS:-}"

  for raw_name in "${raw_clients[@]}"; do
    name="$(trim "$raw_name")"
    [[ -n "$name" ]] || continue
    require_client_name "$name"
    CLIENT_NAMES+=("$name")
  done
}

collect_clients_interactively() {
  [[ -t 0 ]] || die "No CLIENTS value was provided and stdin is not interactive. Example: CLIENTS=\"phone,laptop\" bash setup-wireguard.sh"

  local count
  local name
  while true; do
    read -r -p "How many clients do you want to create? " count
    count="$(trim "$count")"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 && count <= 253 )); then
      break
    fi
    warn "Enter a number between 1 and 253."
  done

  for ((i = 1; i <= count; i++)); do
    while true; do
      read -r -p "Client ${i} name [client${i}]: " name
      name="$(trim "$name")"
      name="${name:-client${i}}"
      if validate_client_name "$name"; then
        CLIENT_NAMES+=("$name")
        break
      fi
      warn "Use letters, numbers, dots, underscores, or hyphens."
    done
  done
}

collect_clients() {
  declare -g -a CLIENT_NAMES=()
  declare -A seen=()
  local name

  if [[ -n "${CLIENTS:-}" ]]; then
    collect_clients_from_env
  else
    collect_clients_interactively
  fi

  (( ${#CLIENT_NAMES[@]} >= 1 )) || die "At least one client is required."
  (( ${#CLIENT_NAMES[@]} <= 253 )) || die "A maximum of 253 clients is supported for ${WG_SUBNET_PREFIX}.0/24."

  for name in "${CLIENT_NAMES[@]}"; do
    if [[ -n "${seen[$name]:-}" ]]; then
      die "Duplicate client name '$name'."
    fi
    seen[$name]=1
  done
}

prepare_existing_config() {
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"

  if [[ ! -f "$WG_CONFIG" ]]; then
    return
  fi

  if [[ "$FORCE" != "1" ]]; then
    die "$WG_CONFIG already exists. Re-run with FORCE=1 to back it up and rebuild."
  fi

  warn "$WG_CONFIG already exists. FORCE=1 enabled, backing up and rebuilding."
  systemctl disable --now "wg-quick@${WG_INTERFACE}" >/dev/null 2>&1 || true
  cp -a "$WG_CONFIG" "${WG_CONFIG}.bak.${timestamp}"

  if [[ -d "$CLIENTS_DIR" ]]; then
    mv "$CLIENTS_DIR" "${CLIENTS_DIR}.bak.${timestamp}"
  fi
}

enable_ipv4_forwarding() {
  log "Enabling IPv4 forwarding..."
  cat >/etc/sysctl.d/99-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

open_firewall_port_if_needed() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log "Allowing WireGuard UDP port ${WG_PORT} in UFW..."
    ufw allow "${WG_PORT}/udp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log "Allowing WireGuard UDP port ${WG_PORT} in firewalld..."
    firewall-cmd --add-port="${WG_PORT}/udp" --permanent
    firewall-cmd --reload
  fi
}

write_server_config_header() {
  local server_private_key="$1"
  local default_interface="$2"

  install -d -m 700 /etc/wireguard
  install -m 600 /dev/null "$WG_CONFIG"

  cat >"$WG_CONFIG" <<EOF
[Interface]
Address = ${WG_SERVER_ADDRESS}
ListenPort = ${WG_PORT}
PrivateKey = ${server_private_key}
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${default_interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${default_interface} -j MASQUERADE
EOF
}

append_server_peer() {
  local client_name="$1"
  local client_public_key="$2"
  local preshared_key="$3"
  local client_ip="$4"

  cat >>"$WG_CONFIG" <<EOF

[Peer]
# ${client_name}
PublicKey = ${client_public_key}
PresharedKey = ${preshared_key}
AllowedIPs = ${client_ip}/32
EOF
}

write_client_config() {
  local client_name="$1"
  local client_private_key="$2"
  local server_public_key="$3"
  local preshared_key="$4"
  local client_ip="$5"
  local endpoint="$6"
  local client_config="${CLIENTS_DIR}/${client_name}.conf"

  cat >"$client_config" <<EOF
[Interface]
PrivateKey = ${client_private_key}
Address = ${client_ip}/32
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${server_public_key}
PresharedKey = ${preshared_key}
Endpoint = ${endpoint}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$client_config"
}

generate_configs() {
  local default_interface="$1"
  local server_public_ip="$2"
  local endpoint="${server_public_ip}:${WG_PORT}"
  local server_private_key
  local server_public_key
  local client_private_key
  local client_public_key
  local preshared_key
  local client_ip
  local client_name

  log "Generating WireGuard keys and configuration..."
  umask 077
  install -d -m 700 "$CLIENTS_DIR"

  server_private_key="$(wg genkey)"
  server_public_key="$(printf '%s\n' "$server_private_key" | wg pubkey)"
  write_server_config_header "$server_private_key" "$default_interface"

  for i in "${!CLIENT_NAMES[@]}"; do
    client_name="${CLIENT_NAMES[$i]}"
    client_ip="${WG_SUBNET_PREFIX}.$((i + 2))"
    client_private_key="$(wg genkey)"
    client_public_key="$(printf '%s\n' "$client_private_key" | wg pubkey)"
    preshared_key="$(wg genpsk)"

    append_server_peer "$client_name" "$client_public_key" "$preshared_key" "$client_ip"
    write_client_config "$client_name" "$client_private_key" "$server_public_key" "$preshared_key" "$client_ip" "$endpoint"
  done
}

start_wireguard() {
  log "Starting WireGuard service..."
  systemctl enable --now "wg-quick@${WG_INTERFACE}"
}

print_results() {
  local client_name
  local client_config

  log "WireGuard is ready."
  printf '\nServer config: %s\n' "$WG_CONFIG"
  printf 'Client configs: %s\n\n' "$CLIENTS_DIR"

  for client_name in "${CLIENT_NAMES[@]}"; do
    client_config="${CLIENTS_DIR}/${client_name}.conf"
    printf 'Client: %s\n' "$client_name"
    printf 'Config: %s\n' "$client_config"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ansiutf8 <"$client_config" || true
    fi
    printf '\n'
  done

  warn "If your VPS provider has an external firewall, also allow UDP port ${WG_PORT} there."
}

main() {
  ensure_root
  validate_port
  ensure_supported_os
  ensure_systemd
  collect_clients
  prepare_existing_config
  install_packages

  local default_interface
  local server_public_ip
  default_interface="$(detect_default_interface)"
  server_public_ip="$(detect_public_ipv4)"

  log "Using public endpoint ${server_public_ip}:${WG_PORT} and network interface ${default_interface}."
  enable_ipv4_forwarding
  open_firewall_port_if_needed
  generate_configs "$default_interface" "$server_public_ip"
  start_wireguard
  print_results
}

main "$@"
