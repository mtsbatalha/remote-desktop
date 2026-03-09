#!/usr/bin/env bash
# =============================================================================
# TacticalRMM - Backup Script
# =============================================================================
#
# Usage:
#   ./backup.sh                  # manual backup to /rmmbackups/
#   ./backup.sh --auto           # scheduled run: rotates daily/weekly/monthly
#   ./backup.sh --schedule       # install midnight cron + create directory tree
#   ./backup.sh --list           # list existing backups with sizes
#   ./backup.sh --verify <file>  # verify integrity of an existing backup
#
# Rotation policy (--auto):
#   Daily   : kept for 14 days  (runs Mon-Thu, Sat, Sun)
#   Weekly  : kept for 60 days  (runs every Friday)
#   Monthly : kept for 380 days (runs on the 1st of the month)
#
# Email notifications: run ./setup_notifications.sh to configure.
# =============================================================================

SCRIPT_VERSION="33"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

BACKUP_ROOT='/rmmbackups'
local_settings='/rmm/api/tacticalrmm/tacticalrmm/local_settings.py'

# =============================================================================
# Helpers
# =============================================================================

require_not_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    print_error "Do NOT run this script as root."
    exit 1
  fi
}

require_installation() {
  if [[ ! -f "${local_settings}" ]]; then
    print_error "TRMM installation not found (${local_settings} missing)."
    exit 1
  fi
}

ensure_backup_dirs() {
  local dirs=("${BACKUP_ROOT}" "${BACKUP_ROOT}/daily" "${BACKUP_ROOT}/weekly" "${BACKUP_ROOT}/monthly")
  for d in "${dirs[@]}"; do
    if [[ ! -d "${d}" ]]; then
      sudo mkdir -p "${d}"
    fi
  done
  sudo chown -R "${USER}:${USER}" "${BACKUP_ROOT}"
}

# =============================================================================
# --schedule: install cron
# =============================================================================

do_schedule() {
  if ! sudo -n true 2>/dev/null; then
    print_error "Passwordless sudo is required for scheduling."
    exit 1
  fi

  ensure_backup_dirs

  # Remove any old trmm backup cron entries, then add fresh one
  crontab -l 2>/dev/null | grep -v "backup.sh" | crontab - || true
  (crontab -l 2>/dev/null; echo "0 0 * * * ${SCRIPT_DIR}/backup.sh --auto >> /var/log/trmm/backup-cron.log 2>&1") | crontab -

  print_green "Backup cron installed: runs daily at midnight"
  printf "Backup directory: %s\n" "${BACKUP_ROOT}"
  printf "Rotation policy:\n"
  printf "  Daily   -> %s/daily/   (kept 14 days)\n" "${BACKUP_ROOT}"
  printf "  Weekly  -> %s/weekly/  (kept 60 days, every Friday)\n" "${BACKUP_ROOT}"
  printf "  Monthly -> %s/monthly/ (kept 380 days, on 1st of month)\n" "${BACKUP_ROOT}"
  exit 0
}

# =============================================================================
# --list: show existing backups
# =============================================================================

do_list() {
  if [[ ! -d "${BACKUP_ROOT}" ]]; then
    printf "No backup directory found at %s\n" "${BACKUP_ROOT}"
    exit 0
  fi

  printf "${GREEN}%-10s %-60s %s${NC}\n" "Type" "File" "Size"
  printf "%0.s-" {1..90}; printf "\n"

  for type in daily weekly monthly; do
    local dir="${BACKUP_ROOT}/${type}"
    if [[ -d "${dir}" ]]; then
      while IFS= read -r -d '' f; do
        local size; size=$(du -sh "${f}" 2>/dev/null | cut -f1)
        printf "%-10s %-60s %s\n" "${type}" "$(basename "${f}")" "${size}"
      done < <(find "${dir}" -name '*.tar' -print0 | sort -z)
    fi
  done

  # Also show manual backups at root level
  while IFS= read -r -d '' f; do
    local size; size=$(du -sh "${f}" 2>/dev/null | cut -f1)
    printf "%-10s %-60s %s\n" "manual" "$(basename "${f}")" "${size}"
  done < <(find "${BACKUP_ROOT}" -maxdepth 1 -name '*.tar' -print0 | sort -z)
  exit 0
}

# =============================================================================
# --verify: check tar integrity
# =============================================================================

do_verify() {
  local file="${1:-}"
  if [[ -z "${file}" || ! -f "${file}" ]]; then
    print_error "Usage: ./backup.sh --verify <path-to-backup.tar>"
    exit 1
  fi

  printf "Verifying %s ...\n" "${file}"
  if tar -tf "${file}" >/dev/null 2>&1; then
    print_green "Backup integrity OK: ${file}"

    # Also check internal gzipped postgres dumps
    local tmp; tmp=$(mktemp -d)
    tar -xf "${file}" -C "${tmp}" postgres/ 2>/dev/null || true
    local ok=true
    while IFS= read -r -d '' gz; do
      if ! gzip -t "${gz}" 2>/dev/null; then
        print_error "Corrupt postgres dump: ${gz}"
        ok=false
      else
        log_ok "Postgres dump OK: $(basename "${gz}")"
      fi
    done < <(find "${tmp}/postgres" -name '*.psql.gz' -print0 2>/dev/null)
    rm -rf "${tmp}"

    "${ok}" && print_green "All internal checks passed." || { print_error "Some checks failed."; exit 1; }
  else
    print_error "Backup is CORRUPT or unreadable: ${file}"
    exit 1
  fi
  exit 0
}

# =============================================================================
# Core backup logic
# =============================================================================

do_backup() {
  local auto_mode="${1:-false}"
  local dt_now; dt_now=$(date '+%Y_%m_%d__%H_%M_%S')
  local tmp_dir; tmp_dir=$(mktemp -d -t tacticalrmm-XXXXXXXXXXXXXXXXXXXXX)
  local sysd="/etc/systemd/system"

  # Trap to clean up tmp_dir on error
  trap 'rm -rf "${tmp_dir}"; notify_failure "Backup failed" "Backup process failed at $(date). Check log: ${TRMM_LOG_FILE}"' ERR

  print_green "Starting backup (${dt_now})"
  log_info "Temp dir: ${tmp_dir}"

  # Create directory structure
  mkdir -p \
    "${tmp_dir}/postgres" \
    "${tmp_dir}/certs" \
    "${tmp_dir}/nginx" \
    "${tmp_dir}/systemd" \
    "${tmp_dir}/rmm" \
    "${tmp_dir}/confd" \
    "${tmp_dir}/opt" \
    "${tmp_dir}/meshcentral"

  # ---- PostgreSQL: TacticalRMM DB ----
  print_green "Backing up TacticalRMM database"
  local POSTGRES_USER POSTGRES_PW
  POSTGRES_USER=$(/rmm/api/env/bin/python /rmm/api/tacticalrmm/manage.py get_config dbuser)
  POSTGRES_PW=$(/rmm/api/env/bin/python /rmm/api/tacticalrmm/manage.py get_config dbpw)

  PGPASSWORD="${POSTGRES_PW}" pg_dump \
    --no-privileges --no-owner \
    --dbname="postgresql://${POSTGRES_USER}:${POSTGRES_PW}@localhost:5432/tacticalrmm" \
    | gzip -9 >"${tmp_dir}/postgres/db-${dt_now}.psql.gz"
  log_ok "TacticalRMM DB backup done"

  # ---- MeshCentral export ----
  print_green "Backing up MeshCentral"
  node /meshcentral/node_modules/meshcentral --dbexport

  if grep -q postgres "/meshcentral/meshcentral-data/config.json"; then
    if ! command -v jq >/dev/null 2>&1; then
      sudo apt-get install -y jq >/dev/null
    fi
    local MESH_PG_USER MESH_PG_PW
    MESH_PG_USER=$(jq -r '.settings.postgres.user' /meshcentral/meshcentral-data/config.json)
    MESH_PG_PW=$(jq -r '.settings.postgres.password' /meshcentral/meshcentral-data/config.json)
    PGPASSWORD="${MESH_PG_PW}" pg_dump \
      --no-privileges --no-owner \
      --dbname="postgresql://${MESH_PG_USER}:${MESH_PG_PW}@localhost:5432/meshcentral" \
      | gzip -9 >"${tmp_dir}/postgres/mesh-db-${dt_now}.psql.gz"
    log_ok "MeshCentral DB backup done"
  else
    mkdir -p "${tmp_dir}/meshcentral/mongo"
    mongodump --gzip --out="${tmp_dir}/meshcentral/mongo"
    log_ok "MeshCentral MongoDB backup done"
  fi

  # Clean up old meshcentral temp dirs before archiving
  [[ -d /meshcentral/meshcentral-backup ]]   && rm -rf /meshcentral/meshcentral-backup/*
  [[ -d /meshcentral/meshcentral-backups ]]  && rm -rf /meshcentral/meshcentral-backups/*
  [[ -d /meshcentral/meshcentral-coredumps ]] && rm -f /meshcentral/meshcentral-coredumps/*

  tar -czf "${tmp_dir}/meshcentral/mesh.tar.gz" \
    --exclude=/meshcentral/node_modules \
    --exclude=/meshcentral/meshcentral-recordings \
    /meshcentral
  log_ok "MeshCentral files archived"

  # ---- Certificates ----
  print_green "Backing up certificates"
  if [[ -d /etc/letsencrypt ]]; then
    sudo tar -czf "${tmp_dir}/certs/etc-letsencrypt.tar.gz" -C /etc/letsencrypt .
    log_ok "Let's Encrypt certs archived"
  fi

  if grep -q CERT_FILE "${local_settings}" 2>/dev/null; then
    mkdir -p "${tmp_dir}/certs/custom"
    local CERT_FILE KEY_FILE
    CERT_FILE=$(grep "^CERT_FILE" "${local_settings}" | awk -F'[= "]' '{print $5}')
    KEY_FILE=$(grep "^KEY_FILE" "${local_settings}" | awk -F'[= "]' '{print $5}')
    cp -p "${CERT_FILE}" "${tmp_dir}/certs/custom/cert"
    cp -p "${KEY_FILE}"  "${tmp_dir}/certs/custom/key"
    log_ok "Custom certs backed up"
  elif grep -q TRMM_INSECURE "${local_settings}" 2>/dev/null; then
    mkdir -p "${tmp_dir}/certs/selfsigned"
    local certdir='/etc/ssl/tactical'
    cp -p "${certdir}/key.pem"  "${tmp_dir}/certs/selfsigned/"
    cp -p "${certdir}/cert.pem" "${tmp_dir}/certs/selfsigned/"
    log_ok "Self-signed certs backed up"
  fi

  # ---- Nginx configs ----
  print_green "Backing up Nginx configs"
  for conf in rmm frontend meshcentral; do
    local src="/etc/nginx/sites-available/${conf}.conf"
    [[ -f "${src}" ]] && sudo cp "${src}" "${tmp_dir}/nginx/"
  done

  # ---- Systemd units ----
  print_green "Backing up systemd units"
  for unit in rmm celery celerybeat meshcentral nats daphne nats-api; do
    local f="${sysd}/${unit}.service"
    [[ -f "${f}" ]] && sudo cp "${f}" "${tmp_dir}/systemd/"
  done

  # ---- Celery / conf.d ----
  sudo tar -czf "${tmp_dir}/confd/etc-confd.tar.gz" -C /etc/conf.d .

  # ---- local_settings ----
  cp "${local_settings}" "${tmp_dir}/rmm/"

  # ---- /opt/tactical ----
  if [[ -d /opt/tactical ]]; then
    sudo tar -czf "${tmp_dir}/opt/opt-tactical.tar.gz" -C /opt/tactical .
    log_ok "/opt/tactical archived"
  fi

  # ---- Create final archive ----
  print_green "Creating final backup archive"
  local archive_path
  if "${auto_mode}"; then
    ensure_backup_dirs
    local month_day week_day
    month_day=$(date +'%d')
    week_day=$(date +'%u')   # 1=Mon ... 7=Sun

    if [[ "${month_day}" -eq 1 ]]; then
      archive_path="${BACKUP_ROOT}/monthly/rmm-backup-${dt_now}.tar"
    elif [[ "${week_day}" -eq 5 ]]; then
      archive_path="${BACKUP_ROOT}/weekly/rmm-backup-${dt_now}.tar"
    else
      archive_path="${BACKUP_ROOT}/daily/rmm-backup-${dt_now}.tar"
    fi
  else
    [[ ! -d "${BACKUP_ROOT}" ]] && { sudo mkdir -p "${BACKUP_ROOT}"; sudo chown "${USER}:${USER}" "${BACKUP_ROOT}"; }
    archive_path="${BACKUP_ROOT}/rmm-backup-${dt_now}.tar"
  fi

  tar -cf "${archive_path}" -C "${tmp_dir}" .
  rm -rf "${tmp_dir}"

  # ---- Verify integrity of the new archive ----
  print_green "Verifying backup integrity"
  if ! tar -tf "${archive_path}" >/dev/null 2>&1; then
    print_error "Backup archive failed integrity check: ${archive_path}"
    notify_failure "Backup integrity FAILED" "Archive is corrupt: ${archive_path}"
    exit 1
  fi
  log_ok "Integrity check passed"

  # ---- Rotate old backups (auto mode only) ----
  if "${auto_mode}"; then
    log_info "Rotating old backups..."
    find "${BACKUP_ROOT}/daily/"   -type f -mtime +14  -name '*.tar' -delete 2>/dev/null || true
    find "${BACKUP_ROOT}/weekly/"  -type f -mtime +60  -name '*.tar' -delete 2>/dev/null || true
    find "${BACKUP_ROOT}/monthly/" -type f -mtime +380 -name '*.tar' -delete 2>/dev/null || true
    log_ok "Old backups rotated"
  fi

  local archive_size; archive_size=$(du -sh "${archive_path}" | cut -f1)
  log_ok "Backup complete: ${archive_path} (${archive_size})"
  printf "${GREEN}Backup saved: %s (%s)${NC}\n" "${archive_path}" "${archive_size}"

  notify_success "Backup complete" \
    "Backup finished successfully.
Archive: ${archive_path}
Size:    ${archive_size}
Log:     ${TRMM_LOG_FILE}"

  # Remove error trap (success path)
  trap - ERR
}

# =============================================================================
# Main
# =============================================================================

main() {
  init_logging "backup"
  setup_error_trap
  require_not_root
  require_installation

  log_info "backup.sh SCRIPT_VERSION=${SCRIPT_VERSION}"
  log_info "Arguments: $*"

  case "${1:-}" in
    --schedule) do_schedule ;;
    --list)     do_list ;;
    --verify)   do_verify "${2:-}" ;;
    --auto)     do_backup true ;;
    *)          do_backup false ;;
  esac
}

main "$@"
