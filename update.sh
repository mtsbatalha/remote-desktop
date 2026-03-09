#!/usr/bin/env bash
# =============================================================================
# TacticalRMM - Update Script
# =============================================================================
#
# Usage:
#   ./update.sh           # normal update
#   ./update.sh --force   # force re-install even if already on latest version
#
# =============================================================================

SCRIPT_VERSION="158"
SCRIPT_URL='https://raw.githubusercontent.com/amidaware/tacticalrmm/master/update.sh'
LATEST_SETTINGS_URL='https://raw.githubusercontent.com/amidaware/tacticalrmm/master/api/tacticalrmm/tacticalrmm/settings.py'

THIS_SCRIPT=$(readlink -f "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

set -euo pipefail

PYTHON_VER='3.11.8'
SETTINGS_FILE='/rmm/api/tacticalrmm/tacticalrmm/settings.py'
local_settings='/rmm/api/tacticalrmm/tacticalrmm/local_settings.py'
SCRIPTS_DIR='/opt/trmm-community-scripts'
export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# Self-update check
# =============================================================================

_self_update_check() {
  local tmp; tmp=$(mktemp -p "" "rmmupdate_XXXXXXXXXX")
  curl -s -L "${SCRIPT_URL}" >"${tmp}"
  local new_ver; new_ver=$(grep "^SCRIPT_VERSION" "${tmp}" | awk -F'[="]' '{print $3}')
  if [[ "${SCRIPT_VERSION}" -ne "${new_ver}" ]]; then
    print_yellow "Old update script detected. Downloading latest version..."
    wget -q "${SCRIPT_URL}" -O "${THIS_SCRIPT}"
    rm -f "${tmp}"
    log_info "Script updated to v${new_ver}. Re-executing..."
    exec "${THIS_SCRIPT}" "$@"
  fi
  rm -f "${tmp}"
}

# =============================================================================
# Pre-flight
# =============================================================================

preflight() {
  check_not_root

  local strip="User="
  local ORIGUSER; ORIGUSER=$(grep "${strip}" /etc/systemd/system/rmm.service | sed -e "s/^${strip}//")
  if [[ "${ORIGUSER}" != "${USER}" ]]; then
    print_error "You must run this update script from the same user account used during install: ${ORIGUSER}"
    exit 1
  fi

  if [[ ! -d /etc/apt/keyrings ]]; then
    sudo mkdir -p /etc/apt/keyrings
  fi
}

# =============================================================================
# Version check
# =============================================================================

version_check() {
  local TMP_SETTINGS; TMP_SETTINGS=$(mktemp -p "" "rmmsettings_XXXXXXXXXX")
  curl -s -L "${LATEST_SETTINGS_URL}" >"${TMP_SETTINGS}"

  LATEST_TRMM_VER=$(grep "^TRMM_VERSION" "${TMP_SETTINGS}" | awk -F'[= "]' '{print $5}')
  CURRENT_TRMM_VER=$(grep "^TRMM_VERSION" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')
  LATEST_MESH_VER=$(grep "^MESH_VER" "${TMP_SETTINGS}" | awk -F'[= "]' '{print $5}')
  LATEST_PIP_VER=$(grep "^PIP_VER" "${TMP_SETTINGS}" | awk -F'[= "]' '{print $5}')
  NATS_SERVER_VER=$(grep "^NATS_SERVER_VER" "${TMP_SETTINGS}" | awk -F'[= "]' '{print $5}')
  CURRENT_PIP_VER=$(grep "^PIP_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')

  rm -f "${TMP_SETTINGS}"

  log_info "Current TRMM version: ${CURRENT_TRMM_VER} | Latest: ${LATEST_TRMM_VER}"
  log_info "Current pip version:  ${CURRENT_PIP_VER}  | Latest: ${LATEST_PIP_VER}"
  log_info "Latest Mesh version:  ${LATEST_MESH_VER}"
  log_info "Latest NATS version:  ${NATS_SERVER_VER}"

  if [[ "${CURRENT_TRMM_VER}" == "${LATEST_TRMM_VER}" ]] && ! "${force}"; then
    print_green "Already on latest version (${CURRENT_TRMM_VER}). Use --force to re-run anyway."
    notify_success "Update skipped" "Already on latest TRMM version: ${CURRENT_TRMM_VER}"
    exit 0
  fi
}

# =============================================================================
# Fix / migrate systemd services if outdated
# =============================================================================

migrate_services() {
  # Ensure nats.service has LimitNOFILE
  if ! grep -q LimitNOFILE /etc/systemd/system/nats.service 2>/dev/null; then
    log_info "Updating nats.service to add LimitNOFILE"
    sudo rm -f /etc/systemd/system/nats.service
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
Group=www-data
Restart=always
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
  fi

  # Migrate celerybeat to V4
  if ! grep -q V4 /etc/systemd/system/celerybeat.service 2>/dev/null; then
    log_info "Updating celerybeat.service to V4"
    sudo rm -f /etc/systemd/system/celerybeat.service
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
    sudo systemctl daemon-reload
  fi

  # Migrate daphne -> uvicorn
  if ! grep -q uvicorn /etc/systemd/system/daphne.service 2>/dev/null; then
    log_info "Migrating daphne.service to uvicorn"
    sudo rm -f /etc/systemd/system/daphne.service
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
    sudo systemctl daemon-reload
  fi
}

# =============================================================================
# Update Nginx
# =============================================================================

update_nginx() {
  local osname; osname=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
  local codename; codename=$(lsb_release -sc)

  # Add nginx repo if missing
  if [[ ! -f /etc/apt/sources.list.d/nginx.list ]]; then
    log_info "Adding nginx apt repository"
    echo "deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/${osname} ${codename} nginx" \
      | sudo tee /etc/apt/sources.list.d/nginx.list >/dev/null
    wget -qO - https://nginx.org/keys/nginx_signing.key \
      | sudo gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg
    sudo apt-get update
    sudo apt-get install -y nginx
  fi

  # Renew expired nginx signing key
  if [[ -f /etc/apt/keyrings/nginx-archive-keyring.gpg ]]; then
    local expired; expired=$(gpg --dry-run --quiet --no-keyring \
      --import --import-options import-show \
      /etc/apt/keyrings/nginx-archive-keyring.gpg 2>/dev/null \
      | grep -B1 573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 \
      | grep expired || true)
    if [[ -n "${expired}" ]]; then
      log_info "Nginx GPG key expired — refreshing"
      sudo rm -f /etc/apt/keyrings/nginx-archive-keyring.gpg
      wget -qO - https://nginx.org/keys/nginx_signing.key \
        | sudo gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg
      sudo apt-get update
    fi
  fi

  # Tune nginx.conf
  local nginxconf='/etc/nginx/nginx.conf'
  if ! grep -q "worker_connections 4096" "${nginxconf}" 2>/dev/null; then
    log_info "Increasing nginx worker_connections to 4096"
    sudo sed -i 's/worker_connections.*/worker_connections 4096;/g' "${nginxconf}"
  fi
  if ! grep -q "worker_rlimit_nofile 1000000" "${nginxconf}" 2>/dev/null; then
    log_info "Increasing nginx worker_rlimit_nofile to 1000000"
    sudo sed -i '/worker_rlimit_nofile.*/d' "${nginxconf}"
    sudo sed -i '1s/^/worker_rlimit_nofile 1000000;\n/' "${nginxconf}"
  fi
  sudo sed -i 's/# server_names_hash_bucket_size.*/server_names_hash_bucket_size 256;/g' "${nginxconf}" || true

  # Add sites-enabled include if missing
  if ! grep -q "sites-enabled" "${nginxconf}" 2>/dev/null; then
    log_info "Fixing nginx.conf to include sites-enabled"
    sudo tee "${nginxconf}" >/dev/null <<'NGINXMAIN'
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
  fi

  # Validate nginx config before continuing
  if ! sudo nginx -t >/dev/null 2>&1; then
    sudo nginx -t
    print_error "Nginx config has errors (see above). Fix them and re-run the update."
    exit 1
  fi
}

# =============================================================================
# Update rmm.conf if /assets/ location is missing
# =============================================================================

update_nginx_rmm_conf() {
  local rmmconf='/etc/nginx/sites-available/rmm.conf'
  if grep -q "location /assets/" "${rmmconf}" 2>/dev/null; then
    return 0
  fi

  print_yellow "Updating ${rmmconf} — adding /assets/ location (backup saved to ~/rmm.conf.nginx.bak)"
  cp "${rmmconf}" ~/rmm.conf.nginx.bak

  local API FRONTEND CERT_PUB_KEY CERT_PRIV_KEY
  source /rmm/api/env/bin/activate
  API=$(python /rmm/api/tacticalrmm/manage.py get_config api)
  FRONTEND=$(python /rmm/api/tacticalrmm/manage.py get_config webdomain)
  CERT_PUB_KEY=$(python /rmm/api/tacticalrmm/manage.py get_config certfile)
  CERT_PRIV_KEY=$(python /rmm/api/tacticalrmm/manage.py get_config keyfile)
  deactivate

  sudo tee "${rmmconf}" >/dev/null <<EOF
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
    server_name ${API};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl reuseport;
    listen [::]:443 ssl;
    server_name ${API};
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
        add_header "Access-Control-Allow-Origin" "https://${FRONTEND}";
    }
    location /private/ {
        internal;
        add_header "Access-Control-Allow-Origin" "https://${FRONTEND}";
        alias /rmm/api/tacticalrmm/tacticalrmm/private/;
    }
    location /assets/ {
        internal;
        add_header "Access-Control-Allow-Origin" "https://${FRONTEND}";
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
  log_info "rmm.conf updated with /assets/ location"
}

# =============================================================================
# Remove ssl_stapling (deprecated)
# =============================================================================

remove_ssl_stapling() {
  for site in rmm frontend meshcentral; do
    local conf="/etc/nginx/sites-enabled/${site}.conf"
    if [[ -f "${conf}" ]] && grep -q "ssl_stapling" "${conf}"; then
      cp "${conf}" ~/${site}.nginx.bak.v1.2.0
      sudo sed -i '/ssl_stapling/d' "${conf}"
      log_info "Removed ssl_stapling from ${conf}"
    fi
  done
}

# =============================================================================
# Update Python
# =============================================================================

update_python() {
  if python3.11 --version 2>/dev/null | grep -q "${PYTHON_VER}"; then
    log_info "Python ${PYTHON_VER} already installed"
    return 0
  fi

  print_green "Updating Python to ${PYTHON_VER}"
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
# Update NATS
# =============================================================================

update_nats() {
  local current_ver; current_ver=$(/usr/local/bin/nats-server -version 2>/dev/null | grep -o '[0-9]*\.[0-9]*\.[0-9]*' || echo "0.0.0")
  if [[ "${current_ver}" == "${NATS_SERVER_VER}" ]] && ! "${force}"; then
    log_info "NATS already at v${NATS_SERVER_VER}"
    return 0
  fi

  print_green "Updating NATS to v${NATS_SERVER_VER}"
  local natsarch; natsarch=$(nats_arch)
  local nats_tmp; nats_tmp=$(mktemp -d -t nats-XXXXXXXXXX)
  wget "https://github.com/nats-io/nats-server/releases/download/v${NATS_SERVER_VER}/nats-server-v${NATS_SERVER_VER}-linux-${natsarch}.tar.gz" \
    -P "${nats_tmp}"
  tar -xzf "${nats_tmp}/nats-server-v${NATS_SERVER_VER}-linux-${natsarch}.tar.gz" -C "${nats_tmp}"
  sudo rm -f /usr/local/bin/nats-server
  sudo mv "${nats_tmp}/nats-server-v${NATS_SERVER_VER}-linux-${natsarch}/nats-server" /usr/local/bin/
  sudo chmod +x /usr/local/bin/nats-server
  sudo chown "${USER}:${USER}" /usr/local/bin/nats-server
  rm -rf "${nats_tmp}"
}

# =============================================================================
# Update MeshCentral
# =============================================================================

update_meshcentral() {
  local current_ver; current_ver=$(cd /meshcentral/node_modules/meshcentral 2>/dev/null \
    && node -p -e "require('./package.json').version" 2>/dev/null || echo "0.0.0")

  if [[ "${current_ver}" == "${LATEST_MESH_VER}" ]] && ! "${force}"; then
    log_info "MeshCentral already at v${LATEST_MESH_VER}"
    return 0
  fi

  print_green "Updating MeshCentral from ${current_ver} to ${LATEST_MESH_VER}"
  sudo systemctl stop meshcentral
  sudo chown "${USER}:${USER}" -R /meshcentral
  cd /meshcentral
  rm -rf node_modules/ package.json package-lock.json

  cat >package.json <<EOF
{
  "dependencies": {
    "archiver": "7.0.1",
    "meshcentral": "${LATEST_MESH_VER}",
    "otplib": "10.2.3",
    "pg": "8.7.1",
    "pgtools": "0.3.2"
  }
}
EOF
  npm install
  sudo systemctl start meshcentral
}

# =============================================================================
# Fix npm if broken
# =============================================================================

ensure_npm() {
  # Clean stale npm/cache directories
  [[ -d ~/.npm ]]   && sudo rm -rf ~/.npm
  [[ -d ~/.cache ]] && sudo rm -rf ~/.cache
  [[ -d ~/.config ]] && sudo chown -R "${USER}:${USER}" ~/.config

  if ! command -v npm >/dev/null 2>&1; then
    sudo apt-get install -y npm 2>/dev/null || true
  fi

  # Still no npm? Switch to nodesource
  if ! command -v npm >/dev/null 2>&1; then
    log_info "npm missing — switching to nodesource Node 20"
    sudo systemctl stop meshcentral || true
    sudo chown "${USER}:${USER}" -R /meshcentral
    sudo apt-get remove -y nodejs || true
    sudo rm -rf /usr/lib/node_modules
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    sudo npm install -g npm
    cd /meshcentral
    rm -rf node_modules/ package-lock.json
    npm install
    sudo systemctl start meshcentral
  fi

  sudo npm install -g npm
}

# =============================================================================
# Update git repos
# =============================================================================

update_repos() {
  print_green "Updating repositories"
  cd /rmm
  git config user.email "admin@example.com"
  git config user.name "Bob"
  git fetch
  git checkout master
  git reset --hard FETCH_HEAD
  git clean -df
  git pull

  if [[ ! -d "${SCRIPTS_DIR}" ]]; then
    sudo mkdir -p "${SCRIPTS_DIR}"
    sudo chown "${USER}:${USER}" "${SCRIPTS_DIR}"
    git clone https://github.com/amidaware/community-scripts.git "${SCRIPTS_DIR}/"
    cd "${SCRIPTS_DIR}"
    git config user.email "admin@example.com"
    git config user.name "Bob"
  else
    cd "${SCRIPTS_DIR}"
    git config user.email "admin@example.com"
    git config user.name "Bob"
    git fetch
    git checkout main
    git reset --hard FETCH_HEAD
    git clean -df
    git pull
  fi
}

# =============================================================================
# Fix ownership
# =============================================================================

fix_ownership() {
  sudo chown "${USER}:${USER}" -R /rmm
  sudo chown "${USER}:${USER}" -R "${SCRIPTS_DIR}"
  sudo chown "${USER}:${USER}" /var/log/celery
  sudo chown "${USER}:${USER}" -R /etc/conf.d/
  [[ -d /etc/letsencrypt ]] && sudo chown "${USER}:${USER}" -R /etc/letsencrypt
  [[ -d /rmmbackups ]]      && sudo chown "${USER}:${USER}" -R /rmmbackups
  sudo chown -R "${USER}:${USER}" /opt/tactical
}

# =============================================================================
# Update celery config if needed
# =============================================================================

update_celery_config() {
  if ! grep -q "autoscale=20,2" /etc/conf.d/celery.conf 2>/dev/null; then
    log_info "Updating celery autoscale config"
    sed -i 's/CELERYD_OPTS=.*/CELERYD_OPTS="--time-limit=86400 --autoscale=20,2"/g' \
      /etc/conf.d/celery.conf
  fi
}

# =============================================================================
# Ensure ADMIN_ENABLED is present in local_settings
# =============================================================================

ensure_admin_enabled() {
  if ! grep -q ADMIN_ENABLED "${local_settings}" 2>/dev/null; then
    echo "ADMIN_ENABLED = False" >> "${local_settings}"
    log_info "Added ADMIN_ENABLED = False to local_settings"
  fi
}

# =============================================================================
# Update nats-api binary
# =============================================================================

update_nats_api() {
  local natsapi
  [[ "$(uname -m)" == "x86_64" ]] && natsapi='nats-api' || natsapi='nats-api-arm64'
  sudo cp "/rmm/natsapi/bin/${natsapi}" /usr/local/bin/nats-api
  sudo chown "${USER}:${USER}" /usr/local/bin/nats-api
  sudo chmod +x /usr/local/bin/nats-api
  log_info "nats-api binary updated"
}

# =============================================================================
# Update Python venv and run Django management commands
# =============================================================================

update_backend() {
  print_green "Updating backend"
  install_weasyprint_deps

  local SETUPTOOLS_VER; SETUPTOOLS_VER=$(grep "^SETUPTOOLS_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')
  local WHEEL_VER; WHEEL_VER=$(grep "^WHEEL_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')

  [[ ! -d /opt/tactical/reporting/assets ]] && sudo mkdir -p /opt/tactical/reporting/assets
  [[ ! -d /opt/tactical/reporting/schemas ]] && sudo mkdir -p /opt/tactical/reporting/schemas
  sudo sed -i '/^REDIS_HOST/d' "${local_settings}" || true

  if [[ "${CURRENT_PIP_VER}" != "${LATEST_PIP_VER}" ]] || "${force}"; then
    log_info "pip version changed (${CURRENT_PIP_VER} -> ${LATEST_PIP_VER}). Rebuilding venv."
    rm -rf /rmm/api/env
    cd /rmm/api
    python3.11 -m venv env
    # shellcheck source=/dev/null
    source /rmm/api/env/bin/activate
    cd /rmm/api/tacticalrmm
    pip install --no-cache-dir pip==25.1
    pip install --no-cache-dir "setuptools==${SETUPTOOLS_VER}" "wheel==${WHEEL_VER}"
    pip install --no-cache-dir -r requirements.txt
  else
    # shellcheck source=/dev/null
    source /rmm/api/env/bin/activate
    cd /rmm/api/tacticalrmm
    pip install -r requirements.txt
  fi

  python manage.py pre_update_tasks
  celery -A tacticalrmm purge -f
  print_green "Running database migrations (may take a while)..."
  python manage.py migrate
  python manage.py generate_json_schemas
  python manage.py delete_tokens
  python manage.py collectstatic --no-input
  python manage.py reload_nats
  python manage.py load_chocos
  python manage.py create_installer_user
  python manage.py create_natsapi_conf
  python manage.py create_uwsgi_conf
  python manage.py clear_redis_celery_locks
  python manage.py post_update_tasks

  log_info "Collecting config values..."
  API=$(python manage.py get_config api)
  WEB_VERSION=$(python manage.py get_config webversion)
  FRONTEND=$(python manage.py get_config webdomain)
  MESHDOMAIN=$(python manage.py get_config meshdomain)
  WEBTAR_URL=$(python manage.py get_webtar_url)
  CERT_PUB_KEY=$(python manage.py get_config certfile)
  CERT_PRIV_KEY=$(python manage.py get_config keyfile)
  deactivate
}

# =============================================================================
# Fix /etc/hosts for cloud-init
# =============================================================================

fix_hosts() {
  if grep -q manage_etc_hosts /etc/hosts 2>/dev/null; then
    sudo sed -i '/manage_etc_hosts: true/d' /etc/cloud/cloud.cfg >/dev/null 2>&1 || true
    if ! grep -q "manage_etc_hosts: false" /etc/cloud/cloud.cfg 2>/dev/null; then
      echo -e "\nmanage_etc_hosts: false" | sudo tee --append /etc/cloud/cloud.cfg >/dev/null
      sudo systemctl restart cloud-init >/dev/null 2>&1 || true
    fi
  fi

  local HAS_11; HAS_11=$(grep 127.0.1.1 /etc/hosts 2>/dev/null || true)
  local CHECK_HOSTS; CHECK_HOSTS=$(grep 127.0.1.1 /etc/hosts 2>/dev/null \
    | grep "${API}" | grep "${FRONTEND}" | grep "${MESHDOMAIN}" || true)

  if [[ -z "${CHECK_HOSTS}" ]]; then
    if [[ -n "${HAS_11}" ]]; then
      sudo sed -i "/127.0.1.1/s/$/ ${API} ${FRONTEND} ${MESHDOMAIN}/" /etc/hosts
    else
      echo "127.0.1.1 ${API} ${FRONTEND} ${MESHDOMAIN}" | sudo tee --append /etc/hosts >/dev/null
    fi
  fi
}

# =============================================================================
# Update frontend
# =============================================================================

update_frontend() {
  print_green "Updating the frontend to v${WEB_VERSION}"
  [[ -d /rmm/web ]] && rm -rf /rmm/web
  [[ ! -d /var/www/rmm ]] && sudo mkdir -p /var/www/rmm

  local webtar="trmm-web-v${WEB_VERSION}.tar.gz"
  wget -q "${WEBTAR_URL}" -O "/tmp/${webtar}"
  sudo rm -rf /var/www/rmm/dist
  sudo tar -xzf "/tmp/${webtar}" -C /var/www/rmm
  echo "window._env_ = {PROD_URL: \"https://${API}\"}" \
    | sudo tee /var/www/rmm/dist/env-config.js >/dev/null
  sudo chown www-data:www-data -R /var/www/rmm/dist
  rm -f "/tmp/${webtar}"
}

# =============================================================================
# Disable MeshCentral compression (fixes known mesh issues)
# =============================================================================

disable_mesh_compression() {
  local mesh_cfg='/meshcentral/meshcentral-data/config.json'
  [[ ! -f "${mesh_cfg}" ]] && return 0

  if ! command -v jq >/dev/null 2>&1; then
    sudo apt-get install -y jq >/dev/null
  fi

  local check_filter='
( .settings // {} ) |
to_entries |
map(select((.key | ascii_downcase) | IN("compression","wscompression","agentwscompression"))) |
all(.value == false)
'
  local apply_filter='
.settings |= (with_entries(
    if ((.key | ascii_downcase) | IN("compression","wscompression","agentwscompression"))
    then .value = false
    else .
    end))
'
  if ! jq -e "${check_filter}" "${mesh_cfg}" >/dev/null 2>&1; then
    log_info "Disabling mesh compression"
    cp "${mesh_cfg}" ~/"meshcfg-$(date "+%Y%m%dT%H%M%S").bak"
    local tmp; tmp=$(mktemp)
    if jq "${apply_filter}" "${mesh_cfg}" >"${tmp}" && [[ -s "${tmp}" ]]; then
      mv "${tmp}" "${mesh_cfg}"
      sudo systemctl restart meshcentral || true
    fi
    rm -f "${tmp}"
  fi
}

# =============================================================================
# Start services
# =============================================================================

start_services() {
  print_green "Starting all services"
  for svc in nats nats-api rmm daphne celery celerybeat nginx; do
    sudo systemctl start "${svc}" 2>/dev/null || true
    log_info "Started ${svc}"
  done
}

# =============================================================================
# Main
# =============================================================================

main() {
  fix_hostname
  init_logging "update"
  setup_error_trap

  log_info "update.sh SCRIPT_VERSION=${SCRIPT_VERSION}"
  log_info "Arguments: $*"

  force=false
  for arg in "$@"; do
    [[ "${arg}" == "--force" ]] && force=true
  done

  _self_update_check "$@"

  sudo apt-get update

  preflight
  version_check

  # Stop services before update
  print_green "Stopping services"
  for svc in celerybeat celery; do
    sudo systemctl stop "${svc}" 2>/dev/null || true
  done
  for svc in nginx nats-api nats rmm daphne; do
    sudo systemctl stop "${svc}" 2>/dev/null || true
  done

  migrate_services
  update_nginx
  update_python
  update_nats
  ensure_npm
  update_meshcentral
  update_repos
  fix_ownership
  update_celery_config
  ensure_admin_enabled
  update_nats_api
  update_backend
  fix_hosts
  update_nginx_rmm_conf
  remove_ssl_stapling
  update_frontend
  disable_mesh_compression
  start_services

  log_info "=== Update to TRMM v${LATEST_TRMM_VER} finished at $(date) ==="
  printf "${GREEN}Update to v%s finished! Log: %s${NC}\n" "${LATEST_TRMM_VER}" "${TRMM_LOG_FILE}"

  notify_success "Update complete" \
    "TacticalRMM updated successfully.
Previous version: ${CURRENT_TRMM_VER}
New version:      ${LATEST_TRMM_VER}
Log: ${TRMM_LOG_FILE}"
}

main "$@"
