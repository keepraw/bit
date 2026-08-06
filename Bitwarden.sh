#!/usr/bin/env bash
set -Eeuo pipefail

# Fresh Vaultwarden + Caddy deployment for Debian/Ubuntu.
# This script never stops, removes, renames, or migrates an existing deployment.

readonly DEFAULT_INSTALL_DIR="/opt/vaultwarden"
readonly VAULTWARDEN_CONTAINER="vaultwarden"
readonly CADDY_CONTAINER="vaultwarden-caddy"

log() {
  printf '[Bitwarden] %s\n' "$*"
}

fail() {
  printf '[Bitwarden] ERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  printf '[Bitwarden] Failed at line %s. Existing services and data were not removed.\n' "${BASH_LINENO[0]}" >&2
  exit "$exit_code"
}
trap on_error ERR

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run this script as root."
}

validate_domain() {
  local value=$1
  [[ "$value" != http://* && "$value" != https://* ]] || return 1
  [[ "$value" != */* ]] || return 1
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_email() {
  local value=$1
  [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

prompt_value() {
  local variable_name=$1
  local prompt_text=$2
  local current_value=${!variable_name:-}

  if [[ -z "$current_value" ]]; then
    read -r -p "$prompt_text" current_value
  fi

  printf -v "$variable_name" '%s' "$current_value"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi

  [[ -r /etc/os-release ]] || fail "Cannot identify the operating system. Install Docker Engine and the Compose plugin manually."
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    debian|ubuntu) ;;
    *) fail "Automatic Docker installation supports Debian and Ubuntu only." ;;
  esac

  log "Installing Docker Engine and Docker Compose from Docker's official repository..."
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  local codename="${VERSION_CODENAME:-}"
  if [[ -z "$codename" && -n "${UBUNTU_CODENAME:-}" ]]; then
    codename=$UBUNTU_CODENAME
  fi
  [[ -n "$codename" ]] || fail "Cannot determine the distribution codename."

  cat > /etc/apt/sources.list.d/docker.list <<EOF
# Added by Bitwarden.sh
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${codename} stable
EOF

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker

  docker compose version >/dev/null 2>&1 || fail "Docker Compose installation failed."
}

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

port_is_in_use() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -H -lnt "sport = :${port}" 2>/dev/null | grep -q .
  else
    return 1
  fi
}

main() {
  require_root

  local domain=${DOMAIN:-}
  local acme_email=${ACME_EMAIL:-}
  local install_dir=${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}
  local allow_signups=${SIGNUPS_ALLOWED:-true}

  prompt_value domain "Domain name, without https://: "
  validate_domain "$domain" || fail "Invalid domain name. Example: vault.example.com"

  prompt_value acme_email "Email for HTTPS certificate notices: "
  validate_email "$acme_email" || fail "Invalid email address."

  case "$allow_signups" in
    true|false) ;;
    *) fail "SIGNUPS_ALLOWED must be true or false." ;;
  esac

  [[ "$install_dir" == /* ]] || fail "INSTALL_DIR must be an absolute path."

  install_docker

  [[ ! -e "$install_dir" ]] || fail "$install_dir already exists. This script is for fresh installations only."
  container_exists "$VAULTWARDEN_CONTAINER" && fail "Container '$VAULTWARDEN_CONTAINER' already exists."
  container_exists "$CADDY_CONTAINER" && fail "Container '$CADDY_CONTAINER' already exists."
  port_is_in_use 80 && fail "TCP port 80 is already in use."
  port_is_in_use 443 && fail "TCP port 443 is already in use."

  log "Creating a fresh installation in $install_dir"
  install -d -m 0750 "$install_dir" "$install_dir/data" "$install_dir/caddy-data" "$install_dir/caddy-config"

  umask 077
  cat > "$install_dir/.env" <<EOF
DOMAIN=${domain}
ACME_EMAIL=${acme_email}
SIGNUPS_ALLOWED=${allow_signups}
EOF

  cat > "$install_dir/compose.yaml" <<'EOF'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "https://${DOMAIN}"
      SIGNUPS_ALLOWED: "${SIGNUPS_ALLOWED}"
    volumes:
      - ./data:/data
    networks:
      - vaultwarden

  caddy:
    image: caddy:2
    container_name: vaultwarden-caddy
    restart: unless-stopped
    depends_on:
      - vaultwarden
    environment:
      DOMAIN: "${DOMAIN}"
      ACME_EMAIL: "${ACME_EMAIL}"
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-config:/config
    networks:
      - vaultwarden

networks:
  vaultwarden:
EOF

  cat > "$install_dir/Caddyfile" <<'EOF'
{
  email {$ACME_EMAIL}
}

{$DOMAIN} {
  encode zstd gzip
  reverse_proxy vaultwarden:80
}
EOF

  chmod 0600 "$install_dir/.env"
  chmod 0644 "$install_dir/compose.yaml" "$install_dir/Caddyfile"

  cd "$install_dir"
  docker compose config >/dev/null
  docker compose pull
  docker compose up -d

  log "Deployment completed: https://${domain}"
  log "Installation directory: ${install_dir}"
  if [[ "$allow_signups" == true ]]; then
    log "Registration is enabled. Create the first account, then disable registration as described in README.md."
  fi
}

main "$@"
