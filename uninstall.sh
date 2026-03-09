#!/usr/bin/env bash
# =============================================================================
# TacticalRMM - Uninstall Script
# =============================================================================
#
# Removes ALL TacticalRMM components:
#   - systemd services
#   - /rmm, /meshcentral, /opt/tactical, /var/www/rmm
#   - PostgreSQL databases (tacticalrmm, meshcentral) and users
#   - Nginx configs for rmm, frontend, meshcentral
#   - /etc/conf.d/celery.conf and related files
#   - /opt/trmm-community-scripts
#   - Cron entries for backup
#   - Hosts file entries added by TRMM
#   - TacticalRMM log directory (/var/log/trmm)
#   - Notification config (/etc/trmm)
#
# Optionally removes (with separate prompts):
#   - Let's Encrypt certificates (/etc/letsencrypt)
#   - System packages: nginx, postgresql-15, nodejs, redis
#   - Python 3.11 (compiled from source)
#
# Usage:
#   ./uninstall.sh           # interactive (with confirmations)
#   ./uninstall.sh --force   # skip all confirmations (DANGEROUS)
#
# IMPORTANT: This is irreversible. Take a backup first with backup.sh.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

set -euo pipefail

TRMM_SERVICES=(rmm daphne celery celerybeat nats nats-api meshcentral nginx)
local_settings='/rmm/api/tacticalrmm/tacticalrmm/local_settings.py'
FORCE=false

# =============================================================================
# Helpers
# =============================================================================

require_not_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    print_error "Do NOT run this script as root."
    exit 1
  fi
}

confirm() {
  local prompt="$1"
  if "${FORCE}"; then return 0; fi
  printf "${YELLOW}%s [y/N]${NC} " "${prompt}"
  local answer; read -r answer
  [[ "${answer,,}" == "y" ]]
}

confirm_critical() {
  # Double confirmation for truly destructive actions
  local prompt="$1"
  if "${FORCE}"; then return 0; fi
  printf "${RED}%s${NC}\n" "${prompt}"
  printf "${RED}Type 'yes' to confirm:${NC} "
  local answer; read -r answer
  [[ "${answer}" == "yes" ]]
}

step() {
  printf "\n${BLUE}[step]${NC} %s\n" "$1"
  log_info "STEP: $1"
}

skip() {
  printf "${YELLOW}  Skipped.${NC}\n"
  log_info "  Skipped: $1"
}

# =============================================================================
# Stop and disable services
# =============================================================================

remove_services() {
  step "Stopping and disabling all TRMM services"
  for svc in "${TRMM_SERVICES[@]}"; do
    if systemctl list-units --full -all 2>/dev/null | grep -q "${svc}.service"; then
      sudo systemctl stop "${svc}.service" 2>/dev/null || true
      sudo systemctl disable "${svc}.service" 2>/dev/null || true
      log_info "  Stopped and disabled ${svc}"
    fi
  done

  step "Removing systemd unit files"
  local sysd='/etc/systemd/system'
  for unit in rmm daphne celery celerybeat nats nats-api meshcentral; do
    local f="${sysd}/${unit}.service"
    if [[ -f "${f}" ]]; then
      sudo rm -f "${f}"
      log_info "  Removed ${f}"
    fi
  done
  sudo systemctl daemon-reload
  print_green "Services removed"
}

# =============================================================================
# Drop databases
# =============================================================================

remove_databases() {
  step "Dropping PostgreSQL databases"

  # Extract credentials from local_settings if available
  local pguser pgpw mesh_pguser mesh_pgpw
  pguser=""
  mesh_pguser=""

  if [[ -f "${local_settings}" ]]; then
    pguser=$(grep -w "USER" "${local_settings}" 2>/dev/null \
      | sed "s/.*'USER': '//; s/'.*//" || true)
    pgpw=$(grep -w "PASSWORD" "${local_settings}" 2>/dev/null \
      | sed "s/.*'PASSWORD': '//; s/'.*//" || true)
  fi

  if [[ -f /meshcentral/meshcentral-data/config.json ]] \
      && command -v jq >/dev/null 2>&1; then
    mesh_pguser=$(jq -r '.settings.postgres.user // empty' \
      /meshcentral/meshcentral-data/config.json 2>/dev/null || true)
    mesh_pgpw=$(jq -r '.settings.postgres.password // empty' \
      /meshcentral/meshcentral-data/config.json 2>/dev/null || true)
  fi

  # Drop tacticalrmm DB
  if sudo -iu postgres psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw tacticalrmm; then
    sudo -iu postgres psql -c "DROP DATABASE IF EXISTS tacticalrmm" 2>/dev/null || true
    log_info "  Dropped database: tacticalrmm"
  fi
  if [[ -n "${pguser}" ]]; then
    sudo -iu postgres psql -c "DROP USER IF EXISTS ${pguser}" 2>/dev/null || true
    log_info "  Dropped user: ${pguser}"
  fi

  # Drop meshcentral DB
  if sudo -iu postgres psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw meshcentral; then
    sudo -iu postgres psql -c "DROP DATABASE IF EXISTS meshcentral" 2>/dev/null || true
    log_info "  Dropped database: meshcentral"
  fi
  if [[ -n "${mesh_pguser}" ]]; then
    sudo -iu postgres psql -c "DROP USER IF EXISTS ${mesh_pguser}" 2>/dev/null || true
    log_info "  Dropped user: ${mesh_pguser}"
  fi

  print_green "Databases removed"
}

# =============================================================================
# Remove directories
# =============================================================================

remove_directories() {
  step "Removing TRMM application directories"

  local dirs=(/rmm /meshcentral /opt/tactical /var/www/rmm /opt/trmm-community-scripts
               /var/log/celery /etc/conf.d /etc/trmm /var/log/trmm)

  for d in "${dirs[@]}"; do
    if [[ -d "${d}" ]]; then
      sudo rm -rf "${d}"
      log_info "  Removed ${d}"
    fi
  done

  # NATS and nats-api binaries
  for bin in /usr/local/bin/nats-server /usr/local/bin/nats-api; do
    if [[ -f "${bin}" ]]; then
      sudo rm -f "${bin}"
      log_info "  Removed ${bin}"
    fi
  done

  print_green "Directories removed"
}

# =============================================================================
# Remove Nginx configs
# =============================================================================

remove_nginx_configs() {
  step "Removing Nginx site configs"
  for conf in rmm frontend meshcentral; do
    sudo rm -f "/etc/nginx/sites-enabled/${conf}.conf"
    sudo rm -f "/etc/nginx/sites-available/${conf}.conf"
    log_info "  Removed nginx config for ${conf}"
  done
  print_green "Nginx configs removed"
}

# =============================================================================
# Remove Let's Encrypt certs (optional)
# =============================================================================

remove_letsencrypt() {
  if [[ ! -d /etc/letsencrypt ]]; then return 0; fi

  if confirm "Remove Let's Encrypt certificates (/etc/letsencrypt)?"; then
    sudo rm -rf /etc/letsencrypt
    # Remove renewal hook
    sudo rm -f /etc/letsencrypt/renewal-hooks/deploy/trmm-reload.sh 2>/dev/null || true
    log_info "Let's Encrypt certs removed"
    print_green "Let's Encrypt certs removed"
  else
    skip "Let's Encrypt certs"
  fi
}

# =============================================================================
# Clean /etc/hosts
# =============================================================================

clean_hosts() {
  step "Cleaning /etc/hosts"

  # Read domains from local_settings before it's gone
  local api="" frontend="" mesh=""
  if [[ -f "${local_settings}" ]]; then
    api=$(grep -oP "(?<=ALLOWED_HOSTS = \[')[^']+" "${local_settings}" 2>/dev/null || true)
  fi

  # Remove 127.0.1.1 line if it was added by TRMM (contains known TRMM subdomains)
  # We can't reliably know all domains, so we just warn the user
  if [[ -n "${api}" ]]; then
    sudo sed -i "/127\.0\.1\.1.*${api}/d" /etc/hosts 2>/dev/null || true
    log_info "Removed ${api} entries from /etc/hosts"
  fi
  printf "${YELLOW}NOTE: Manually review /etc/hosts if TRMM domain entries remain.${NC}\n"
}

# =============================================================================
# Remove cron entries
# =============================================================================

remove_cron() {
  step "Removing TRMM cron entries"
  if crontab -l 2>/dev/null | grep -q "backup.sh"; then
    crontab -l 2>/dev/null | grep -v "backup.sh" | crontab -
    log_info "Removed backup cron entry"
    print_green "Cron entries removed"
  else
    log_info "No TRMM cron entries found"
  fi
}

# =============================================================================
# Remove system packages (optional)
# =============================================================================

remove_packages() {
  step "Optional: remove system packages installed by TRMM"

  if confirm "Remove Nginx?"; then
    sudo apt-get remove -y nginx nginx-common 2>/dev/null || true
    sudo rm -f /etc/apt/sources.list.d/nginx.list
    sudo rm -f /etc/apt/keyrings/nginx-archive-keyring.gpg
    log_info "Nginx removed"
  else
    skip "nginx"
  fi

  if confirm "Remove PostgreSQL 15?"; then
    sudo apt-get remove -y postgresql-15 postgresql-client-15 2>/dev/null || true
    sudo apt-get purge -y postgresql-15 2>/dev/null || true
    sudo rm -f /etc/apt/sources.list.d/pgdg.list
    sudo rm -f /etc/apt/keyrings/postgresql-archive-keyring.gpg
    log_info "PostgreSQL 15 removed"
  else
    skip "postgresql-15"
  fi

  if confirm "Remove NodeJS?"; then
    sudo apt-get remove -y nodejs 2>/dev/null || true
    sudo rm -f /etc/apt/sources.list.d/nodesource.list
    sudo rm -f /etc/apt/keyrings/nodesource.gpg
    log_info "NodeJS removed"
  else
    skip "nodejs"
  fi

  if confirm "Remove Redis?"; then
    sudo apt-get remove -y redis-server 2>/dev/null || true
    log_info "Redis removed"
  else
    skip "redis"
  fi

  if confirm "Remove Python 3.11 (compiled from source at /usr/local/bin/python3.11)?"; then
    sudo rm -f /usr/local/bin/python3.11* /usr/local/bin/pip3.11*
    sudo rm -rf /usr/local/lib/python3.11
    log_info "Python 3.11 removed"
  else
    skip "python3.11"
  fi

  if confirm "Remove Certbot?"; then
    sudo apt-get remove -y certbot 2>/dev/null || true
    log_info "Certbot removed"
  else
    skip "certbot"
  fi

  sudo apt-get autoremove -y 2>/dev/null || true
  print_green "Package cleanup done"
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
  printf "\n${GREEN}%0.s=${NC}" {1..80}; printf "\n"
  printf "${GREEN}TacticalRMM has been uninstalled.${NC}\n"
  printf "${GREEN}%0.s=${NC}" {1..80}; printf "\n\n"
  printf "Log file: %s\n\n" "${TRMM_LOG_FILE}"
  printf "${YELLOW}You may want to:${NC}\n"
  printf "  - Review /etc/hosts for any remaining TRMM entries\n"
  printf "  - Reboot the server to clear any residual processes\n"
  printf "  - Remove /rmmbackups/ if you no longer need the backup archives\n\n"
}

# =============================================================================
# Main
# =============================================================================

main() {
  init_logging "uninstall"
  require_not_root

  for arg in "$@"; do
    [[ "${arg}" == "--force" ]] && FORCE=true
  done

  log_info "uninstall.sh started. FORCE=${FORCE}"

  printf "\n${RED}%0.s!${NC}" {1..80}; printf "\n"
  printf "${RED}  WARNING: This will permanently remove TacticalRMM and all its data.${NC}\n"
  printf "${RED}  This action CANNOT be undone.${NC}\n"
  printf "${RED}%0.s!${NC}" {1..80}; printf "\n\n"

  if [[ -f "${SCRIPT_DIR}/backup.sh" ]]; then
    printf "${YELLOW}It is strongly recommended to run a backup first:${NC}\n"
    printf "  ${GREEN}./backup.sh${NC}\n\n"
  fi

  if ! confirm_critical "Are you absolutely sure you want to uninstall TacticalRMM?"; then
    printf "Aborted. No changes made.\n"
    exit 0
  fi

  log_info "User confirmed uninstall."

  remove_services
  remove_databases
  remove_nginx_configs
  remove_letsencrypt
  remove_cron
  clean_hosts
  remove_directories    # After databases (needs local_settings for credentials)
  remove_packages

  print_summary
  log_info "=== Uninstall complete ==="
}

main "$@"
