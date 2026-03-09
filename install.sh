#!/usr/bin/env bash
# =============================================================================
# TacticalRMM - Installation Script
# =============================================================================
#
# INTERACTIVE (default):
#   ./install.sh
#   ./install.sh --use-own-cert
#   ./install.sh --insecure
#
# AUTOMATED (set env vars, then run):
#   export TRMM_API_DOMAIN="api.example.com"
#   export TRMM_FRONTEND_DOMAIN="rmm.example.com"
#   export TRMM_MESH_DOMAIN="mesh.example.com"
#   export TRMM_ROOT_DOMAIN="example.com"
#   export TRMM_EMAIL="admin@example.com"
#   export TRMM_ADMIN_USER="admin"
#   export TRMM_CERT_MODE="letsencrypt"   # letsencrypt | insecure | custom
#   # For custom cert:
#   # export TRMM_CERT_FILE="/path/to/fullchain.pem"
#   # export TRMM_KEY_FILE="/path/to/privkey.pem"
#   ./install.sh --auto
#
# =============================================================================

SCRIPT_VERSION="90"
SCRIPT_URL="https://raw.githubusercontent.com/amidaware/tacticalrmm/master/install.sh"

# Bootstrap minimal deps before sourcing lib
sudo apt-get install -y --quiet curl wget jq dirmngr gnupg lsb-release ca-certificates \
  software-properties-common openssl 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

set -euo pipefail

# =============================================================================
# Self-update check
# =============================================================================

_self_update_check() {
  local tmp; tmp=$(mktemp -p "" "rmminstall_XXXXXXXXXX")
  curl -s -L "${SCRIPT_URL}" >"${tmp}"
  local new_ver; new_ver=$(grep "^SCRIPT_VERSION" "${tmp}" | awk -F'[="]' '{print $3}')
  if [[ "${SCRIPT_VERSION}" -ne "${new_ver}" ]]; then
    print_yellow "Old install script detected. Downloading latest version..."
    wget -q "${SCRIPT_URL}" -O install.sh
    print_yellow "Script updated. Please re-run ./install.sh"
    rm -f "${tmp}"
    exit 1
  fi
  rm -f "${tmp}"
}

# =============================================================================
# Paths / constants
# =============================================================================

PYTHON_VER='3.11.8'
SETTINGS_FILE='/rmm/api/tacticalrmm/tacticalrmm/settings.py'
local_settings='/rmm/api/tacticalrmm/tacticalrmm/local_settings.py'
SCRIPTS_DIR='/opt/trmm-community-scripts'

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# Argument parsing
# =============================================================================

AUTO_MODE=false
byocert=false
insecure=false
ssl_method=""   # http | dns | custom | insecure  (set interactively or via --auto)

for arg in "$@"; do
  case "${arg}" in
    --auto)          AUTO_MODE=true ;;
    --use-own-cert)  byocert=true; ssl_method="custom" ;;
    --insecure)      insecure=true; ssl_method="insecure" ;;
  esac
done

# =============================================================================
# Pre-flight checks
# =============================================================================

preflight_checks() {
  check_not_root
  check_virt
  check_arch
  check_ram
  check_locale
  check_os
  check_no_existing_install

  if ps aux | grep -v grep | grep -qi webmin; then
    print_error "Webmin is running. Remove it before installing TRMM."
    exit 1
  fi
}

# =============================================================================
# Input collection - interactive
# =============================================================================

collect_input_interactive() {
  cls

  printf "${GREEN}%0.s=${NC}" {1..80}; printf "\n"
  printf "${GREEN}  TacticalRMM Interactive Installer${NC}\n"
  printf "${GREEN}%0.s=${NC}" {1..80}; printf "\n\n"

  # ---- Domains ----
  while [[ "${rmmdomain:-}" != *[.]*[.]* ]]; do
    printf "${YELLOW}Backend API subdomain${NC} (e.g. api.example.com): "
    read -r rmmdomain
  done

  while [[ "${frontenddomain:-}" != *[.]*[.]* ]]; do
    printf "${YELLOW}Frontend subdomain${NC}   (e.g. rmm.example.com): "
    read -r frontenddomain
  done

  while [[ "${meshdomain:-}" != *[.]*[.]* ]]; do
    printf "${YELLOW}MeshCentral subdomain${NC} (e.g. mesh.example.com): "
    read -r meshdomain
  done

  printf "${YELLOW}Root domain${NC}           (e.g. example.com): "
  read -r rootdomain

  while [[ "${letsemail:-}" != *[@]*[.]* ]]; do
    printf "${YELLOW}Email address${NC} (for Let's Encrypt / MeshCentral): "
    read -r letsemail
  done

  # ---- SSL method selection ----
  printf "\n${GREEN}%0.s-${NC}" {1..80}; printf "\n"
  printf "${GREEN}  SSL Certificate Setup${NC}\n"
  printf "${GREEN}%0.s-${NC}" {1..80}; printf "\n\n"

  printf "  ${GREEN}1)${NC} Let's Encrypt - HTTP challenge ${YELLOW}(recommended)${NC}\n"
  printf "     Fully automated. Requires:\n"
  printf "       - All 3 subdomains DNS already pointing to this server's IP\n"
  printf "       - Port 80 open on this server\n\n"

  printf "  ${GREEN}2)${NC} Let's Encrypt - DNS challenge (wildcard)\n"
  printf "     Gets a wildcard cert (*.%s).\n" "${rootdomain}"
  printf "     Requires: adding a TXT record at your DNS provider (guided).\n\n"

  printf "  ${GREEN}3)${NC} Use my own certificate (bring your own cert)\n\n"

  printf "  ${GREEN}4)${NC} Self-signed / insecure (NOT for production)\n\n"

  local ssl_choice
  while true; do
    printf "${YELLOW}Choose SSL method [1-4]:${NC} "
    read -r ssl_choice
    case "${ssl_choice}" in
      1) ssl_method="http";     break ;;
      2) ssl_method="dns";      break ;;
      3) ssl_method="custom";   byocert=true; break ;;
      4) ssl_method="insecure"; insecure=true; break ;;
      *) printf "${RED}Invalid choice. Enter 1, 2, 3 or 4.${NC}\n" ;;
    esac
  done

  # ---- Custom cert paths ----
  if [[ "${ssl_method}" == "custom" ]]; then
    while true; do
      printf "${YELLOW}Full path to fullchain.pem:${NC} "
      read -r fullchain_path
      printf "${YELLOW}Full path to privkey.pem:${NC} "
      read -r privkey_path
      if [[ ! -f "${fullchain_path}" || ! -f "${privkey_path}" ]]; then
        print_error "One or both files do not exist. Try again."
        continue
      fi
      openssl x509 -in "${fullchain_path}" -noout >/dev/null \
        || { print_error "Not a valid certificate file."; exit 1; }
      break
    done
  fi
}

# =============================================================================
# Input collection - automated
# =============================================================================

collect_input_auto() {
  local required_vars=(TRMM_API_DOMAIN TRMM_FRONTEND_DOMAIN TRMM_MESH_DOMAIN
                        TRMM_ROOT_DOMAIN TRMM_EMAIL TRMM_ADMIN_USER)
  for v in "${required_vars[@]}"; do
    if [[ -z "${!v:-}" ]]; then
      print_error "Auto mode requires env var ${v} to be set."
      exit 1
    fi
  done

  rmmdomain="${TRMM_API_DOMAIN}"
  frontenddomain="${TRMM_FRONTEND_DOMAIN}"
  meshdomain="${TRMM_MESH_DOMAIN}"
  rootdomain="${TRMM_ROOT_DOMAIN}"
  letsemail="${TRMM_EMAIL}"
  djangousername="${TRMM_ADMIN_USER}"

  local cert_mode="${TRMM_CERT_MODE:-http}"
  case "${cert_mode}" in
    http)       ssl_method="http" ;;
    dns)        ssl_method="dns" ;;
    insecure)   ssl_method="insecure"; insecure=true ;;
    custom)     ssl_method="custom";   byocert=true
                fullchain_path="${TRMM_CERT_FILE:?TRMM_CERT_FILE required for custom cert mode}"
                privkey_path="${TRMM_KEY_FILE:?TRMM_KEY_FILE required for custom cert mode}"
                ;;
    letsencrypt) ssl_method="http" ;;   # backwards-compat alias
    *) print_error "TRMM_CERT_MODE must be: http | dns | insecure | custom"; exit 1 ;;
  esac

  print_green "Auto mode: using provided environment variables"
  log_info "  API domain:      ${rmmdomain}"
  log_info "  Frontend domain: ${frontenddomain}"
  log_info "  Mesh domain:     ${meshdomain}"
  log_info "  Root domain:     ${rootdomain}"
  log_info "  Email:           ${letsemail}"
  log_info "  Cert mode:       ${cert_mode}"
}

# =============================================================================
# Generate secrets
# =============================================================================

gen_secrets() {
  # tr|fold|head pipelines trigger SIGPIPE (exit 141) on fold/tr when head exits
  # after reading the first line. With set -o pipefail active this causes a
  # spurious failure. Disable pipefail only for these assignments.
  set +o pipefail
  DJANGO_SEKRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 80 | head -n 1)
  ADMINURL=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 70 | head -n 1)
  MESHPASSWD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 25 | head -n 1)
  pgusername=$(tr -dc 'a-z' </dev/urandom | fold -w 8 | head -n 1)
  pgpw=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 20 | head -n 1)
  meshusername=$(tr -dc 'a-z' </dev/urandom | fold -w 8 | head -n 1)
  MESHPGUSER=$(tr -dc 'a-z' </dev/urandom | fold -w 8 | head -n 1)
  MESHPGPWD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 20 | head -n 1)
  set -o pipefail
  log_info "Secrets generated."
}

# =============================================================================
# SSL / Certificates
# =============================================================================

# Check whether a hostname resolves to this server's public IP.
# Returns 0 if it matches, 1 otherwise.
_check_dns_resolves() {
  local host="$1"
  local server_ip
  # Get this server's public-facing IP
  server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || ip -4 addr show scope global | awk '/inet/{print $2}' | cut -d/ -f1 | head -1)

  local resolved_ip
  resolved_ip=$(getent hosts "${host}" 2>/dev/null | awk '{print $1}' | head -1)

  if [[ -z "${resolved_ip}" ]]; then
    log_warn "DNS: ${host} does not resolve to any IP"
    return 1
  fi

  if [[ "${resolved_ip}" != "${server_ip}" ]]; then
    log_warn "DNS: ${host} resolves to ${resolved_ip}, server IP is ${server_ip}"
    return 1
  fi

  log_info "DNS: ${host} -> ${resolved_ip} (OK)"
  return 0
}

# Verify DNS for all 3 subdomains, warn if any fail.
# Returns 0 if all pass, 1 if any fail.
_verify_all_dns() {
  local all_ok=true
  local server_ip
  server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || ip -4 addr show scope global | awk '/inet/{print $2}' | cut -d/ -f1 | head -1)

  printf "\n${BLUE}Checking DNS resolution for your subdomains...${NC}\n"
  printf "This server's IP: ${GREEN}%s${NC}\n\n" "${server_ip}"

  for domain in "${rmmdomain}" "${frontenddomain}" "${meshdomain}"; do
    local resolved
    resolved=$(getent hosts "${domain}" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ "${resolved}" == "${server_ip}" ]]; then
      printf "  ${GREEN}[OK]${NC} %-40s -> %s\n" "${domain}" "${resolved}"
    else
      printf "  ${RED}[!!]${NC} %-40s -> %s (expected %s)\n" \
        "${domain}" "${resolved:-NOT FOUND}" "${server_ip}"
      all_ok=false
    fi
  done
  printf "\n"
  "${all_ok}"
}

# Let's Encrypt via HTTP-01 challenge (fully automated, no DNS interaction).
# Requires: ports 80/443 open, all 3 subdomains pointing to this server.
_ssl_http01() {
  print_green "Let's Encrypt — HTTP-01 challenge (automated)"
  sudo apt-get install -y certbot

  # Verify DNS first
  if ! _verify_all_dns; then
    printf "${YELLOW}One or more subdomains do not resolve to this server.${NC}\n"
    printf "${YELLOW}Let's Encrypt HTTP challenge will fail if DNS is wrong.${NC}\n\n"
    printf "${YELLOW}Continue anyway? [y/N]:${NC} "
    read -r cont
    if [[ "${cont,,}" != "y" ]]; then
      print_error "Aborted. Fix DNS first, then re-run the installer."
      exit 1
    fi
  fi

  # Stop nginx if running so certbot standalone can bind to port 80
  sudo systemctl stop nginx 2>/dev/null || true

  print_green "Requesting certificate for all 3 subdomains"
  local attempt=0
  local max_attempts=3
  while [[ "${attempt}" -lt "${max_attempts}" ]]; do
    attempt=$(( attempt + 1 ))
    if sudo certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --no-eff-email \
        -m "${letsemail}" \
        -d "${rmmdomain}" \
        -d "${frontenddomain}" \
        -d "${meshdomain}"; then
      break
    fi
    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      print_yellow "Certbot attempt ${attempt} failed. Retrying in 10s..."
      sleep 10
    else
      print_error "Let's Encrypt HTTP challenge failed after ${max_attempts} attempts."
      print_error "Common causes:"
      print_error "  - Port 80 is blocked by a firewall"
      print_error "  - DNS does not point to this server"
      print_error "  - Rate limit reached (try again in 1 hour)"
      exit 1
    fi
  done

  # Cert is stored under the first domain
  CERT_PRIV_KEY="/etc/letsencrypt/live/${rmmdomain}/privkey.pem"
  CERT_PUB_KEY="/etc/letsencrypt/live/${rmmdomain}/fullchain.pem"
  sudo chown "${USER}:${USER}" -R /etc/letsencrypt
}

# Let's Encrypt via DNS-01 challenge (wildcard cert, manual TXT record).
_ssl_dns01() {
  print_green "Let's Encrypt — DNS-01 challenge (wildcard)"
  sudo apt-get install -y certbot

  printf "\n${YELLOW}%0.s*${NC}" {1..70}; printf "\n"
  printf "${YELLOW}MANUAL DNS STEP REQUIRED${NC}\n"
  printf "You will be asked to create a DNS TXT record:\n"
  printf "  Name:  ${GREEN}_acme-challenge.%s${NC}\n" "${rootdomain}"
  printf "  Value: (certbot will show it)\n\n"
  printf "Steps:\n"
  printf "  1. Certbot will display a TXT record value below.\n"
  printf "  2. Go to your DNS provider and add:\n"
  printf "       Type : TXT\n"
  printf "       Name : _acme-challenge.%s\n" "${rootdomain}"
  printf "       Value: <the value certbot shows>\n"
  printf "  3. Wait 1-2 minutes for DNS to propagate.\n"
  printf "  4. Press Enter in the certbot prompt to continue.\n"
  printf "${YELLOW}%0.s*${NC}" {1..70}; printf "\n\n"

  local attempt=0
  local max_attempts=3
  while [[ "${attempt}" -lt "${max_attempts}" ]]; do
    attempt=$(( attempt + 1 ))
    if sudo certbot certonly \
        --manual \
        --preferred-challenges dns \
        --agree-tos \
        --no-eff-email \
        -m "${letsemail}" \
        -d "*.${rootdomain}" \
        -d "${rootdomain}"; then
      break
    fi
    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      print_yellow "Certbot attempt ${attempt} failed."
      printf "${YELLOW}Retry? [Y/n]:${NC} "
      read -r retry
      [[ "${retry,,}" == "n" ]] && { print_error "Aborted."; exit 1; }
    else
      print_error "Let's Encrypt DNS challenge failed after ${max_attempts} attempts."
      exit 1
    fi
  done

  CERT_PRIV_KEY="/etc/letsencrypt/live/${rootdomain}/privkey.pem"
  CERT_PUB_KEY="/etc/letsencrypt/live/${rootdomain}/fullchain.pem"
  sudo chown "${USER}:${USER}" -R /etc/letsencrypt
}

# Verify certbot auto-renewal is active and install the nginx reload hook.
_setup_certbot_renewal() {
  install_letsencrypt_renewal_hook

  # On modern Debian/Ubuntu, certbot installs a systemd timer automatically.
  # Enable it if it exists and isn't already running.
  if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    sudo systemctl enable --now certbot.timer 2>/dev/null || true
    local timer_status
    timer_status=$(systemctl is-active certbot.timer 2>/dev/null || echo "inactive")
    if [[ "${timer_status}" == "active" ]]; then
      log_ok "certbot.timer is active — certificates will renew automatically"
    else
      log_warn "certbot.timer not active — adding fallback cron for renewal"
      # Fallback: add renewal cron if timer is not available
      (crontab -l 2>/dev/null | grep -v "certbot renew"; \
       echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'") \
        | crontab - || true
      log_info "Certbot renewal cron added (runs daily at 03:00)"
    fi
  else
    log_warn "certbot.timer not found — adding fallback cron for renewal"
    (crontab -l 2>/dev/null | grep -v "certbot renew"; \
     echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'") \
      | crontab - || true
    log_info "Certbot renewal cron added (runs daily at 03:00)"
  fi

  # Do a dry-run to confirm renewal will work
  print_green "Testing certificate auto-renewal (dry run)"
  if sudo certbot renew --dry-run --quiet 2>/dev/null; then
    log_ok "Auto-renewal dry-run passed"
  else
    log_warn "Auto-renewal dry-run had issues — check 'sudo certbot renew --dry-run' after install"
  fi
}

setup_ssl() {
  case "${ssl_method}" in

    http)
      _ssl_http01
      _setup_certbot_renewal
      ;;

    dns)
      _ssl_dns01
      _setup_certbot_renewal
      ;;

    custom)
      print_green "Using custom certificate"
      CERT_PRIV_KEY="${privkey_path}"
      CERT_PUB_KEY="${fullchain_path}"
      sudo chown "${USER}:${USER}" "${CERT_PRIV_KEY}" "${CERT_PUB_KEY}"
      ;;

    insecure)
      print_green "Generating self-signed certificate (insecure)"
      local certdir='/etc/ssl/tactical'
      sudo mkdir -p "${certdir}"
      sudo chown "${USER}:${USER}" "${certdir}"
      sudo chmod 770 "${certdir}"
      CERT_PRIV_KEY="${certdir}/key.pem"
      CERT_PUB_KEY="${certdir}/cert.pem"
      openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
        -nodes -keyout "${CERT_PRIV_KEY}" -out "${CERT_PUB_KEY}" \
        -subj "/CN=${rootdomain}" \
        -addext "subjectAltName=DNS:${rootdomain},DNS:*.${rootdomain}"
      ;;

    *)
      print_error "Unknown ssl_method '${ssl_method}'. This should not happen."
      exit 1
      ;;
  esac

  log_info "Certificates: pub=${CERT_PUB_KEY} priv=${CERT_PRIV_KEY}"
}

# =============================================================================
# Install: Nginx
# =============================================================================

install_nginx() {
  print_green "Installing Nginx"
  local osname codename
  osname=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
  codename=$(lsb_release -sc)

  sudo mkdir -p /etc/apt/keyrings
  wget -qO - https://nginx.org/keys/nginx_signing.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/${osname} ${codename} nginx" \
    | sudo tee /etc/apt/sources.list.d/nginx.list >/dev/null

  sudo apt-get update
  sudo apt-get install -y nginx
  sudo systemctl stop nginx

  for d in sites-available sites-enabled; do
    sudo mkdir -p "/etc/nginx/${d}"
  done

  sudo tee /etc/nginx/nginx.conf >/dev/null <<'NGINXMAIN'
worker_rlimit_nofile 1000000;
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 256;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXMAIN
}

# =============================================================================
# Install: NodeJS
# =============================================================================

install_nodejs() {
  print_green "Installing NodeJS"
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] \
https://deb.nodesource.com/node_20.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list
  sudo apt-get update
  sudo apt-get install -y gcc g++ make nodejs
  sudo npm install -g npm
}

# =============================================================================
# Install: Python
# =============================================================================

install_python() {
  print_green "Installing Python ${PYTHON_VER}"
  sudo apt-get install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
    libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev libbz2-dev
  local numprocs; numprocs=$(nproc)
  cd ~
  wget "https://www.python.org/ftp/python/${PYTHON_VER}/Python-${PYTHON_VER}.tgz"
  tar -xf "Python-${PYTHON_VER}.tgz"
  cd "Python-${PYTHON_VER}"
  ./configure --enable-optimizations
  make -j "${numprocs}"
  sudo make altinstall
  cd ~
  sudo rm -rf "Python-${PYTHON_VER}" "Python-${PYTHON_VER}.tgz"
}

# =============================================================================
# Install: PostgreSQL
# =============================================================================

install_postgresql() {
  print_green "Installing PostgreSQL 15"
  local pgarch; pgarch=$(pg_arch)
  local codename; codename=$(lsb_release -sc)

  echo "deb [arch=${pgarch} signed-by=/etc/apt/keyrings/postgresql-archive-keyring.gpg] \
https://apt.postgresql.org/pub/repos/apt/ ${codename}-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list

  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | sudo gpg --dearmor -o /etc/apt/keyrings/postgresql-archive-keyring.gpg

  sudo apt-get update
  sudo apt-get install -y postgresql-15
  sleep 2
  sudo systemctl enable --now postgresql

  until pg_isready >/dev/null 2>&1; do
    printf "${GREEN}Waiting for PostgreSQL...${NC}\n"
    sleep 3
  done
}

create_databases() {
  print_green "Creating databases"
  sudo -iu postgres psql -c "CREATE DATABASE tacticalrmm"
  sudo -iu postgres psql -c "CREATE USER ${pgusername} WITH PASSWORD '${pgpw}'"
  sudo -iu postgres psql -c "ALTER ROLE ${pgusername} SET client_encoding TO 'utf8'"
  sudo -iu postgres psql -c "ALTER ROLE ${pgusername} SET default_transaction_isolation TO 'read committed'"
  sudo -iu postgres psql -c "ALTER ROLE ${pgusername} SET timezone TO 'UTC'"
  sudo -iu postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE tacticalrmm TO ${pgusername}"
  sudo -iu postgres psql -c "ALTER DATABASE tacticalrmm OWNER TO ${pgusername}"
  sudo -iu postgres psql -c "GRANT USAGE, CREATE ON SCHEMA PUBLIC TO ${pgusername}"

  sudo -iu postgres psql -c "CREATE DATABASE meshcentral"
  sudo -iu postgres psql -c "CREATE USER ${MESHPGUSER} WITH PASSWORD '${MESHPGPWD}'"
  sudo -iu postgres psql -c "ALTER ROLE ${MESHPGUSER} SET client_encoding TO 'utf8'"
  sudo -iu postgres psql -c "ALTER ROLE ${MESHPGUSER} SET default_transaction_isolation TO 'read committed'"
  sudo -iu postgres psql -c "ALTER ROLE ${MESHPGUSER} SET timezone TO 'UTC'"
  sudo -iu postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE meshcentral TO ${MESHPGUSER}"
  sudo -iu postgres psql -c "ALTER DATABASE meshcentral OWNER TO ${MESHPGUSER}"
  sudo -iu postgres psql -c "GRANT USAGE, CREATE ON SCHEMA PUBLIC TO ${MESHPGUSER}"
}

# =============================================================================
# Install: NATS
# =============================================================================

install_nats() {
  print_green "Installing NATS Server"
  local natsarch; natsarch=$(nats_arch)
  local NATS_SERVER_VER; NATS_SERVER_VER=$(grep "^NATS_SERVER_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')
  local nats_tmp; nats_tmp=$(mktemp -d -t nats-XXXXXXXXXX)

  wget "https://github.com/nats-io/nats-server/releases/download/v${NATS_SERVER_VER}/nats-server-v${NATS_SERVER_VER}-linux-${natsarch}.tar.gz" \
    -P "${nats_tmp}"
  tar -xzf "${nats_tmp}/nats-server-v${NATS_SERVER_VER}-linux-${natsarch}.tar.gz" -C "${nats_tmp}"
  sudo mv "${nats_tmp}/nats-server-v${NATS_SERVER_VER}-linux-${natsarch}/nats-server" /usr/local/bin/
  sudo chmod +x /usr/local/bin/nats-server
  sudo chown "${USER}:${USER}" /usr/local/bin/nats-server
  rm -rf "${nats_tmp}"

  local natsapi
  [[ "$(uname -m)" == "x86_64" ]] && natsapi='nats-api' || natsapi='nats-api-arm64'
  sudo cp "/rmm/natsapi/bin/${natsapi}" /usr/local/bin/nats-api
  sudo chown "${USER}:${USER}" /usr/local/bin/nats-api
  sudo chmod +x /usr/local/bin/nats-api
}

# =============================================================================
# Install: MeshCentral
# =============================================================================

install_meshcentral() {
  print_green "Installing MeshCentral"
  local MESH_VER; MESH_VER=$(grep "^MESH_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')

  sudo mkdir -p /meshcentral/meshcentral-data
  sudo chown "${USER}:${USER}" -R /meshcentral

  cat >/meshcentral/package.json <<EOF
{
  "dependencies": {
    "archiver": "7.0.1",
    "meshcentral": "${MESH_VER}",
    "otplib": "10.2.3",
    "pg": "8.7.1",
    "pgtools": "0.3.2"
  }
}
EOF

  cat >/meshcentral/meshcentral-data/config.json <<EOF
{
  "settings": {
    "cert": "${meshdomain}",
    "WANonly": true,
    "minify": 1,
    "port": 4430,
    "aliasPort": 443,
    "redirPort": 800,
    "allowLoginToken": true,
    "allowFraming": true,
    "agentPing": 35,
    "allowHighQualityDesktop": true,
    "tlsOffload": "127.0.0.1",
    "agentCoreDump": false,
    "compression": false,
    "wsCompression": false,
    "agentWsCompression": false,
    "maxInvalidLogin": { "time": 5, "count": 5, "coolofftime": 30 },
    "postgres": {
      "user": "${MESHPGUSER}",
      "password": "${MESHPGPWD}",
      "port": "5432",
      "host": "localhost"
    }
  },
  "domains": {
    "": {
      "title": "Tactical RMM",
      "title2": "Tactical RMM",
      "newAccounts": false,
      "certUrl": "https://${meshdomain}:443/",
      "geoLocation": true,
      "cookieIpCheck": false,
      "mstsc": true
    }
  }
}
EOF

  cd /meshcentral
  npm install
}

# =============================================================================
# Clone repositories
# =============================================================================

clone_repos() {
  print_green "Cloning repositories"
  sudo mkdir /rmm
  sudo chown "${USER}:${USER}" /rmm
  sudo mkdir -p /var/log/celery
  sudo chown "${USER}:${USER}" /var/log/celery

  git clone https://github.com/amidaware/tacticalrmm.git /rmm/
  cd /rmm
  git config user.email "admin@example.com"
  git config user.name "Bob"
  git checkout master

  sudo mkdir -p "${SCRIPTS_DIR}"
  sudo chown "${USER}:${USER}" "${SCRIPTS_DIR}"
  git clone https://github.com/amidaware/community-scripts.git "${SCRIPTS_DIR}/"
  cd "${SCRIPTS_DIR}"
  git config user.email "admin@example.com"
  git config user.name "Bob"
  git checkout main
}

# =============================================================================
# Write local_settings.py
# =============================================================================

write_local_settings() {
  cat >"${local_settings}" <<EOF
SECRET_KEY = "${DJANGO_SEKRET}"

DEBUG = False

ALLOWED_HOSTS = ['${rmmdomain}']

ADMIN_URL = "${ADMINURL}/"

CORS_ORIGIN_WHITELIST = [
    "https://${frontenddomain}"
]

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'tacticalrmm',
        'USER': '${pgusername}',
        'PASSWORD': '${pgpw}',
        'HOST': 'localhost',
        'PORT': '5432',
    }
}

MESH_USERNAME = "${meshusername}"
MESH_SITE = "https://${meshdomain}"
ADMIN_ENABLED = True
EOF

  "${insecure}" && echo "TRMM_INSECURE = True" >>"${local_settings}"

  if "${byocert}" || "${insecure}"; then
    cat >>"${local_settings}" <<EOF
CERT_FILE = "${CERT_PUB_KEY}"
KEY_FILE = "${CERT_PRIV_KEY}"
EOF
  fi
}

# =============================================================================
# Install: Backend (Django/Celery)
# =============================================================================

install_backend() {
  print_green "Installing the backend"
  install_weasyprint_deps

  local SETUPTOOLS_VER; SETUPTOOLS_VER=$(grep "^SETUPTOOLS_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')
  local WHEEL_VER; WHEEL_VER=$(grep "^WHEEL_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')

  sudo mkdir -p /opt/tactical/reporting/assets /opt/tactical/reporting/schemas
  sudo chown -R "${USER}:${USER}" /opt/tactical

  cd /rmm/api
  python3.11 -m venv env
  source /rmm/api/env/bin/activate
  cd /rmm/api/tacticalrmm
  pip install --no-cache-dir pip==25.1
  pip install --no-cache-dir "setuptools==${SETUPTOOLS_VER}" "wheel==${WHEEL_VER}"
  pip install --no-cache-dir -r /rmm/api/tacticalrmm/requirements.txt
  python manage.py migrate
  python manage.py generate_json_schemas
  python manage.py collectstatic --no-input
  python manage.py create_natsapi_conf
  python manage.py create_uwsgi_conf
  python manage.py load_chocos
  python manage.py load_community_scripts
  WEB_VERSION=$(python manage.py get_config webversion)
  WEBTAR_URL=$(python manage.py get_webtar_url)
}

# =============================================================================
# Create admin user
# =============================================================================

create_admin_user() {
  print_green "Creating admin user"
  source /rmm/api/env/bin/activate
  cd /rmm/api/tacticalrmm

  if "${AUTO_MODE}" && [[ -n "${TRMM_ADMIN_PASS:-}" ]]; then
    # Non-interactive user creation
    python manage.py createsuperuser \
      --username "${djangousername}" \
      --email "${letsemail}" \
      --noinput
    python manage.py shell -c "
from django.contrib.auth import get_user_model
u = get_user_model().objects.get(username='${djangousername}')
u.set_password('${TRMM_ADMIN_PASS}')
u.save()
"
  else
    printf >&2 "\n${YELLOW}%0.s*${NC}" {1..80}; printf >&2 "\n"
    printf >&2 "${YELLOW}Create your RMM admin login:${NC}\n"
    printf >&2 "${YELLOW}%0.s*${NC}" {1..80}; printf >&2 "\n"
    printf "Username: "
    read -r djangousername
    python manage.py createsuperuser --username "${djangousername}" --email "${letsemail}"
  fi

  python manage.py create_installer_user
  RANDBASE=$(python manage.py generate_totp)
  cls
  python manage.py generate_barcode "${RANDBASE}" "${djangousername}" "${frontenddomain}"
  deactivate

  if ! "${AUTO_MODE}"; then
    read -n 1 -s -r -p "Press any key to continue..."
  fi
}

# =============================================================================
# Write systemd services
# =============================================================================

write_systemd_services() {
  print_green "Writing systemd service files"

  sudo tee /etc/systemd/system/rmm.service >/dev/null <<EOF
[Unit]
Description=tacticalrmm uwsgi daemon
After=network.target postgresql.service

[Service]
User=${USER}
Group=www-data
WorkingDirectory=/rmm/api/tacticalrmm
Environment="PATH=/rmm/api/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/rmm/api/env/bin/uwsgi --ini app.ini
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

  sudo tee /etc/systemd/system/daphne.service >/dev/null <<EOF
[Unit]
Description=uvicorn daemon v1
After=network.target

[Service]
User=${USER}
Group=www-data
WorkingDirectory=/rmm/api/tacticalrmm
Environment="PATH=/rmm/api/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/rmm/api/env/bin/uvicorn --uds /rmm/daphne.sock --forwarded-allow-ips='*' tacticalrmm.asgi:application
ExecStartPre=rm -f /rmm/daphne.sock
ExecStartPre=rm -f /rmm/daphne.sock.lock
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

  sudo tee /etc/systemd/system/nats.service >/dev/null <<EOF
[Unit]
Description=NATS Server
After=network.target

[Service]
PrivateTmp=true
Type=simple
ExecStart=/usr/local/bin/nats-server -c /rmm/api/tacticalrmm/nats-rmm.conf
ExecReload=/usr/bin/kill -s HUP \$MAINPID
ExecStop=/usr/bin/kill -s SIGINT \$MAINPID
User=${USER}
Group=${USER}
Restart=always
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

  sudo tee /etc/systemd/system/nats-api.service >/dev/null <<EOF
[Unit]
Description=TacticalRMM Nats Api v1
After=nats.service

[Service]
Type=simple
ExecStart=/usr/local/bin/nats-api
User=${USER}
Group=${USER}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  sudo mkdir -p /etc/conf.d

  sudo tee /etc/systemd/system/celery.service >/dev/null <<'EOF'
[Unit]
Description=Celery Service V2
After=network.target redis-server.service postgresql.service

[Service]
Type=forking
User=${USER}
Group=${USER}
EnvironmentFile=/etc/conf.d/celery.conf
WorkingDirectory=/rmm/api/tacticalrmm
ExecStart=/bin/sh -c '${CELERY_BIN} -A $CELERY_APP multi start $CELERYD_NODES --pidfile=${CELERYD_PID_FILE} --logfile=${CELERYD_LOG_FILE} --loglevel="${CELERYD_LOG_LEVEL}" $CELERYD_OPTS'
ExecStop=/bin/sh -c '${CELERY_BIN} multi stopwait $CELERYD_NODES --pidfile=${CELERYD_PID_FILE} --loglevel="${CELERYD_LOG_LEVEL}"'
ExecReload=/bin/sh -c '${CELERY_BIN} -A $CELERY_APP multi restart $CELERYD_NODES --pidfile=${CELERYD_PID_FILE} --logfile=${CELERYD_LOG_FILE} --loglevel="${CELERYD_LOG_LEVEL}" $CELERYD_OPTS'
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

  # Fix User/Group expansion in celery service (heredoc can't expand when using single quotes above
  # for other $vars, so we substitute after)
  sudo sed -i "s/^User=\${USER}/User=${USER}/; s/^Group=\${USER}/Group=${USER}/" \
    /etc/systemd/system/celery.service 2>/dev/null || true

  sudo tee /etc/conf.d/celery.conf >/dev/null <<EOF
CELERYD_NODES="w1"
CELERY_BIN="/rmm/api/env/bin/celery"
CELERY_APP="tacticalrmm"
CELERYD_MULTI="multi"
CELERYD_OPTS="--time-limit=86400 --autoscale=20,2"
CELERYD_PID_FILE="/rmm/api/tacticalrmm/%n.pid"
CELERYD_LOG_FILE="/var/log/celery/%n%I.log"
CELERYD_LOG_LEVEL="ERROR"
CELERYBEAT_PID_FILE="/rmm/api/tacticalrmm/beat.pid"
CELERYBEAT_LOG_FILE="/var/log/celery/beat.log"
EOF

  sudo tee /etc/systemd/system/celerybeat.service >/dev/null <<EOF
[Unit]
Description=Celery Beat Service V4
After=network.target redis-server.service postgresql.service

[Service]
Type=simple
User=${USER}
Group=${USER}
EnvironmentFile=/etc/conf.d/celery.conf
WorkingDirectory=/rmm/api/tacticalrmm
ExecStart=/bin/sh -c '\${CELERY_BIN} -A \${CELERY_APP} beat --pidfile=\${CELERYBEAT_PID_FILE} --logfile=\${CELERYBEAT_LOG_FILE} --loglevel=\${CELERYD_LOG_LEVEL}'
ExecStartPre=rm -f /rmm/api/tacticalrmm/beat.pid
ExecStartPre=rm -f /rmm/api/tacticalrmm/celerybeat-schedule
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

  sudo tee /etc/systemd/system/meshcentral.service >/dev/null <<EOF
[Unit]
Description=MeshCentral Server
After=network.target postgresql.service nginx.service

[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/usr/bin/node node_modules/meshcentral
Environment=NODE_ENV=production
WorkingDirectory=/meshcentral
User=${USER}
Group=${USER}
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

  sudo chown "${USER}:${USER}" -R /etc/conf.d/
  sudo systemctl daemon-reload
}

# =============================================================================
# Write Nginx configs
# =============================================================================

write_nginx_configs() {
  print_green "Writing Nginx configs"

  sudo tee /etc/nginx/sites-available/rmm.conf >/dev/null <<EOF
server_tokens off;

upstream tacticalrmm {
    server unix:////rmm/api/tacticalrmm/tacticalrmm.sock;
}

map \$http_user_agent \$ignore_ua {
    "~python-requests.*" 0;
    "~go-resty.*" 0;
    default 1;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${rmmdomain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl reuseport;
    listen [::]:443 ssl;
    server_name ${rmmdomain};
    client_max_body_size 300M;
    access_log /rmm/api/tacticalrmm/tacticalrmm/private/log/access.log combined if=\$ignore_ua;
    error_log /rmm/api/tacticalrmm/tacticalrmm/private/log/error.log;
    ssl_certificate ${CERT_PUB_KEY};
    ssl_certificate_key ${CERT_PRIV_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
    ssl_ecdh_curve secp384r1;
    add_header X-Content-Type-Options nosniff;

    location /static/ {
        root /rmm/api/tacticalrmm;
        add_header "Access-Control-Allow-Origin" "https://${frontenddomain}";
    }
    location /private/ {
        internal;
        add_header "Access-Control-Allow-Origin" "https://${frontenddomain}";
        alias /rmm/api/tacticalrmm/tacticalrmm/private/;
    }
    location /assets/ {
        internal;
        add_header "Access-Control-Allow-Origin" "https://${frontenddomain}";
        alias /opt/tactical/reporting/assets/;
    }
    location ~ ^/ws/ {
        proxy_pass http://unix:/rmm/daphne.sock;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$server_name;
    }
    location ~ ^/natsws {
        proxy_pass http://127.0.0.1:9235;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-Host \$host:\$server_port;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location / {
        uwsgi_pass tacticalrmm;
        include /etc/nginx/uwsgi_params;
        uwsgi_read_timeout 300s;
        uwsgi_ignore_client_abort on;
    }
}
EOF

  sudo tee /etc/nginx/sites-available/meshcentral.conf >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${meshdomain};
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    proxy_send_timeout 330s;
    proxy_read_timeout 330s;
    server_name ${meshdomain};
    ssl_certificate ${CERT_PUB_KEY};
    ssl_certificate_key ${CERT_PRIV_KEY};
    ssl_session_cache shared:WEBSSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
    ssl_ecdh_curve secp384r1;
    add_header X-Content-Type-Options nosniff;
    location / {
        proxy_pass http://127.0.0.1:4430/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-Host \$host:\$server_port;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  sudo tee /etc/nginx/sites-available/frontend.conf >/dev/null <<EOF
server {
    server_name ${frontenddomain};
    charset utf-8;
    location / {
        root /var/www/rmm/dist;
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        add_header Pragma "no-cache";
    }
    error_log  /var/log/nginx/frontend-error.log;
    access_log /var/log/nginx/frontend-access.log;
    listen 443 ssl;
    listen [::]:443 ssl;
    ssl_certificate ${CERT_PUB_KEY};
    ssl_certificate_key ${CERT_PRIV_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
    ssl_ecdh_curve secp384r1;
    add_header X-Content-Type-Options nosniff;
}
server {
    if (\$host = ${frontenddomain}) {
        return 301 https://\$host\$request_uri;
    }
    listen 80;
    listen [::]:80;
    server_name ${frontenddomain};
    return 404;
}
EOF

  for conf in rmm meshcentral frontend; do
    sudo ln -sf "/etc/nginx/sites-available/${conf}.conf" \
                "/etc/nginx/sites-enabled/${conf}.conf"
  done
}

# =============================================================================
# Install frontend
# =============================================================================

install_frontend() {
  print_green "Installing the frontend"
  local webtar="trmm-web-v${WEB_VERSION}.tar.gz"
  wget -q "${WEBTAR_URL}" -O "/tmp/${webtar}"
  sudo mkdir -p /var/www/rmm
  sudo tar -xzf "/tmp/${webtar}" -C /var/www/rmm
  echo "window._env_ = {PROD_URL: \"https://${rmmdomain}\"}" \
    | sudo tee /var/www/rmm/dist/env-config.js >/dev/null
  sudo chown www-data:www-data -R /var/www/rmm/dist
  rm -f "/tmp/${webtar}"
}

# =============================================================================
# Start and configure MeshCentral
# =============================================================================

configure_meshcentral() {
  print_green "Starting MeshCentral and waiting for it to be ready"
  sudo systemctl enable meshcentral
  sudo systemctl restart meshcentral
  sleep 3

  local CHECK_MESH_READY=""
  while [[ -z "${CHECK_MESH_READY}" ]]; do
    CHECK_MESH_READY=$(sudo journalctl -u meshcentral.service -b --no-pager 2>/dev/null \
      | grep "MeshCentral HTTP server running on port" || true)
    printf "${GREEN}MeshCentral not ready yet...${NC}\n"
    sleep 5
  done

  print_green "Generating MeshCentral login token key"
  MESHTOKENKEY=$(node /meshcentral/node_modules/meshcentral --logintokenkey)
  echo "MESH_TOKEN_KEY = \"${MESHTOKENKEY}\"" >> "${local_settings}"

  print_green "Creating MeshCentral account and device group"
  sudo systemctl stop meshcentral
  sleep 1
  cd /meshcentral
  node node_modules/meshcentral --createaccount "${meshusername}" \
    --pass "${MESHPASSWD}" --email "${letsemail}"
  sleep 1
  node node_modules/meshcentral --adminaccount "${meshusername}"
  sudo systemctl start meshcentral
  sleep 5

  local CHECK_MESH_READY2=""
  while [[ -z "${CHECK_MESH_READY2}" ]]; do
    CHECK_MESH_READY2=$(sudo journalctl -u meshcentral.service -b --no-pager 2>/dev/null \
      | grep "MeshCentral HTTP server running on port" || true)
    printf "${GREEN}MeshCentral not ready yet...${NC}\n"
    sleep 5
  done

  node node_modules/meshcentral/meshctrl.js \
    --url "wss://${meshdomain}:443" \
    --loginuser "${meshusername}" \
    --loginpass "${MESHPASSWD}" \
    AddDeviceGroup --name TacticalRMM
  sleep 1
}

# =============================================================================
# Fix /etc/hosts for cloud-init environments
# =============================================================================

fix_hosts() {
  if grep -q manage_etc_hosts /etc/hosts 2>/dev/null; then
    sudo sed -i '/manage_etc_hosts: true/d' /etc/cloud/cloud.cfg >/dev/null 2>&1 || true
    echo -e "\nmanage_etc_hosts: false" | sudo tee --append /etc/cloud/cloud.cfg >/dev/null
    sudo systemctl restart cloud-init >/dev/null 2>&1 || true
  fi

  local CHECK_HOSTS; CHECK_HOSTS=$(grep 127.0.1.1 /etc/hosts 2>/dev/null \
    | grep "${rmmdomain}" | grep "${meshdomain}" | grep "${frontenddomain}" || true)

  if [[ -z "${CHECK_HOSTS}" ]]; then
    local HAS_11; HAS_11=$(grep 127.0.1.1 /etc/hosts 2>/dev/null || true)
    if [[ -n "${HAS_11}" ]]; then
      sudo sed -i "/127.0.1.1/s/$/ ${rmmdomain} ${frontenddomain} ${meshdomain}/" /etc/hosts
    else
      echo "127.0.1.1 ${rmmdomain} ${frontenddomain} ${meshdomain}" \
        | sudo tee --append /etc/hosts >/dev/null
    fi
  fi
}

# =============================================================================
# Final NATS + DB setup
# =============================================================================

finalize_setup() {
  print_green "Finalizing setup"
  sudo systemctl enable nats.service
  cd /rmm/api/tacticalrmm
  source /rmm/api/env/bin/activate
  python manage.py initial_db_setup
  python manage.py reload_nats
  python manage.py sync_mesh_with_trmm
  deactivate

  sudo systemctl start nats.service
  sleep 1
  sudo systemctl enable nats-api.service
  sudo systemctl start nats-api.service

  # Disable Django admin after initial setup
  sed -i 's/ADMIN_ENABLED = True/ADMIN_ENABLED = False/g' "${local_settings}"
}

# =============================================================================
# Enable and start all services
# =============================================================================

enable_services() {
  print_green "Enabling and starting services"
  for svc in rmm.service daphne.service celery.service celerybeat.service nginx; do
    sudo systemctl enable "${svc}"
    sudo systemctl stop "${svc}" 2>/dev/null || true
    sudo systemctl start "${svc}"
  done

  sleep 5
  print_green "Restarting services"
  for svc in rmm.service daphne.service celery.service celerybeat.service; do
    sudo systemctl stop "${svc}"
    sudo systemctl start "${svc}"
  done
}

# =============================================================================
# Print summary
# =============================================================================

print_summary() {
  local BEHIND_NAT=false
  local IPV4; IPV4=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | head -1)
  if echo "${IPV4}" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
    BEHIND_NAT=true
  fi

  printf >&2 "\n${YELLOW}%0.s*${NC}" {1..80}; printf >&2 "\n\n"
  printf >&2 "${YELLOW}Installation complete!${NC}\n\n"
  printf >&2 "${YELLOW}Access RMM at:${NC}          ${GREEN}https://${frontenddomain}${NC}\n"
  printf >&2 "${YELLOW}MeshCentral username:${NC}   ${GREEN}${meshusername}${NC}\n"
  printf >&2 "${YELLOW}MeshCentral password:${NC}   ${GREEN}${MESHPASSWD}${NC}\n"
  printf >&2 "${YELLOW}Log file:${NC}               ${GREEN}${TRMM_LOG_FILE}${NC}\n\n"

  if "${BEHIND_NAT}"; then
    printf >&2 "${YELLOW}NOTE: Server is behind NAT (${IPV4}).${NC}\n"
    printf >&2 "Ensure port 443 is forwarded and your 3 subdomains resolve to your public IP.\n"
  fi
  printf >&2 "${YELLOW}%0.s*${NC}" {1..80}; printf >&2 "\n"

  notify_success "Installation complete" \
    "TacticalRMM installed successfully.
Frontend: https://${frontenddomain}
MeshCentral user: ${meshusername}
Log: ${TRMM_LOG_FILE}"
}

# =============================================================================
# Main
# =============================================================================

main() {
  fix_hostname
  init_logging "install"
  setup_error_trap

  log_info "install.sh SCRIPT_VERSION=${SCRIPT_VERSION}"
  log_info "Arguments: $*"

  _self_update_check

  sudo systemctl restart systemd-journald.service 2>/dev/null || true

  preflight_checks

  if "${AUTO_MODE}"; then
    collect_input_auto
  else
    collect_input_interactive
  fi

  gen_secrets
  fix_hosts
  setup_ssl

  install_nginx
  install_nodejs
  install_python
  sudo apt-get install -y redis git
  install_postgresql
  create_databases
  clone_repos
  install_nats
  install_meshcentral

  write_local_settings
  install_backend
  create_admin_user

  write_systemd_services
  write_nginx_configs

  if [[ -n "${WEB_VERSION:-}" ]]; then
    install_frontend
  fi

  enable_services
  configure_meshcentral
  finalize_setup

  if [[ -d ~/.npm ]]; then sudo chown -R "$USER:$GROUP" ~/.npm; fi
  if [[ -d ~/.config ]]; then sudo chown -R "$USER:$GROUP" ~/.config; fi

  print_summary
}

main "$@"
