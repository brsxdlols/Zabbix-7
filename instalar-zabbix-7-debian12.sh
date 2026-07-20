#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo; echo "[ERRO] Falha na linha $LINENO. Consulte: /var/log/zabbix-install.log"' ERR

exec > >(tee -a /var/log/zabbix-install.log) 2>&1

# ============================================================
# Zabbix 7.0 LTS + PostgreSQL + NGINX + PHP-FPM
# Debian 12 Bookworm - instalação totalmente automatizada
# ============================================================

ZBX_VERSION="7.0"
DB_NAME="zabbix"
DB_USER="zabbix"
ZBX_SERVER_NAME="${ZBX_SERVER_NAME:-Zabbix Monitoramento}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
DB_PASS="${DB_PASS:-$(openssl rand -hex 24)}"
CREDENTIAL_FILE="/root/zabbix-install-credentials.txt"

green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
    red "Execute como root."
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    red "Não foi possível identificar o sistema operacional."
    exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "12" ]]; then
    red "Este instalador foi preparado exclusivamente para Debian 12."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

green "[1/12] Ajustando hostname, timezone e locales..."
timedatectl set-timezone "$TIMEZONE"
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates wget curl gnupg2 locales lsb-release apt-transport-https \
    openssl nginx postgresql postgresql-contrib php8.2-fpm

sed -i \
    -e 's/^# *pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' \
    -e 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
    /etc/locale.gen
locale-gen
update-locale LANG=pt_BR.UTF-8

green "[2/12] Instalando o repositório oficial do Zabbix ${ZBX_VERSION} LTS..."
REPO_DEB="/tmp/zabbix-release.deb"
wget -qO "$REPO_DEB" \
    "https://repo.zabbix.com/zabbix/${ZBX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_VERSION}+debian12_all.deb"
dpkg -i "$REPO_DEB"
apt-get update

green "[3/12] Instalando Zabbix Server, frontend, agente e utilitários..."
apt-get install -y --no-install-recommends \
    zabbix-server-pgsql \
    zabbix-frontend-php \
    zabbix-nginx-conf \
    zabbix-sql-scripts \
    zabbix-agent2 \
    zabbix-sender \
    zabbix-get \
    php8.2-pgsql \
    php8.2-bcmath \
    php8.2-mbstring \
    php8.2-gd \
    php8.2-xml \
    php8.2-ldap \
    php8.2-curl \
    php8.2-zip \
    traceroute \
    fping \
    snmp \
    snmptrapd \
    mtr-tiny \
    jq

green "[4/12] Criando usuário e banco PostgreSQL..."
if runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    red "O banco '${DB_NAME}' já existe. Instalação interrompida para não sobrescrever dados."
    exit 1
fi

runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' TEMPLATE template0;
SQL

green "[5/12] Importando o esquema inicial do Zabbix..."
SQL_FILE=""
for candidate in \
    /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz \
    /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz
do
    if [[ -f "$candidate" ]]; then
        SQL_FILE="$candidate"
        break
    fi
done

if [[ -z "$SQL_FILE" ]]; then
    red "Arquivo server.sql.gz não encontrado."
    exit 1
fi

PGPASSWORD="$DB_PASS" zcat "$SQL_FILE" | \
    PGPASSWORD="$DB_PASS" psql \
        --host=127.0.0.1 \
        --username="$DB_USER" \
        --dbname="$DB_NAME" \
        --set ON_ERROR_STOP=on \
        >/dev/null

green "[6/12] Configurando o Zabbix Server..."
ZBX_CONF="/etc/zabbix/zabbix_server.conf"
cp -a "$ZBX_CONF" "${ZBX_CONF}.bak.$(date +%Y%m%d-%H%M%S)"

set_zbx_option() {
    local key="$1"
    local value="$2"
    if grep -Eq "^[#[:space:]]*${key}=" "$ZBX_CONF"; then
        sed -ri "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "$ZBX_CONF"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ZBX_CONF"
    fi
}

set_zbx_option DBHost "127.0.0.1"
set_zbx_option DBName "$DB_NAME"
set_zbx_option DBUser "$DB_USER"
set_zbx_option DBPassword "$DB_PASS"
set_zbx_option CacheSize "256M"
set_zbx_option HistoryCacheSize "128M"
set_zbx_option HistoryIndexCacheSize "64M"
set_zbx_option TrendCacheSize "128M"
set_zbx_option ValueCacheSize "256M"
set_zbx_option Timeout "30"
set_zbx_option StartPollers "20"
set_zbx_option StartPollersUnreachable "10"
set_zbx_option StartPingers "10"
set_zbx_option StartDiscoverers "5"
set_zbx_option StartHTTPPollers "5"
set_zbx_option StartSNMPTrapper "1"
set_zbx_option SNMPTrapperFile "/var/log/snmptrap/snmptrap.log"

green "[7/12] Aplicando ajuste conservador e automático no PostgreSQL..."
RAM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
SHARED_MB=$(( RAM_MB / 4 ))
EFFECTIVE_MB=$(( RAM_MB * 3 / 4 ))
MAINT_MB=$(( RAM_MB / 16 ))

(( SHARED_MB < 128 )) && SHARED_MB=128
(( SHARED_MB > 8192 )) && SHARED_MB=8192
(( EFFECTIVE_MB < 512 )) && EFFECTIVE_MB=512
(( EFFECTIVE_MB > 24576 )) && EFFECTIVE_MB=24576
(( MAINT_MB < 128 )) && MAINT_MB=128
(( MAINT_MB > 2048 )) && MAINT_MB=2048

runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
ALTER SYSTEM SET shared_buffers = '${SHARED_MB}MB';
ALTER SYSTEM SET effective_cache_size = '${EFFECTIVE_MB}MB';
ALTER SYSTEM SET maintenance_work_mem = '${MAINT_MB}MB';
ALTER SYSTEM SET work_mem = '16MB';
ALTER SYSTEM SET max_connections = '300';
ALTER SYSTEM SET max_wal_size = '2GB';
ALTER SYSTEM SET min_wal_size = '512MB';
ALTER SYSTEM SET checkpoint_completion_target = '0.9';
ALTER SYSTEM SET random_page_cost = '1.1';
SQL

green "[8/12] Configurando PHP-FPM..."
PHP_INI="/etc/php/8.2/fpm/php.ini"
sed -ri \
    -e 's|^[;[:space:]]*max_execution_time[[:space:]]*=.*|max_execution_time = 600|' \
    -e 's|^[;[:space:]]*max_input_time[[:space:]]*=.*|max_input_time = 600|' \
    -e 's|^[;[:space:]]*memory_limit[[:space:]]*=.*|memory_limit = 256M|' \
    -e 's|^[;[:space:]]*post_max_size[[:space:]]*=.*|post_max_size = 100M|' \
    -e 's|^[;[:space:]]*upload_max_filesize[[:space:]]*=.*|upload_max_filesize = 100M|' \
    "$PHP_INI"

PHP_POOL="/etc/zabbix/php-fpm.conf"
if [[ -f "$PHP_POOL" ]]; then
    sed -ri \
        -e "s|^[;[:space:]]*php_value\[date.timezone\].*|php_value[date.timezone] = ${TIMEZONE}|" \
        -e 's|^[;[:space:]]*php_value\[upload_max_filesize\].*|php_value[upload_max_filesize] = 100M|' \
        -e 's|^[;[:space:]]*php_value\[post_max_size\].*|php_value[post_max_size] = 100M|' \
        -e 's|^[;[:space:]]*php_value\[max_execution_time\].*|php_value[max_execution_time] = 600|' \
        -e 's|^[;[:space:]]*php_value\[max_input_time\].*|php_value[max_input_time] = 600|' \
        "$PHP_POOL"

    grep -qF 'php_value[date.timezone]' "$PHP_POOL" ||
        echo "php_value[date.timezone] = ${TIMEZONE}" >> "$PHP_POOL"
    grep -qF 'php_value[upload_max_filesize]' "$PHP_POOL" ||
        echo 'php_value[upload_max_filesize] = 100M' >> "$PHP_POOL"
fi

green "[9/12] Configurando automaticamente o frontend..."
WEB_CONF_DIR="/etc/zabbix/web"
mkdir -p "$WEB_CONF_DIR"

cat > "${WEB_CONF_DIR}/zabbix.conf.php" <<PHP
<?php
// Arquivo criado automaticamente pelo instalador.
\$DB['TYPE']     = 'POSTGRESQL';
\$DB['SERVER']   = '127.0.0.1';
\$DB['PORT']     = '5432';
\$DB['DATABASE'] = '${DB_NAME}';
\$DB['USER']     = '${DB_USER}';
\$DB['PASSWORD'] = '${DB_PASS}';
\$DB['SCHEMA']   = '';

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = '${ZBX_SERVER_NAME}';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
PHP

chown root:www-data "${WEB_CONF_DIR}/zabbix.conf.php"
chmod 640 "${WEB_CONF_DIR}/zabbix.conf.php"

if [[ -d /usr/share/zabbix/ui && -f /usr/share/zabbix/ui/index.php ]]; then
    WEB_ROOT="/usr/share/zabbix/ui"
else
    WEB_ROOT="/usr/share/zabbix"
fi

green "[10/12] Configurando NGINX..."
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/conf.d/zabbix.conf <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root ${WEB_ROOT};
    index index.php;

    client_max_body_size 100M;
    server_tokens off;

    location = /favicon.ico {
        log_not_found off;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /assets {
        access_log off;
        expires 10d;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~ /(api\/|conf[^\.]|include|locale) {
        deny all;
        return 404;
    }

    location ~ [^/]\.php(/|\$) {
        fastcgi_pass unix:/run/php/zabbix.sock;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_index index.php;

        fastcgi_param DOCUMENT_ROOT ${WEB_ROOT};
        fastcgi_param SCRIPT_FILENAME ${WEB_ROOT}\$fastcgi_script_name;
        fastcgi_param PATH_TRANSLATED ${WEB_ROOT}\$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_connect_timeout 60;
        fastcgi_send_timeout 600;
        fastcgi_read_timeout 600;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
    }
}
NGINX

nginx -t

green "[11/12] Preparando SNMP Trap e iniciando serviços..."
install -d -o Debian-snmp -g Debian-snmp -m 0755 /var/log/snmptrap
touch /var/log/snmptrap/snmptrap.log
chown Debian-snmp:Debian-snmp /var/log/snmptrap/snmptrap.log
chmod 664 /var/log/snmptrap/snmptrap.log

systemctl enable postgresql nginx php8.2-fpm zabbix-server zabbix-agent2 snmptrapd
systemctl restart postgresql
systemctl restart php8.2-fpm
systemctl restart nginx
systemctl restart zabbix-server
systemctl restart zabbix-agent2
systemctl restart snmptrapd

green "[12/12] Validando a instalação..."
sleep 5

FAILED=0
for service in postgresql php8.2-fpm nginx zabbix-server zabbix-agent2; do
    if systemctl is-active --quiet "$service"; then
        green "  [OK] $service"
    else
        red "  [FALHA] $service"
        systemctl --no-pager --full status "$service" || true
        FAILED=1
    fi
done

SERVER_IP="$(hostname -I | awk '{print $1}')"

cat > "$CREDENTIAL_FILE" <<EOF
Zabbix instalado em: http://${SERVER_IP}/
Banco PostgreSQL: ${DB_NAME}
Usuário PostgreSQL: ${DB_USER}
Senha PostgreSQL: ${DB_PASS}

Login inicial do painel:
Usuário: Admin
Senha: zabbix

IMPORTANTE: altere a senha do usuário Admin no primeiro acesso.
EOF
chmod 600 "$CREDENTIAL_FILE"

echo
echo "============================================================"
if [[ "$FAILED" -eq 0 ]]; then
    green " INSTALAÇÃO CONCLUÍDA COM SUCESSO"
else
    yellow " INSTALAÇÃO CONCLUÍDA, MAS HÁ SERVIÇO COM FALHA"
fi
echo "============================================================"
echo "Acesso: http://${SERVER_IP}/"
echo "Usuário inicial: Admin"
echo "Senha inicial: zabbix"
echo
echo "Senha do banco salva em: ${CREDENTIAL_FILE}"
echo "Log completo: /var/log/zabbix-install.log"
echo
echo "Depois do primeiro acesso, altere imediatamente a senha Admin."
echo "============================================================"

exit "$FAILED"
