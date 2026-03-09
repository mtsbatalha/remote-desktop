#!/usr/bin/env bash
# =============================================================================
# TacticalRMM - Restore Script
# =============================================================================
#
# Usage:
#   ./restore.sh rmm-backup-YYYY_MM_DD__HH_MM_SS.tar
#
# Must be run on a CLEAN server (no existing TRMM installation).
# Must be run as the same non-root user that performed the original install.
# =============================================================================

SCRIPT_VERSION="65"
SCRIPT_URL='https://raw.githubusercontent.com/amidaware/tacticalrmm/master/restore.sh'

# Bootstrap minimal deps
sudo apt-get update -qq
sudo apt-get install -y --quiet curl wget jq dirmngr gnupg lsb-release ca-certificates 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PYTHON_VER='3.11.8'
SETTINGS_FILE='/rmm/api/tacticalrmm/tacticalrmm/settings.py'
local_settings='/rmm/api/tacticalrmm/tacticalrmm/local_settings.py'
SCRIPTS_DIR='/opt/trmm-community-scripts'

# =============================================================================
# Self-update check
# =============================================================================

_self_update_check() {
  local tmp; tmp=$(mktemp -p "" "rmmrestore_XXXXXXXXXX")
  curl -s -L "${SCRIPT_URL}" >"${tmp}"
  local new_ver; new_ver=$(grep "^SCRIPT_VERSION" "${tmp}" | awk -F'[="]' '{print $3}')
  if [[ "${SCRIPT_VERSION}" -ne "${new_ver}" ]]; then
    print_yellow "A newer restore script is available (v${new_ver})."
    print_yellow "Download it from: ${SCRIPT_URL}"
    rm -f "${tmp}"
    exit 1
  fi
  rm -f "${tmp}"
}

# =============================================================================
# Pre-flight checks
# =============================================================================

preflight() {
  check_not_root
  check_virt
  check_arch
  check_ram
  check_locale
  check_os
  check_no_existing_install
}

# =============================================================================
# Unpack and validate backup
# =============================================================================

unpack_backup() {
  local archive="$1"

  if [[ ! -f "${archive}" ]]; then
    print_error "Usage: ./restore.sh <path-to-rmm-backup.tar>"
    exit 1
  fi

  print_green "Verifying backup integrity"
  if ! tar -tf "${archive}" >/dev/null 2>&1; then
    print_error "Backup archive is corrupt or unreadable: ${archive}"
    exit 1
  fi
  log_ok "Backup integrity OK"

  print_green "Unpacking backup"
  tmp_dir=$(mktemp -d -t tacticalrmm-XXXXXXXXXXXXXXXXXXXXX)
  tar -xf "${archive}" -C "${tmp_dir}"

  # Validate original user
  local strip="User="
  ORIGUSER=$(grep "${strip}" "${tmp_dir}/systemd/rmm.service" | sed -e "s/^${strip}//")
  if [[ "${ORIGUSER}" != "${USER}" ]]; then
    print_error "You must run this restore as the original install user: ${ORIGUSER}"
    rm -rf "${tmp_dir}"
    exit 1
  fi

  log_info "Backup unpacked to ${tmp_dir}"
  log_info "Original install user: ${ORIGUSER}"
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
# Install: Nginx
# =============================================================================

install_nginx() {
  print_green "Restoring Nginx"
  local osname; osname=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
  local codename; codename=$(lsb_release -sc)

  wget -qO - https://nginx.org/keys/nginx_signing.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/${osname} ${codename} nginx" \
    | sudo tee /etc/apt/sources.list.d/nginx.list >/dev/null

  sudo apt-get update
  sudo apt-get install -y nginx
  sudo systemctl stop nginx

  for d in sites-available sites-enabled; do sudo mkdir -p "/etc/nginx/${d}"; done

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
# Restore: Certificates
# =============================================================================

restore_certs() {
  print_green "Restoring certbot"
  sudo apt-get install -y software-properties-common certbot openssl

  print_green "Restoring certificates"

  if [[ -f "${tmp_dir}/certs/etc-letsencrypt.tar.gz" ]]; then
    sudo rm -rf /etc/letsencrypt
    sudo mkdir /etc/letsencrypt
    sudo tar -xzf "${tmp_dir}/certs/etc-letsencrypt.tar.gz" -C /etc/letsencrypt
    sudo chown "${USER}:${USER}" -R /etc/letsencrypt
    log_ok "Let's Encrypt certs restored"

    # Ensure renewal hook is in place
    install_letsencrypt_renewal_hook
  fi

  if [[ -d "${tmp_dir}/certs/custom" ]]; then
    local CERT_FILE KEY_FILE
    CERT_FILE=$(grep "^CERT_FILE" "${tmp_dir}/rmm/local_settings.py" | awk -F'[= "]' '{print $5}')
    KEY_FILE=$(grep "^KEY_FILE"  "${tmp_dir}/rmm/local_settings.py" | awk -F'[= "]' '{print $5}')
    sudo mkdir -p "$(dirname "${CERT_FILE}")" "$(dirname "${KEY_FILE}")"
    sudo chown "${USER}:${USER}" "$(dirname "${CERT_FILE}")" "$(dirname "${KEY_FILE}")"
    cp -p "${tmp_dir}/certs/custom/cert" "${CERT_FILE}"
    cp -p "${tmp_dir}/certs/custom/key"  "${KEY_FILE}"
    log_ok "Custom certs restored"
  elif [[ -d "${tmp_dir}/certs/selfsigned" ]]; then
    local certdir='/etc/ssl/tactical'
    sudo mkdir -p "${certdir}"
    sudo chown "${USER}:${USER}" "${certdir}"
    sudo chmod 770 "${certdir}"
    cp -p "${tmp_dir}/certs/selfsigned/key.pem"  "${certdir}/"
    cp -p "${tmp_dir}/certs/selfsigned/cert.pem" "${certdir}/"
    log_ok "Self-signed certs restored"
  fi
}

# =============================================================================
# Restore: /opt/tactical assets
# =============================================================================

restore_assets() {
  print_green "Restoring assets"
  if [[ -f "${tmp_dir}/opt/opt-tactical.tar.gz" ]]; then
    sudo mkdir -p /opt/tactical
    sudo tar -xzf "${tmp_dir}/opt/opt-tactical.tar.gz" -C /opt/tactical
    sudo chown "${USER}:${USER}" -R /opt/tactical
    log_ok "/opt/tactical restored from backup"
  else
    sudo mkdir -p /opt/tactical/reporting/assets /opt/tactical/reporting/schemas
    sudo chown -R "${USER}:${USER}" /opt/tactical
    log_info "/opt/tactical created (no backup archive found)"
  fi
}

# =============================================================================
# Restore: Celery config & systemd units
# =============================================================================

restore_services_config() {
  print_green "Restoring Celery config"
  sudo mkdir -p /etc/conf.d
  sudo tar -xzf "${tmp_dir}/confd/etc-confd.tar.gz" -C /etc/conf.d
  sudo chown "${USER}:${USER}" -R /etc/conf.d

  print_green "Restoring systemd units"
  sudo cp "${tmp_dir}/systemd/"* /etc/systemd/system/

  # Migrate mongod dependency to postgresql in meshcentral.service
  if grep -q mongod /etc/systemd/system/meshcentral.service 2>/dev/null; then
    sudo sed -i 's/mongod.service/postgresql.service/g' /etc/systemd/system/meshcentral.service
    log_info "Migrated meshcentral.service from mongod to postgresql dependency"
  fi

  # Migrate daphne -> uvicorn if old backup
  if ! grep -q uvicorn /etc/systemd/system/daphne.service 2>/dev/null; then
    log_info "Upgrading daphne.service to uvicorn"
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
  fi

  sudo systemctl daemon-reload
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
    printf '%s\n' "${GREEN}Waiting for PostgreSQL...${NC}"
    sleep 3
  done
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
# Install: NATS
# =============================================================================

install_nats() {
  print_green "Restoring NATS"
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
# Restore: MeshCentral
# =============================================================================

restore_meshcentral() {
  print_green "Restoring MeshCentral"
  local MESH_VER; MESH_VER=$(grep "^MESH_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')

  sudo tar -xzf "${tmp_dir}/meshcentral/mesh.tar.gz" -C /
  sudo chown "${USER}:${USER}" -R /meshcentral
  rm -f /meshcentral/package.json /meshcentral/package-lock.json

  # Determine if we're coming from mongo or postgres
  FROM_MONGO=false
  local MESH_PG_USER MESH_PG_PW
  if grep -q postgres "/meshcentral/meshcentral-data/config.json"; then
    MESH_PG_USER=$(jq -r '.settings.postgres.user' /meshcentral/meshcentral-data/config.json)
    MESH_PG_PW=$(jq -r '.settings.postgres.password' /meshcentral/meshcentral-data/config.json)
  else
    FROM_MONGO=true
    MESH_PG_USER=$(tr -dc 'a-z' </dev/urandom | fold -w 8 | head -n 1)
    MESH_PG_PW=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 20 | head -n 1)
  fi

  # Create MeshCentral database
  print_green "Creating MeshCentral database"
  sudo -iu postgres psql -c "CREATE DATABASE meshcentral"
  sudo -iu postgres psql -c "CREATE USER ${MESH_PG_USER} WITH PASSWORD '${MESH_PG_PW}'"
  sudo -iu postgres psql -c "ALTER ROLE ${MESH_PG_USER} SET client_encoding TO 'utf8'"
  sudo -iu postgres psql -c "ALTER ROLE ${MESH_PG_USER} SET default_transaction_isolation TO 'read committed'"
  sudo -iu postgres psql -c "ALTER ROLE ${MESH_PG_USER} SET timezone TO 'UTC'"
  sudo -iu postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE meshcentral TO ${MESH_PG_USER}"
  sudo -iu postgres psql -c "ALTER DATABASE meshcentral OWNER TO ${MESH_PG_USER}"
  sudo -iu postgres psql -c "GRANT USAGE, CREATE ON SCHEMA PUBLIC TO ${MESH_PG_USER}"

  if "${FROM_MONGO}"; then
    print_green "Converting MeshCentral from MongoDB to PostgreSQL"
    local mesh_data='/meshcentral/meshcentral-data'

    if [[ ! -f "${mesh_data}/meshcentral.db.json" ]]; then
      print_error "meshcentral.db.json not found. Your backup may have used an outdated backup.sh."
      print_error "Please take a fresh backup with the latest backup.sh and retry."
      exit 1
    fi

    cp "${mesh_data}/config.json" "${mesh_data}/config-mongodb-$(date '+%Y%m%dT%H%M%S').bak"
    jq '.settings |= with_entries(select((.key | ascii_downcase) as $k | $k != "mongodb" and $k != "mongodbname"))' \
      "${mesh_data}/config.json" \
      | jq ".settings.postgres.user = \"${MESH_PG_USER}\"" \
      | jq ".settings.postgres.password = \"${MESH_PG_PW}\"" \
      | jq '.settings.postgres.port = "5432"' \
      | jq '.settings.postgres.host = "localhost"' \
      >"${mesh_data}/config-postgres.json"
    mv "${mesh_data}/config-postgres.json" "${mesh_data}/config.json"
  else
    log_info "Restoring MeshCentral PostgreSQL dump"
    gzip -d "${tmp_dir}/postgres/mesh-db"*.psql.gz
    PGPASSWORD="${MESH_PG_PW}" psql -h localhost -U "${MESH_PG_USER}" \
      -d meshcentral -f "${tmp_dir}/postgres/mesh-db"*.psql
  fi

  # Install meshcentral package
  cd /meshcentral
  cat >package.json <<EOF
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
  npm install

  if "${FROM_MONGO}"; then
    node node_modules/meshcentral --dbimport >/dev/null
    log_ok "MongoDB data imported to PostgreSQL"
  fi
}

# =============================================================================
# Restore: TacticalRMM backend
# =============================================================================

restore_backend() {
  print_green "Restoring TacticalRMM backend"

  # Restore local_settings
  cp "${tmp_dir}/rmm/local_settings.py" "${local_settings}"

  install_weasyprint_deps

  local SETUPTOOLS_VER; SETUPTOOLS_VER=$(grep "^SETUPTOOLS_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')
  local WHEEL_VER; WHEEL_VER=$(grep "^WHEEL_VER" "${SETTINGS_FILE}" | awk -F'[= "]' '{print $5}')

  # Restore TacticalRMM database
  print_green "Restoring TacticalRMM database"
  local pgusername pgpw
  pgusername=$(grep -w "USER" "${local_settings}" | sed "s/.*'USER': '//; s/'.*//")
  pgpw=$(grep -w "PASSWORD" "${local_settings}" | sed "s/.*'PASSWORD': '//; s/'.*//")

  sudo -iu postgres psql -c "CREATE DATABASE tacticalrmm"
  sudo -iu postgres psql -c "CREATE USER ${pgusername} WITH PASSWORD '${pgpw}'"
  sudo -iu postgres psql -c "ALTER ROLE ${pgusername} SET client_encoding TO 'utf8'"
  sudo -iu postgres psql -c "ALTER ROLE ${pgusername} SET default_transaction_isolation TO 'read committed'"
  sudo -iu postgres psql -c "ALTER ROLE ${pgusername} SET timezone TO 'UTC'"
  sudo -iu postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE tacticalrmm TO ${pgusername}"
  sudo -iu postgres psql -c "ALTER DATABASE tacticalrmm OWNER TO ${pgusername}"
  sudo -iu postgres psql -c "GRANT USAGE, CREATE ON SCHEMA PUBLIC TO ${pgusername}"

  gzip -d "${tmp_dir}/postgres/db"*.psql.gz
  PGPASSWORD="${pgpw}" psql -h localhost -U "${pgusername}" -d tacticalrmm \
    -f "${tmp_dir}/postgres/db"*.psql
  log_ok "TacticalRMM DB restored"

  # Python venv + Django setup
  cd /rmm/api
  python3.11 -m venv env
  # shellcheck source=/dev/null
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
  python manage.py reload_nats
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
# Restore: Nginx configs
# =============================================================================

restore_nginx_configs() {
  print_green "Restoring Nginx configs"

  for conf in frontend meshcentral; do
    sudo cp "${tmp_dir}/nginx/${conf}.conf" /etc/nginx/sites-available/
    sudo ln -sf "/etc/nginx/sites-available/${conf}.conf" \
                "/etc/nginx/sites-enabled/${conf}.conf"
  done

  # rmm.conf: upgrade if missing /assets/ location (old backup)
  if grep -q "location /assets/" "${tmp_dir}/nginx/rmm.conf"; then
    sudo cp "${tmp_dir}/nginx/rmm.conf" /etc/nginx/sites-available/rmm.conf
  else
    log_info "Old rmm.conf — regenerating with /assets/ location"
    local cert_pub="${CERT_PUB_KEY}"
    local cert_priv="${CERT_PRIV_KEY}"

    # Fall back to selfsigned paths if needed
    if [[ -d "${tmp_dir}/certs/selfsigned" ]]; then
      cert_pub='/etc/ssl/tactical/cert.pem'
      cert_priv='/etc/ssl/tactical/key.pem'
    fi

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
    ssl_certificate ${cert_pub};
    ssl_certificate_key ${cert_priv};
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
  fi

  sudo ln -sf /etc/nginx/sites-available/rmm.conf /etc/nginx/sites-enabled/rmm.conf

  # Remove deprecated ssl_stapling directives
  for site in rmm frontend meshcentral; do
    local conf="/etc/nginx/sites-enabled/${site}.conf"
    if [[ -f "${conf}" ]] && grep -q "ssl_stapling" "${conf}"; then
      sudo sed -i '/ssl_stapling/d' "${conf}"
      log_info "Removed ssl_stapling from ${conf}"
    fi
  done
}

# =============================================================================
# Fix /etc/hosts
# =============================================================================

fix_hosts() {
  print_green "Restoring hosts file"
  if grep -q manage_etc_hosts /etc/hosts 2>/dev/null; then
    sudo sed -i '/manage_etc_hosts: true/d' /etc/cloud/cloud.cfg >/dev/null 2>&1 || true
    echo -e "\nmanage_etc_hosts: false" | sudo tee --append /etc/cloud/cloud.cfg >/dev/null
    sudo systemctl restart cloud-init >/dev/null 2>&1 || true
  fi

  local HAS_11; HAS_11=$(grep 127.0.1.1 /etc/hosts 2>/dev/null || true)
  if [[ -n "${HAS_11}" ]]; then
    sudo sed -i "/127.0.1.1/s/$/ ${API} ${FRONTEND} ${MESHDOMAIN}/" /etc/hosts
  else
    echo "127.0.1.1 ${API} ${FRONTEND} ${MESHDOMAIN}" | sudo tee --append /etc/hosts >/dev/null
  fi
}

# =============================================================================
# Restore: Frontend
# =============================================================================

restore_frontend() {
  print_green "Restoring frontend (v${WEB_VERSION})"
  local webtar="trmm-web-v${WEB_VERSION}.tar.gz"
  wget -q "${WEBTAR_URL}" -O "/tmp/${webtar}"
  sudo mkdir -p /var/www/rmm
  sudo tar -xzf "/tmp/${webtar}" -C /var/www/rmm
  echo "window._env_ = {PROD_URL: \"https://${API}\"}" \
    | sudo tee /var/www/rmm/dist/env-config.js >/dev/null
  sudo chown www-data:www-data -R /var/www/rmm/dist
  rm -f "/tmp/${webtar}"
}

# =============================================================================
# Disable MeshCentral compression
# =============================================================================

disable_mesh_compression() {
  local mesh_cfg='/meshcentral/meshcentral-data/config.json'
  [[ ! -f "${mesh_cfg}" ]] && return 0
  if ! command -v jq >/dev/null 2>&1; then sudo apt-get install -y jq >/dev/null; fi

  local check_filter='
( .settings // {} ) |
to_entries |
map(select((.key | ascii_downcase) | IN("compression","wscompression","agentwscompression"))) |
all(.value == false)
'
  local apply_filter='
.settings |= (with_entries(
  if ((.key | ascii_downcase) | IN("compression","wscompression","agentwscompression"))
  then .value = false else . end))
'
  if ! jq -e "${check_filter}" "${mesh_cfg}" >/dev/null 2>&1; then
    log_info "Disabling mesh compression in config"
    cp "${mesh_cfg}" ~/"meshcfg-$(date "+%Y%m%dT%H%M%S").bak"
    local tmp; tmp=$(mktemp)
    if jq "${apply_filter}" "${mesh_cfg}" >"${tmp}" && [[ -s "${tmp}" ]]; then
      mv "${tmp}" "${mesh_cfg}"
    fi
    rm -f "${tmp}"
  fi
}

# =============================================================================
# Fix ownership and enable services
# =============================================================================

fix_permissions() {
  sudo chown "${USER}:${USER}" -R /rmm
  sudo chown "${USER}:${USER}" /var/log/celery
  sudo chown "${USER}:${USER}" -R /etc/conf.d/
  [[ -d /home/${USER}/.npm ]]    && sudo chown -R "${USER}:${USER}" "/home/${USER}/.npm"
  [[ -d /home/${USER}/.config ]] && sudo chown -R "${USER}:${USER}" "/home/${USER}/.config"
  [[ -d /home/${USER}/.cache ]]  && sudo chown -R "${USER}:${USER}" "/home/${USER}/.cache"
}

enable_and_start_services() {
  print_green "Enabling and starting services"
  sudo systemctl daemon-reload

  sudo systemctl enable nats.service
  sudo systemctl start nats.service

  for svc in celery.service celerybeat.service rmm.service daphne.service nats-api.service nginx; do
    sudo systemctl enable "${svc}"
    sudo systemctl stop "${svc}" 2>/dev/null || true
    sudo systemctl start "${svc}"
  done

  sleep 5
  disable_mesh_compression

  sudo systemctl enable meshcentral
  sudo systemctl start meshcentral
}

# =============================================================================
# Main
# =============================================================================

main() {
  fix_hostname
  init_logging "restore"
  setup_error_trap

  log_info "restore.sh SCRIPT_VERSION=${SCRIPT_VERSION}"
  log_info "Arguments: $*"

  _self_update_check

  if [[ $# -lt 1 ]]; then
    print_error "Usage: ./restore.sh <path-to-rmm-backup.tar>"
    exit 1
  fi

  local archive="$1"
  log_info "Restoring from: ${archive}"

  preflight
  unpack_backup "${archive}"

  # Prevent journald issues on freshly provisioned VPS
  sudo systemctl restart systemd-journald.service 2>/dev/null || true

  sudo apt-get update

  install_nodejs
  install_nginx
  restore_certs
  restore_assets
  restore_services_config
  install_python
  sudo apt-get install -y redis git
  install_postgresql
  clone_repos
  install_nats
  restore_meshcentral
  restore_backend
  fix_hosts
  restore_nginx_configs
  restore_frontend
  fix_permissions
  enable_and_start_services

  # Cleanup
  rm -rf "${tmp_dir}"

  printf >&2 "\n${YELLOW}%0.s*${NC}" {1..80}; printf >&2 "\n\n"
  printf >&2 '%s\n\n' "${YELLOW}Restore complete!${NC}"
  printf >&2 '  Frontend:  %s\n' "${GREEN}https://${API}${NC}"
  printf >&2 '  Log file:  %s\n' "${GREEN}${TRMM_LOG_FILE}${NC}"
  printf >&2 "\n${YELLOW}%0.s*${NC}" {1..80}; printf >&2 "\n"

  notify_success "Restore complete" \
    "TacticalRMM restored successfully from: ${archive}
Frontend: https://${API}
Log: ${TRMM_LOG_FILE}"
}

main "$@"
