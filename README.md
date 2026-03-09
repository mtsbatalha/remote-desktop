# Tactical RMM

![CI Tests](https://github.com/amidaware/tacticalrmm/actions/workflows/ci-tests.yml/badge.svg?branch=develop)
[![codecov](https://codecov.io/gh/amidaware/tacticalrmm/branch/develop/graph/badge.svg?token=8ACUPVPTH6)](https://codecov.io/gh/amidaware/tacticalrmm)
[![Code style: black](https://img.shields.io/badge/code%20style-black-000000.svg)](https://github.com/python/black)

Tactical RMM is a remote monitoring & management tool, built with Django and Vue.\
It uses an [agent](https://github.com/amidaware/rmmagent) written in golang and integrates with [MeshCentral](https://github.com/Ylianst/MeshCentral)

# [LIVE DEMO](https://demo.tacticalrmm.com/)

Demo database resets every hour. A lot of features are disabled for obvious reasons due to the nature of this app.

### [Discord Chat](https://discord.gg/upGTkWp)

### [Documentation](https://docs.tacticalrmm.com)

## Features

- Teamviewer-like remote desktop control
- Real-time remote shell
- Remote file browser (download and upload files)
- Windows Registry Editor
- Remote command and script execution (batch, powershell, python, nushell and deno scripts)
- Event log viewer
- Services management
- Windows patch management
- Automated checks with email/SMS/Webhook alerting (cpu, disk, memory, services, scripts, event logs)
- Automated task runner (run scripts on a schedule)
- Remote software installation via chocolatey
- Software and hardware inventory

## Windows agent versions supported

- Windows 7, 8.1, 10, 11,
- Server 2008R2, 2012R2, 2016, 2019, 2022, 2025

## Linux agent versions supported

- Any distro with systemd which includes but is not limited to: Debian (10, 11), Ubuntu x86_64 (18.04, 20.04, 22.04), Synology 7, centos, freepbx and more!

## Mac agent versions supported

- 64 bit Intel and Apple Silicon (M-Series)

## Sponsorship Features

- Mac and Linux Agents
- Windows [Code Signed](https://docs.tacticalrmm.com/code_signing/) Agents
- Fully Customizable [Reporting](https://docs.tacticalrmm.com/ee/reporting/reporting_overview/) Module
- [Single Sign-On](https://docs.tacticalrmm.com/ee/sso/sso/) (SSO)

---

## Requisitos

| Item | Requisito |
|------|-----------|
| OS | Debian 11/12 ou Ubuntu 22.04 LTS |
| RAM | 4 GB minimo (8 GB recomendado) |
| CPU | x86_64 ou aarch64 |
| Disco | 20 GB livre |
| Usuario | Nao-root com sudo passwordless |
| Dominios | 3 subdominios apontando para o servidor |

> Para instalacao via Docker, consulte o [INSTALL.md](INSTALL.md#instalacao-via-docker).

---

## Pre-requisitos: DNS

Crie 3 registros DNS tipo A apontando para o IP do servidor antes de rodar qualquer script:

```
rmm.example.com     -> IP_DO_SERVIDOR
api.example.com     -> IP_DO_SERVIDOR
mesh.example.com    -> IP_DO_SERVIDOR
```

---

## Scripts disponiveis

| Script | Descricao |
|--------|-----------|
| [`install.sh`](#installsh) | Instalacao completa do servidor |
| [`update.sh`](#updatesh) | Atualizacao para a versao mais recente |
| [`backup.sh`](#backupsh) | Backup com rotacao automatica |
| [`restore.sh`](#restoresh) | Restauracao a partir de backup |
| [`uninstall.sh`](#uninstallsh) | Remocao completa da instalacao |
| [`setup_notifications.sh`](#setup_notificationssh) | Configuracao de alertas por email |
| [`troubleshoot_server.sh`](#troubleshoot_serversh) | Diagnostico de problemas |

---

## install.sh

Instala todos os componentes: PostgreSQL, Redis, NATS, Python 3.11, Nginx, MeshCentral, Django e o frontend Vue.

### Modo interativo (padrao)

```bash
./install.sh                  # Let's Encrypt (padrao)
./install.sh --use-own-cert   # certificado proprio (custom)
./install.sh --insecure       # certificado self-signed
```

### Modo automatizado (sem prompts)

Exporte as variaveis de ambiente e passe `--auto`:

```bash
export TRMM_API_DOMAIN="api.example.com"
export TRMM_FRONTEND_DOMAIN="rmm.example.com"
export TRMM_MESH_DOMAIN="mesh.example.com"
export TRMM_ROOT_DOMAIN="example.com"
export TRMM_EMAIL="admin@example.com"
export TRMM_ADMIN_USER="admin"
export TRMM_CERT_MODE="letsencrypt"   # letsencrypt | insecure | custom

# Para certificado proprio (custom):
# export TRMM_CERT_FILE="/path/to/fullchain.pem"
# export TRMM_KEY_FILE="/path/to/privkey.pem"

./install.sh --auto
```

> O script possui auto-atualizacao: se detectar uma versao mais recente de si mesmo, faz download e re-executa automaticamente.

---

## update.sh

Atualiza todos os componentes (Python, NATS, MeshCentral, repositorios, banco de dados, frontend).

```bash
./update.sh           # atualiza se houver nova versao
./update.sh --force   # forca re-instalacao mesmo ja estando na ultima versao
```

> Deve ser executado com o mesmo usuario nao-root usado na instalacao.

---

## backup.sh

Gera um arquivo `.tar` contendo: dump do PostgreSQL (tacticalrmm + meshcentral), arquivos do MeshCentral, certificados SSL, configs do Nginx, units do systemd, `local_settings.py` e `/opt/tactical`.

```bash
./backup.sh                    # backup manual em /rmmbackups/
./backup.sh --auto             # backup com rotacao (uso via cron)
./backup.sh --schedule         # instala cron diario a meia-noite e cria diretorios
./backup.sh --list             # lista backups existentes com tamanho
./backup.sh --verify <arquivo> # verifica integridade de um backup
```

### Politica de rotacao (--auto)

| Tipo | Retencao | Quando |
|------|----------|--------|
| Daily | 14 dias | Seg, Ter, Qua, Qui, Sab, Dom |
| Weekly | 60 dias | Toda sexta-feira |
| Monthly | 380 dias | Dia 1 de cada mes |

### Configurar cron automatico

```bash
./backup.sh --schedule
```

Isso instala a entrada no crontab do usuario e cria os diretorios `/rmmbackups/daily/`, `/rmmbackups/weekly/` e `/rmmbackups/monthly/`.

### Verificar um backup

```bash
./backup.sh --verify /rmmbackups/daily/rmm-backup-2025_01_15__00_00_01.tar
```

---

## restore.sh

Restaura uma instalacao a partir de um arquivo de backup gerado pelo `backup.sh`.

```bash
./restore.sh /rmmbackups/rmm-backup-YYYY_MM_DD__HH_MM_SS.tar
```

**Requisitos:**
- Servidor limpo (sem instalacao existente do TRMM)
- Mesmo usuario nao-root usado na instalacao original
- O script instala automaticamente todas as dependencias (NodeJS, Nginx, Python, PostgreSQL, NATS, MeshCentral)
- Suporta migracao automatica de MongoDB para PostgreSQL (backups antigos)

---

## uninstall.sh

Remove completamente o TacticalRMM: servicos, bancos de dados, diretorios, configs do Nginx, binarios do NATS, entradas no cron e `/etc/hosts`.

```bash
./uninstall.sh           # interativo (pede confirmacao dupla)
./uninstall.sh --force   # pula todas as confirmacoes (PERIGOSO)
```

**O que e removido:**
- Servicos systemd: `rmm`, `daphne`, `celery`, `celerybeat`, `nats`, `nats-api`, `meshcentral`, `nginx`
- Bancos de dados PostgreSQL: `tacticalrmm` e `meshcentral`
- Diretorios: `/rmm`, `/meshcentral`, `/opt/tactical`, `/var/www/rmm`, `/opt/trmm-community-scripts`
- Configs Nginx, binarios NATS, entradas no cron, `/var/log/trmm`, `/etc/trmm`

**Opcional (perguntado interativamente):**
- Certificados Let's Encrypt
- Pacotes do sistema: nginx, postgresql-15, nodejs, redis, python3.11, certbot

> Faca sempre um backup antes de desinstalar: `./backup.sh`

---

## setup_notifications.sh

Configura alertas por email para os scripts de instalacao, atualizacao, backup e restore. Suporta msmtp (recomendado), mailutils ou sendmail existente.

```bash
./setup_notifications.sh           # configuracao interativa
./setup_notifications.sh --test    # envia email de teste
./setup_notifications.sh --show    # exibe configuracao atual
./setup_notifications.sh --remove  # remove configuracao de notificacoes
```

**Provedores SMTP suportados:**

| Provedor | Servidor | Porta |
|----------|----------|-------|
| Gmail | smtp.gmail.com | 587 |
| Office 365 | smtp.office365.com | 587 |
| SendGrid | smtp.sendgrid.net | 587 |

> Para Gmail, use uma **App Password** (nao a senha da conta).

A configuracao fica em `/etc/trmm/notify.conf`. Apos configurar, todos os scripts enviarao notificacoes automaticamente em caso de sucesso ou falha.

---

## troubleshoot_server.sh

Diagnostico completo da instalacao. Gera um arquivo `checklog.log` no diretorio atual.

```bash
./troubleshoot_server.sh
```

**O que o script verifica:**
- OS suportado (Debian 11/12, Ubuntu 22.04)
- RAM minima (4 GB)
- Resolucao DNS dos 3 subdominios (local e remoto via 8.8.8.8)
- Status de todos os servicos: `rmm`, `daphne`, `celery`, `celerybeat`, `nginx`, `nats`, `nats-api`, `meshcentral`, `postgresql`, `redis-server`
- Porta 443 acessivel externamente
- Deteccao de proxy (via certificado e IP)
- Validade do certificado SSL (certbot)
- Ultimas linhas dos logs Django

**Pre-requisito:**
```bash
sudo apt install resolvconf
```

---

## Configuracao do Django (local_settings.py)

Para instalacoes bare metal, o arquivo de configuracao local fica em:
`/rmm/api/tacticalrmm/tacticalrmm/local_settings.py`

Consulte o [INSTALL.md](INSTALL.md) para detalhes completos sobre configuracao do Django, Docker, seguranca (GuardianRMM), servicos systemd, logs e solucao de problemas.

---

## Logs

| Arquivo | Descricao |
|---------|-----------|
| `/var/log/trmm/install.log` | Log da instalacao |
| `/var/log/trmm/update.log` | Log de atualizacoes |
| `/var/log/trmm/backup.log` | Log de backups |
| `/var/log/trmm/restore.log` | Log de restauracoes |
| `/var/log/trmm/uninstall.log` | Log da desinstalacao |
| `/rmm/api/tacticalrmm/tacticalrmm/private/log/trmm_debug.log` | Log de debug do TRMM |
| `/rmm/api/tacticalrmm/tacticalrmm/private/log/django_debug.log` | Log de debug do Django |
