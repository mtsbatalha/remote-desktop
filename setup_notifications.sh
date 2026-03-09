#!/usr/bin/env bash
# =============================================================================
# TacticalRMM - Email Notification Setup
# Configures email alerts for install/update/backup/restore scripts.
# Supports msmtp (recommended), mailutils, or sendmail.
#
# Usage:
#   ./setup_notifications.sh           # interactive setup
#   ./setup_notifications.sh --test    # send a test email
#   ./setup_notifications.sh --show    # show current config
#   ./setup_notifications.sh --remove  # remove notification config
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TRMM_CONF_DIR='/etc/trmm'
NOTIFY_CONF="${TRMM_CONF_DIR}/notify.conf"
MSMTP_CONF='/etc/msmtprc'

# =============================================================================
# Helpers
# =============================================================================

require_not_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    print_error "Do NOT run this script as root."
    exit 1
  fi
}

ensure_conf_dir() {
  if [[ ! -d "${TRMM_CONF_DIR}" ]]; then
    sudo mkdir -p "${TRMM_CONF_DIR}"
    sudo chown "${USER}:${USER}" "${TRMM_CONF_DIR}"
  fi
}

prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local input

  if [[ -n "${default}" ]]; then
    printf "${YELLOW}%s${NC} [%s]: " "${prompt_text}" "${default}"
  else
    printf "${YELLOW}%s${NC}: " "${prompt_text}"
  fi

  read -r input
  if [[ -z "${input}" ]] && [[ -n "${default}" ]]; then
    input="${default}"
  fi
  printf -v "${var_name}" '%s' "${input}"
}

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local input

  printf "${YELLOW}%s${NC}: " "${prompt_text}"
  read -rs input
  printf "\n"
  printf -v "${var_name}" '%s' "${input}"
}

# =============================================================================
# Install mail agent
# =============================================================================

install_msmtp() {
  print_green "Installing msmtp"
  sudo apt-get update -qq
  sudo apt-get install -y msmtp msmtp-mta ca-certificates
}

configure_msmtp() {
  local smtp_host="$1"
  local smtp_port="$2"
  local smtp_user="$3"
  local smtp_pass="$4"
  local from_addr="$5"
  local tls_mode="$6"   # on | off

  local tls_cfg
  if [[ "${tls_mode}" == "on" ]]; then
    tls_cfg="tls on
tls_starttls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt"
  else
    tls_cfg="tls off"
  fi

  sudo tee "${MSMTP_CONF}" >/dev/null <<MSMTPRC
# msmtp configuration - managed by TacticalRMM setup_notifications.sh
defaults
auth           on
${tls_cfg}
logfile        /var/log/trmm/msmtp.log

account        trmm
host           ${smtp_host}
port           ${smtp_port}
from           ${from_addr}
user           ${smtp_user}
password       ${smtp_pass}

account default : trmm
MSMTPRC

  sudo chmod 600 "${MSMTP_CONF}"
  sudo chown root:root "${MSMTP_CONF}"
  print_green "msmtp configured at ${MSMTP_CONF}"
}

# =============================================================================
# Save notification config
# =============================================================================

save_notify_conf() {
  local email="$1"
  local on_success="$2"
  local on_failure="$3"

  ensure_conf_dir
  cat >"${NOTIFY_CONF}" <<CONF
# TacticalRMM notification config - managed by setup_notifications.sh
# Edit manually or re-run setup_notifications.sh

NOTIFY_EMAIL="${email}"
NOTIFY_ON_SUCCESS=${on_success}
NOTIFY_ON_FAILURE=${on_failure}
CONF
  chmod 640 "${NOTIFY_CONF}"
  print_green "Notification config saved to ${NOTIFY_CONF}"
}

# =============================================================================
# Actions
# =============================================================================

show_config() {
  if [[ ! -f "${NOTIFY_CONF}" ]]; then
    echo "No notification config found at ${NOTIFY_CONF}."
    exit 0
  fi
  printf "${GREEN}Current notification config:${NC}\n"
  cat "${NOTIFY_CONF}"
}

remove_config() {
  printf "${YELLOW}This will remove ${NOTIFY_CONF}. Continue? [y/N]${NC} "
  read -r confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Aborted."
    exit 0
  fi
  rm -f "${NOTIFY_CONF}"
  print_green "Notification config removed."
}

send_test_email() {
  load_notify_conf
  if [[ -z "${NOTIFY_EMAIL}" ]]; then
    print_error "No NOTIFY_EMAIL configured. Run setup_notifications.sh first."
    exit 1
  fi
  # Temporarily set log file for test
  TRMM_LOG_FILE='/var/log/trmm/setup_notifications.log'
  send_notification "Test notification" "This is a test notification from TacticalRMM.
If you received this, email notifications are working correctly."
  print_green "Test email sent to ${NOTIFY_EMAIL}."
}

interactive_setup() {
  cls
  printf "${GREEN}%0.s=${NC}" {1..80}; printf "\n"
  printf "${GREEN}  TacticalRMM - Email Notification Setup${NC}\n"
  printf "${GREEN}%0.s=${NC}" {1..80}; printf "\n\n"

  # Check for existing config
  if [[ -f "${NOTIFY_CONF}" ]]; then
    printf "${YELLOW}Existing config found. Overwrite? [y/N]${NC} "
    read -r ow
    [[ "${ow,,}" != "y" ]] && { echo "Aborted."; exit 0; }
  fi

  # Choose mail agent
  printf "\n${YELLOW}Select mail agent:${NC}\n"
  printf "  1) msmtp (recommended - supports Gmail, Office 365, etc.)\n"
  printf "  2) Use existing system sendmail/mail\n"
  printf "  3) Skip mail agent setup (just configure notification recipients)\n"
  printf "${YELLOW}Choice [1]:${NC} "
  read -r agent_choice
  agent_choice="${agent_choice:-1}"

  if [[ "${agent_choice}" == "1" ]]; then
    if ! command -v msmtp >/dev/null 2>&1; then
      install_msmtp
    else
      printf "${GREEN}msmtp is already installed.${NC}\n"
    fi

    printf "\n${GREEN}Configure SMTP relay:${NC}\n"
    printf "  Common examples:\n"
    printf "  - Gmail:      smtp.gmail.com  port 587 (use App Password)\n"
    printf "  - Office 365: smtp.office365.com  port 587\n"
    printf "  - SendGrid:   smtp.sendgrid.net  port 587\n\n"

    prompt smtp_host "SMTP server hostname" "smtp.gmail.com"
    prompt smtp_port "SMTP port" "587"
    prompt smtp_user "SMTP username / email"
    prompt_secret smtp_pass "SMTP password / app password"
    prompt from_addr "From address" "${smtp_user}"

    printf "${YELLOW}Use TLS/STARTTLS? [Y/n]${NC} "
    read -r use_tls
    use_tls="${use_tls:-Y}"
    tls_mode="on"; [[ "${use_tls,,}" == "n" ]] && tls_mode="off"

    configure_msmtp "${smtp_host}" "${smtp_port}" "${smtp_user}" "${smtp_pass}" "${from_addr}" "${tls_mode}"
  fi

  # Notification preferences
  printf "\n${GREEN}Notification preferences:${NC}\n"
  prompt notify_email "Recipient email address"
  printf "${YELLOW}Notify on SUCCESS (backups, updates)? [y/N]${NC} "
  read -r ns; on_success=false; [[ "${ns,,}" == "y" ]] && on_success=true
  printf "${YELLOW}Notify on FAILURE? [Y/n]${NC} "
  read -r nf; on_failure=true; [[ "${nf,,}" == "n" ]] && on_failure=false

  save_notify_conf "${notify_email}" "${on_success}" "${on_failure}"

  # Test email
  printf "\n${YELLOW}Send a test email now? [Y/n]${NC} "
  read -r do_test
  if [[ "${do_test,,}" != "n" ]]; then
    TRMM_LOG_FILE="${TRMM_LOG_DIR}/setup_notifications.log"
    _ensure_log_dir
    touch "${TRMM_LOG_FILE}"
    send_notification "Test notification" "TacticalRMM notifications are configured and working."
    print_green "Test email sent to ${notify_email}."
  fi

  printf "\n${GREEN}Setup complete!${NC}\n"
  printf "All TRMM scripts will now send notifications to ${YELLOW}${notify_email}${NC}.\n\n"
}

# =============================================================================
# Main
# =============================================================================

require_not_root

case "${1:-}" in
  --test)   send_test_email ;;
  --show)   show_config ;;
  --remove) remove_config ;;
  *)        interactive_setup ;;
esac
