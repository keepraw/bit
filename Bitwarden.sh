#!/usr/bin/env bash
set -Eeuo pipefail

# Fresh Vaultwarden + Caddy deployment for Debian/Ubuntu.
# Existing containers, files, and data are never removed or migrated.

readonly DEFAULT_INSTALL_DIR="/opt/vaultwarden"
readonly VAULTWARDEN_CONTAINER="vaultwarden"
readonly CADDY_CONTAINER="vaultwarden-caddy"
readonly RCLONE_REMOTE="d:data/bitwarden"
readonly BACKUP_RETENTION_DAYS="14"
readonly BACKUP_TIME="03:30:00"

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

load_os_release() {
  [[ -r /etc/os-release ]] || fail "Cannot identify the operating system."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) fail "Automatic installation supports Debian and Ubuntu only." ;;
  esac
}

install_base_packages() {
  apt-get update
  apt-get install -y ca-certificates curl rclone util-linux
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker
    return
  fi

  log "Installing Docker Engine and Docker Compose from Docker's official repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  local codename="${VERSION_CODENAME:-}"
  if [[ -z "$codename" && -n "${UBUNTU_CODENAME:-}" ]]; then
    codename=$UBUNTU_CODENAME
  fi
  [[ -n "$codename" ]] || fail "Cannot determine the distribution codename."

  cat > /etc/apt/sources.list.d/docker.list <<EOF_DOCKER_REPO
# Added by Bitwarden.sh
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${codename} stable
EOF_DOCKER_REPO

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

write_compose_files() {
  local install_dir=$1
  local domain=$2
  local acme_email=$3
  local allow_signups=$4

  umask 077
  cat > "$install_dir/.env" <<EOF_ENV
DOMAIN=${domain}
ACME_EMAIL=${acme_email}
SIGNUPS_ALLOWED=${allow_signups}
EOF_ENV

  cat > "$install_dir/compose.yaml" <<'EOF_COMPOSE'
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
EOF_COMPOSE

  cat > "$install_dir/Caddyfile" <<'EOF_CADDY'
{
  email {$ACME_EMAIL}
}

{$DOMAIN} {
  encode zstd gzip
  reverse_proxy vaultwarden:80
}
EOF_CADDY

  chmod 0600 "$install_dir/.env"
  chmod 0644 "$install_dir/compose.yaml" "$install_dir/Caddyfile"
}

write_backup_files() {
  local install_dir=$1
  local backup_dir="$install_dir/backups"

  cat > /usr/local/sbin/vaultwarden-backup.sh <<'EOF_BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /etc/default/vaultwarden-backup

log() {
  printf '[Vaultwarden backup] %s\n' "$*"
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  log "ERROR: run as root"
  exit 1
}

command -v docker >/dev/null 2>&1 || {
  log "ERROR: docker is not installed"
  exit 1
}
command -v rclone >/dev/null 2>&1 || {
  log "ERROR: rclone is not installed"
  exit 1
}
[[ -f "$INSTALL_DIR/compose.yaml" ]] || {
  log "ERROR: $INSTALL_DIR/compose.yaml does not exist"
  exit 1
}

install -d -m 0750 "$BACKUP_DIR"
exec 9>"/run/lock/vaultwarden-backup.lock"
flock -n 9 || {
  log "Another backup is already running; exiting"
  exit 0
}

stamp=$(date +%Y%m%d-%H%M%S)
archive="$BACKUP_DIR/vaultwarden-full-$stamp.tar.gz"
temporary="$archive.partial"
vaultwarden_stopped=false

restart_vaultwarden() {
  if [[ "$vaultwarden_stopped" == true ]]; then
    docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/compose.yaml" start vaultwarden >/dev/null 2>&1 || true
  fi
  rm -f "$temporary"
}
trap restart_vaultwarden EXIT

log "Stopping Vaultwarden briefly for a consistent backup"
docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/compose.yaml" stop vaultwarden
vaultwarden_stopped=true

log "Creating local backup: $archive"
tar -C "$INSTALL_DIR" -czf "$temporary" \
  .env \
  Caddyfile \
  compose.yaml \
  data
mv "$temporary" "$archive"

log "Starting Vaultwarden"
docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/compose.yaml" start vaultwarden
vaultwarden_stopped=false

log "Uploading backup to $RCLONE_REMOTE"
rclone copyto "$archive" "$RCLONE_REMOTE/$(basename "$archive")" --retries 3

log "Deleting remote backups older than $RETENTION_DAYS days"
rclone delete "$RCLONE_REMOTE" \
  --min-age "${RETENTION_DAYS}d" \
  --include 'vaultwarden-full-*.tar.gz'

log "Deleting local backups older than $RETENTION_DAYS days"
find "$BACKUP_DIR" -maxdepth 1 -type f \
  -name 'vaultwarden-full-*.tar.gz' \
  -mtime "+$RETENTION_DAYS" \
  -delete

log "Backup completed: $archive"
EOF_BACKUP

  chmod 0750 /usr/local/sbin/vaultwarden-backup.sh

  {
    printf 'INSTALL_DIR=%q\n' "$install_dir"
    printf 'BACKUP_DIR=%q\n' "$backup_dir"
    printf 'RCLONE_REMOTE=%q\n' "$RCLONE_REMOTE"
    printf 'RETENTION_DAYS=%q\n' "$BACKUP_RETENTION_DAYS"
  } > /etc/default/vaultwarden-backup
  chmod 0600 /etc/default/vaultwarden-backup

  cat > /etc/systemd/system/vaultwarden-backup.service <<'EOF_SERVICE'
[Unit]
Description=Vaultwarden local and rclone backup
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Environment=HOME=/root
ExecStart=/usr/local/sbin/vaultwarden-backup.sh
EOF_SERVICE

  cat > /etc/systemd/system/vaultwarden-backup.timer <<EOF_TIMER
[Unit]
Description=Run Vaultwarden backup every day

[Timer]
OnCalendar=*-*-* ${BACKUP_TIME}
Persistent=true
Unit=vaultwarden-backup.service

[Install]
WantedBy=timers.target
EOF_TIMER

  systemctl daemon-reload

  if rclone listremotes 2>/dev/null | grep -Fxq 'd:'; then
    systemctl enable --now vaultwarden-backup.timer
    log "Daily backup timer enabled for ${BACKUP_TIME}; remote: ${RCLONE_REMOTE}"
  else
    systemctl disable --now vaultwarden-backup.timer >/dev/null 2>&1 || true
    log "WARNING: rclone remote 'd:' is not configured."
    log "The backup timer was installed but left disabled. Run 'rclone config', then:"
    log "systemctl enable --now vaultwarden-backup.timer"
  fi
}

main() {
  require_root
  load_os_release

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

  install_base_packages
  install_docker

  [[ ! -e "$install_dir" ]] || fail "$install_dir already exists. This script is for fresh installations only."
  container_exists "$VAULTWARDEN_CONTAINER" && fail "Container '$VAULTWARDEN_CONTAINER' already exists."
  container_exists "$CADDY_CONTAINER" && fail "Container '$CADDY_CONTAINER' already exists."
  port_is_in_use 80 && fail "TCP port 80 is already in use."
  port_is_in_use 443 && fail "TCP port 443 is already in use."

  log "Creating a fresh installation in $install_dir"
  install -d -m 0750 \
    "$install_dir" \
    "$install_dir/data" \
    "$install_dir/backups" \
    "$install_dir/caddy-data" \
    "$install_dir/caddy-config"

  write_compose_files "$install_dir" "$domain" "$acme_email" "$allow_signups"
  write_backup_files "$install_dir"

  cd "$install_dir"
  docker compose config >/dev/null
  docker compose pull
  docker compose up -d

  log "Deployment completed: https://${domain}"
  log "Installation directory: ${install_dir}"
  log "Backup script: /usr/local/sbin/vaultwarden-backup.sh"
  log "Backup timer: vaultwarden-backup.timer"
  log "Backup remote: ${RCLONE_REMOTE}"
  if [[ "$allow_signups" == true ]]; then
    log "Registration is enabled. Create the first account, then disable registration as described in README.md."
  fi
}

main "$@"
