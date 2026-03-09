#!/usr/bin/env bash
# =============================================================================
# TacticalRMM - Shared Library
# Source this file in all TRMM scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/common.sh"
# =============================================================================

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Paths
TRMM_LOG_DIR='/var/log/trmm'
TRMM_CONF_DIR='/etc/trmm'
NOTIFY_CONF="${TRMM_CONF_DIR}/notify.conf"
TRMM_LOG_FILE='/dev/null'   # overwritten by init_logging

# Notification defaults (overridden by notify.conf)
NOTIFY_EMAIL=""
NOTIFY_ON_SUCCESS=false
NOTIFY_ON_FAILURE=true

# =============================================================================
# Logging
# =============================================================================

_ensure_log_dir() {
  if [[ ! -d "${TRMM_LOG_DIR}" ]]; then
    sudo mkdir -p "${TRMM_LOG_DIR}"
    sudo chown "${USER}:${USER}" "${TRMM_LOG_DIR}"
  fi
}

# Call at the start of each script: init_logging "scriptname"
init_logging() {
  local name="${1:-trmm}"
  _ensure_log_dir
  TRMM_LOG_FILE="${TRMM_LOG_DIR}/${name}-$(date '+%Y%m%d_%H%M%S').log"
  export TRMM_LOG_FILE
  _raw_log "INFO " "=== ${name^^} started by ${USER} on $(hostname -f 2>/dev/null || hostname) at $(date) ==="
}

_raw_log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s [%s] %s\n' "${ts}" "${level}" "${msg}" >> "${TRMM_LOG_FILE}"
}

log_info()  { _raw_log "INFO " "$@"; }
log_ok()    { _raw_log "OK   " "$@"; printf "${GREEN}%s${NC}\n" "$*"; }
log_warn()  { _raw_log "WARN " "$@"; printf "${YELLOW}%s${NC}\n" "$*" >&2; }
log_error() { _raw_log "ERROR" "$@"; printf "${RED}%s${NC}\n" "$*" >&2; }

print_green() {
  printf >&2 "${GREEN}%0.s-${NC}" {1..80}; printf >&2 "\n"
  printf >&2 "${GREEN}%s${NC}\n" "$1"
  printf >&2 "${GREEN}%0.s-${NC}" {1..80}; printf >&2 "\n"
  log_info ">>> $1"
}
print_error()  { printf >&2 "${RED}%s${NC}\n"    "$1"; log_error "$1"; }
print_yellow() { printf >&2 "${YELLOW}%s${NC}\n" "$1"; log_warn  "$1"; }

cls() { printf "\033c"; }

# =============================================================================
# Email Notifications
# =============================================================================

load_notify_conf() {
  if [[ -f "${NOTIFY_CONF}" ]]; then
    # shellcheck source=/dev/null
    source "${NOTIFY_CONF}"
  fi
}

# Usage: send_notification "Subject line" "Body text"
send_notification() {
  local subject="$1"
  local body="$2"
  load_notify_conf

  [[ -z "${NOTIFY_EMAIL}" ]] && return 0

  local host; host=$(hostname -f 2>/dev/null || hostname)
  local full_subject="[TacticalRMM @ ${host}] ${subject}"
  local full_body
  full_body="Host:    ${host}
Date:    $(date)
Log:     ${TRMM_LOG_FILE}
Script:  ${BASH_SOURCE[1]:-unknown}

${body}"

  log_info "Sending email notification to ${NOTIFY_EMAIL}: ${subject}"

  if command -v msmtp >/dev/null 2>&1; then
    printf 'To: %s\nSubject: %s\n\n%s\n' \
      "${NOTIFY_EMAIL}" "${full_subject}" "${full_body}" \
      | msmtp "${NOTIFY_EMAIL}" 2>>"${TRMM_LOG_FILE}" || true
  elif command -v mail >/dev/null 2>&1; then
    echo "${full_body}" | mail -s "${full_subject}" "${NOTIFY_EMAIL}" 2>>"${TRMM_LOG_FILE}" || true
  elif command -v sendmail >/dev/null 2>&1; then
    printf 'To: %s\nSubject: %s\n\n%s\n' \
      "${NOTIFY_EMAIL}" "${full_subject}" "${full_body}" \
      | sendmail -t 2>>"${TRMM_LOG_FILE}" || true
  else
    log_warn "No mail agent found (msmtp/mail/sendmail). Email not sent."
  fi
}

notify_success() {
  load_notify_conf
  "${NOTIFY_ON_SUCCESS}" && send_notification "SUCCESS: $1" "${2:-}" || true
}

notify_failure() {
  load_notify_conf
  "${NOTIFY_ON_FAILURE}" && send_notification "FAILURE: $1" "${2:-}" || true
}

# =============================================================================
# Error Trap
# =============================================================================

_on_error() {
  local exit_code=$?
  local line_no="${1:-?}"
  local script="${2:-${BASH_SOURCE[0]}}"
  local msg="Script failed at line ${line_no} in $(basename "${script}") (exit code: ${exit_code})"
  log_error "${msg}"
  notify_failure "Script error" "${msg}

Check the log for details: ${TRMM_LOG_FILE}"
}

setup_error_trap() {
  trap '_on_error ${LINENO} "${BASH_SOURCE[0]}"' ERR
}

# =============================================================================
# Common Pre-flight Checks
# =============================================================================

check_not_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    print_error "Do NOT run this script as root. Exiting."
    exit 1
  fi
}

check_virt() {
  local virt_type; virt_type=$(systemd-detect-virt 2>/dev/null || true)
  if [[ "${virt_type}" == "lxc" ]]; then
    print_error "LXC is not supported. Use a VM instead."
    exit 1
  fi
}

check_arch() {
  local arch; arch=$(uname -m)
  if [[ "${arch}" != "x86_64" ]] && [[ "${arch}" != "aarch64" ]]; then
    print_error "Only x86_64 and aarch64 are supported, not ${arch}."
    exit 1
  fi
}

check_ram() {
  local kb; kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  if [[ "${kb}" -lt 3627528 ]]; then
    print_error "A minimum of 4 GB of RAM is required."
    exit 1
  fi
}

check_locale() {
  if [[ "${LANG:-}" != *".UTF-8" ]]; then
    print_error "System locale must be <language>.UTF-8 (current: ${LANG:-unset})"
    printf >&2 "Run: sudo dpkg-reconfigure locales\nLog out and back in, then re-run.\n"
    exit 1
  fi
}

check_os() {
  local osname relno fullrelno
  osname=$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]')
  relno=$(lsb_release -sr 2>/dev/null | cut -d. -f1)
  fullrelno=$(lsb_release -sr 2>/dev/null)

  local ok=false
  if [[ "${osname}" == "debian" ]] && { [[ "${relno}" -eq 11 ]] || [[ "${relno}" -eq 12 ]]; }; then
    ok=true
  elif [[ "${osname}" == "ubuntu" ]] && [[ "${fullrelno}" == "22.04" ]]; then
    ok=true
  fi

  if ! "${ok}"; then
    print_error "Only Debian 11, Debian 12 and Ubuntu 22.04 are supported."
    exit 1
  fi

  if dpkg -l 2>/dev/null | grep -qi turnkey; then
    print_error "Turnkey Linux is not supported. Use the official Debian/Ubuntu ISO."
    exit 1
  fi

  if ps aux | grep -v grep | grep -qi webmin; then
    print_error "Webmin is running and must be removed before installing TRMM."
    exit 1
  fi
}

check_no_existing_install() {
  if [[ -d /rmm/api/tacticalrmm ]]; then
    print_error "Existing TRMM installation found. This script must run on a clean server."
    exit 1
  fi
}

# =============================================================================
# Architecture helpers
# =============================================================================

pg_arch() { [[ "$(uname -m)" == "x86_64" ]] && echo 'amd64' || echo 'arm64'; }
nats_arch() { [[ "$(uname -m)" == "x86_64" ]] && echo 'amd64' || echo 'arm64'; }

# =============================================================================
# Dependency helpers
# =============================================================================

install_weasyprint_deps() {
  local osname; osname=$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ "${osname}" == "debian" ]]; then
    local c; c=$(dpkg -l 2>/dev/null | grep -cE "libpango-1\.0-0|libpangoft2-1\.0-0" || true)
    [[ "${c}" -lt 2 ]] && sudo apt-get install -y libpango-1.0-0 libpangoft2-1.0-0
  elif [[ "${osname}" == "ubuntu" ]]; then
    local c; c=$(dpkg -l 2>/dev/null | grep -cE "libpango-1\.0-0|libharfbuzz0b|libpangoft2-1\.0-0" || true)
    [[ "${c}" -lt 3 ]] && sudo apt-get install -y libpango-1.0-0 libharfbuzz0b libpangoft2-1.0-0
  fi
}

# =============================================================================
# Service helpers
# =============================================================================

TRMM_SERVICES=(rmm daphne celery celerybeat nats nats-api meshcentral nginx)

stop_all_services() {
  log_info "Stopping all TRMM services..."
  for svc in "${TRMM_SERVICES[@]}"; do
    sudo systemctl stop "${svc}" 2>/dev/null || true
  done
}

start_core_services() {
  log_info "Starting core TRMM services..."
  for svc in nats nats-api rmm daphne celery celerybeat nginx; do
    sudo systemctl start "${svc}" 2>/dev/null || true
  done
}

# =============================================================================
# Let's Encrypt renewal hook
# =============================================================================

install_letsencrypt_renewal_hook() {
  local hook_dir='/etc/letsencrypt/renewal-hooks/deploy'
  sudo mkdir -p "${hook_dir}"
  sudo tee "${hook_dir}/trmm-reload.sh" >/dev/null <<'HOOK'
#!/usr/bin/env bash
# Reload nginx after Let's Encrypt cert renewal
systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
HOOK
  sudo chmod +x "${hook_dir}/trmm-reload.sh"
  log_info "Let's Encrypt deploy hook installed at ${hook_dir}/trmm-reload.sh"
}
