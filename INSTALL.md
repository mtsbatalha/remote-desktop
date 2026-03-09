# GuardianRMM — Guia de Instalação e Configuração

GuardianRMM é um fork seguro e otimizado do TacticalRMM, com hardening de segurança aplicado (bypass de 2FA removido, permissões deny-by-default, rate limiting, security headers e mais).

---

## Requisitos

### Instalação em Servidor (Bare Metal / VM)

| Item | Requisito |
|------|-----------|
| OS | Debian 11/12 ou Ubuntu 22.04 LTS |
| RAM | 4 GB mínimo (8 GB recomendado) |
| CPU | x86_64 ou aarch64 |
| Disco | 20 GB livre |
| Usuário | Não-root com sudo |
| Domínios | 3 subdomínios apontando para o servidor |

### Instalação via Docker

| Item | Requisito |
|------|-----------|
| Docker | 20.10+ |
| Docker Compose | 2.0+ |
| RAM | 4 GB mínimo |
| Disco | 20 GB livre |

---

## Pré-requisitos: DNS

Você precisará de 3 registros DNS do tipo A apontando para o IP do servidor:

```
rmm.example.com     → IP_DO_SERVIDOR
api.example.com     → IP_DO_SERVIDOR
mesh.example.com    → IP_DO_SERVIDOR
```

---

## Instalação em Servidor (Script)

### Modo interativo (padrão)

```bash
./install.sh                  # Let's Encrypt (padrão)
./install.sh --use-own-cert   # certificado próprio (custom)
./install.sh --insecure       # certificado self-signed
```

### Modo automatizado (sem prompts)

```bash
export TRMM_API_DOMAIN="api.example.com"
export TRMM_FRONTEND_DOMAIN="rmm.example.com"
export TRMM_MESH_DOMAIN="mesh.example.com"
export TRMM_ROOT_DOMAIN="example.com"
export TRMM_EMAIL="admin@example.com"
export TRMM_ADMIN_USER="admin"
export TRMM_CERT_MODE="letsencrypt"   # letsencrypt | insecure | custom

# Para certificado próprio:
# export TRMM_CERT_FILE="/path/to/fullchain.pem"
# export TRMM_KEY_FILE="/path/to/privkey.pem"

./install.sh --auto
```

O script irá:
1. Verificar requisitos (OS, RAM, arquitetura, locale)
2. Instalar dependências (PostgreSQL 15, Redis, NATS, Python 3.11, Nginx, NodeJS)
3. Configurar certificados SSL (Let's Encrypt, self-signed ou custom)
4. Criar banco de dados com credenciais aleatórias
5. Configurar MeshCentral integrado
6. Criar serviços systemd
7. Gerar QR code para autenticação 2FA

---

## Instalação via Docker

### 1. Preparar configuração

```bash
cd docker/
cp .env.example .env
```

### 2. Editar o arquivo `.env`

```bash
nano .env
```

```env
IMAGE_REPO=guardianrmm/
VERSION=latest

# Credenciais do dashboard (trocar em produção)
TRMM_USER=tactical
TRMM_PASS=tactical

# Portas HTTP/HTTPS
TRMM_HTTP_PORT=80
TRMM_HTTPS_PORT=443

# Domínios (obrigatório configurar)
APP_HOST=rmm.example.com
API_HOST=api.example.com
MESH_HOST=mesh.example.com

# Integração MeshCentral
MESH_USER=tactical
MESH_PASS=tactical
MONGODB_USER=mongouser
MONGODB_PASSWORD=mongopass
MESH_PERSISTENT_CONFIG=0

# Banco de dados
POSTGRES_USER=postgres
POSTGRES_PASS=postgrespass

# Funcionalidades (True/False)
TRMM_DISABLE_WEB_TERMINAL=False
TRMM_DISABLE_SERVER_SCRIPTS=False
TRMM_DISABLE_SSO=False
```

> **Produção:** Troque todas as senhas por valores fortes antes de expor externamente.

### 3. Iniciar os serviços

```bash
docker-compose up -d
```

### 4. Verificar status

```bash
docker-compose ps
docker-compose logs -f tactical-backend
```

---

## Serviços Docker

| Container | Função | Rede |
|-----------|--------|------|
| `trmm-postgres` | Banco de dados principal (PostgreSQL 13) | api-db |
| `trmm-redis` | Cache e filas Celery (Redis 6) | redis |
| `trmm-init` | Inicialização e migração do ambiente | api-db, proxy, redis |
| `trmm-nats` | Message broker para agentes | proxy |
| `trmm-meshcentral` | Servidor NexusMesh integrado | proxy, mesh-db |
| `trmm-mongodb` | Banco de dados do NexusMesh (MongoDB) | mesh-db |
| `trmm-frontend` | Interface web (Vue.js) | proxy |
| `trmm-backend` | API Django | api-db, proxy, redis |
| `trmm-websockets` | WebSocket via Django Channels | proxy, redis |
| `trmm-nginx` | Reverse proxy e TLS | proxy |
| `trmm-celery` | Worker de tarefas assíncronas | api-db, proxy, redis |
| `trmm-celerybeat` | Scheduler de tarefas periódicas | api-db, proxy, redis |

---

## Portas Utilizadas

| Porta | Protocolo | Serviço | Exposta |
|-------|-----------|---------|---------|
| 80 | HTTP | Nginx (redirect) | Sim |
| 443 | HTTPS | Nginx (frontend + API) | Sim |
| 4222 | TCP | NATS (agentes) | Sim |
| 9235 | WebSocket | NATS WebSocket | Sim |
| 4430 | HTTPS | NexusMesh (interno) | Não |
| 5432 | TCP | PostgreSQL | Não |
| 6379 | TCP | Redis | Não |
| 27017 | TCP | MongoDB | Não |

---

## Configuração do Django (local_settings.py)

Para instalações bare metal, o arquivo de configuração local fica em:
`/rmm/api/tacticalrmm/tacticalrmm/local_settings.py`

### Configurações essenciais

```python
SECRET_KEY = "gerar_com_python_c_from_django_core_management_utils_import_get_random_secret_key"

ALLOWED_HOSTS = ["api.example.com"]

CORS_ORIGIN_WHITELIST = ["https://rmm.example.com"]

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "tacticalrmm",
        "USER": "seu_usuario",
        "PASSWORD": "sua_senha_forte",
        "HOST": "127.0.0.1",
        "PORT": "5432",
    }
}

MESH_USERNAME = "tactical"
MESH_SITE = "https://mesh.example.com"
MESH_TOKEN_KEY = "token_gerado_pela_instalacao"

REDIS_HOST = "127.0.0.1"
```

### Gerar SECRET_KEY seguro

```bash
python3 -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"
```

---

## Segurança (GuardianRMM)

Melhorias de segurança aplicadas neste fork:

### Autenticação
- **Bypass 2FA removido**: Token `"sekret"` em modo DEBUG eliminado
- **Bypass DEMO removido**: Autenticação incondicional em modo demo eliminada
- **TOTP window reduzida**: De 10 para 1 (janela de ±30 segundos)

### Permissões
- **Deny-by-default**: Roles sem restrições explícitas negam acesso (era permitir tudo)
- **Três funções corrigidas**: `_has_perm_on_agent`, `_has_perm_on_client`, `_has_perm_on_site`

### Headers HTTP
```
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
X-XSS-Protection: 1; mode=block
```

### Rate Limiting (DRF)
| Tipo | Limite |
|------|--------|
| Anônimo | 20 req/min |
| Autenticado | 200 req/min |

### Outras melhorias
- **SSL habilitado**: Verificação de certificado em downloads do agente mesh (`verify=True`)
- **NATS autenticado**: Opção `IgnoreAuthErrorAbort` removida
- **Token TTL**: Reduzido de 5 horas para 1 hora
- **SECRET_KEY**: Validação no startup — falha se não configurado ou muito curto
- **ALLOWED_HOSTS**: Sem wildcard `*` em modo debug (usa `localhost` e `127.0.0.1`)

---

## Primeiro Acesso

1. Acesse `https://rmm.example.com`
2. Faça login com as credenciais definidas em `TRMM_USER`/`TRMM_PASS`
3. Configure autenticação 2FA em: **Settings → My Profile → Enable 2FA**
4. Adicione seu primeiro cliente em: **Clients → Add Client**
5. Instale agentes nos dispositivos gerenciados

---

## Instalação de Agentes

No dashboard, vá em **Clients → [seu cliente] → Install Agent** e siga o wizard para:
- **Windows**: Baixar e executar o installer `.exe`
- **Linux**: Executar o script de instalação via curl
- **macOS**: Executar o script de instalação

---

## Serviços Systemd (Bare Metal)

```bash
# Verificar status de todos os serviços
sudo systemctl status rmm.service
sudo systemctl status daphne.service
sudo systemctl status celery.service
sudo systemctl status celerybeat.service
sudo systemctl status nats.service

# Reiniciar todos
sudo systemctl restart rmm daphne celery celerybeat nats

# Logs em tempo real
sudo journalctl -u rmm -f
```

---

## Backup e Restore

### Backup (bare metal)

```bash
./backup.sh                    # backup manual em /rmmbackups/
./backup.sh --auto             # backup com rotação (uso via cron)
./backup.sh --schedule         # instala cron diário à meia-noite
./backup.sh --list             # lista backups existentes com tamanho
./backup.sh --verify <arquivo> # verifica integridade de um backup
```

O backup inclui: dump PostgreSQL (tacticalrmm + meshcentral), arquivos do MeshCentral, certificados SSL, configs Nginx, units systemd, `local_settings.py` e `/opt/tactical`.

**Política de rotação automática (`--auto`):**

| Tipo | Retenção | Quando |
|------|----------|--------|
| Daily | 14 dias | Seg–Qui, Sáb, Dom |
| Weekly | 60 dias | Toda sexta-feira |
| Monthly | 380 dias | Dia 1 de cada mês |

**Configurar cron automático:**
```bash
./backup.sh --schedule
```

### Restore (bare metal)

```bash
./restore.sh /rmmbackups/rmm-backup-YYYY_MM_DD__HH_MM_SS.tar
```

Requisitos: servidor limpo, mesmo usuário não-root da instalação original. O script instala todas as dependências automaticamente e suporta migração de MongoDB para PostgreSQL em backups antigos.

### Backup Docker

```bash
docker exec trmm-postgres pg_dump -U postgres tacticalrmm > backup.sql
docker run --rm -v guardianrmm_tactical_data:/data -v $(pwd):/backup \
    alpine tar czf /backup/tactical_data.tar.gz /data
```

---

## Atualização

### Docker

```bash
docker-compose pull
docker-compose up -d
```

### Bare Metal

```bash
./update.sh           # atualiza se houver nova versão
./update.sh --force   # força re-instalação mesmo já na última versão
```

O script atualiza automaticamente: Python, NATS, MeshCentral, repositórios git, dependências pip, banco de dados (migrations) e frontend.

> Deve ser executado com o mesmo usuário não-root usado na instalação.

---

## Desinstalação

```bash
./uninstall.sh           # interativo (confirmação dupla)
./uninstall.sh --force   # pula confirmações (PERIGOSO)
```

Remove: serviços systemd, bancos de dados PostgreSQL, diretórios (`/rmm`, `/meshcentral`, `/opt/tactical`, `/var/www/rmm`), configs Nginx, binários NATS, entradas no cron e `/etc/hosts`.

> **Sempre faça backup antes de desinstalar:** `./backup.sh`

---

## Notificações por Email

```bash
./setup_notifications.sh           # configuração interativa
./setup_notifications.sh --test    # envia email de teste
./setup_notifications.sh --show    # exibe configuração atual
./setup_notifications.sh --remove  # remove configuração
```

Suporta msmtp (recomendado), mailutils ou sendmail. Após configurar, todos os scripts (install, update, backup, restore) enviam alertas automaticamente. A configuração fica em `/etc/trmm/notify.conf`.

---

## Diagnóstico (troubleshoot_server.sh)

```bash
sudo apt install resolvconf   # pré-requisito
./troubleshoot_server.sh
```

Verifica: OS suportado, RAM, resolução DNS dos 3 subdomínios (local e remoto via 8.8.8.8), status de todos os serviços, porta 443, detecção de proxy e validade do certificado SSL. Gera `checklog.log` no diretório atual.

---

## Solução de Problemas

**Erro: `Do NOT run this script as root. Exiting.`**

Os scripts de instalação, atualização e restore não podem ser executados como `root`. Crie um usuário não-root com sudo passwordless:

```bash
adduser rmm
usermod -aG sudo rmm
echo "rmm ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/rmm
su - rmm
cd /opt/remote-desktop
bash install.sh
```

---

**Erro: `sudo: unable to resolve host <hostname>: Name or service not known`**

O hostname do servidor não está mapeado em `/etc/hosts`. Adicione a entrada manualmente:

```bash
echo "127.0.0.1 $(hostname)" | sudo tee -a /etc/hosts
```

---

**Erro: `Permission denied` ao criar arquivo de log (`/var/log/trmm/`)**

O diretório `/var/log/trmm/` não existe ou pertence ao root. Execute como root antes de rodar o script:

```bash
mkdir -p /var/log/trmm
chown <seu-usuario>:<seu-usuario> /var/log/trmm
chown -R <seu-usuario>:<seu-usuario> /opt/remote-desktop
```

Exemplo com usuário `rmm`:

```bash
mkdir -p /var/log/trmm
chown rmm:rmm /var/log/trmm
chown -R rmm:rmm /opt/remote-desktop
```

---

**Instalador sai sem erro após escolher SSL método 1 (Let's Encrypt HTTP)**

O script verifica automaticamente se os 3 subdomínios resolvem para o IP público do servidor antes de pedir o certificado. Se algum não resolver, exibe o prompt:

```
Continue anyway? [y/N]:
```

Se o Enter for pressionado (ou qualquer tecla que não seja `y`), o script aborta com:

```
Aborted. Fix DNS first, then re-run the installer.
```

**Opções:**

1. **Configurar DNS antes de instalar** (recomendado para produção): adicione os 3 registros A no seu provedor DNS e aguarde a propagação (use `dig api.example.com` para verificar).

2. **Digitar `y` para continuar mesmo sem DNS**: útil se o DNS ainda está propagando e você quer testar o resto do fluxo. O Let's Encrypt falhará na emissão do certificado, mas o resto da instalação pode prosseguir.

3. **Usar certificado self-signed para testes** (`--insecure`): não exige DNS configurado.
   ```bash
   bash install.sh --insecure
   ```

---

**Erro: `curl: command not found` no início do install.sh**

O script tenta instalar `curl` via `apt-get` no bootstrap, mas chama `curl` imediatamente depois. Isso ocorre quando o script é executado como root antes do `curl` ser instalado. Solução: rodar como usuário não-root (o `sudo apt-get install curl` do bootstrap funcionará normalmente) ou instalar curl manualmente antes:

```bash
sudo apt-get install -y curl
bash install.sh
```

---

**Agentes não conectam via NATS:**
Verifique se a porta 4222 está acessível externamente e se as credenciais NATS batem com o `nats.conf`.

**Erro 502 Bad Gateway:**
```bash
sudo systemctl status daphne rmm
sudo journalctl -u daphne -n 50
```

**Celery não processa tarefas:**
```bash
sudo systemctl status celery celerybeat
sudo journalctl -u celery -n 50
```

**MeshCentral não conecta:**
```bash
docker logs trmm-meshcentral -f
# ou em bare metal:
sudo journalctl -u meshcentral -n 50
```

**Reset de senha do admin:**
```bash
cd /rmm
source env/bin/activate
python api/tacticalrmm/manage.py changepassword <usuario>
```

**Logs Django:**
```
/rmm/api/tacticalrmm/tacticalrmm/private/log/trmm_debug.log
/rmm/api/tacticalrmm/tacticalrmm/private/log/django_debug.log
```
