#!/usr/bin/env bash
# ==============================================================================
# 09_bitrix_config.sh -- Bitrix24 post-install configuration
# Creates/updates all config files needed for the stack to work:
#   - .settings.php  (DB, Redis cache, Redis sessions, crypto key)
#   - dbconn.php     (DB connection constants)
#   - .settings_extra.php (push-server, OpenSearch)
#   - php_interface/dbconn.php (PHP flags)
#   - Postfix env vars reminder
# ==============================================================================
step "STEP 9/10 -- Bitrix configuration files"

cd "${PROJECT_DIR}"

# ── Read credentials from env files ──────────────────────────────────────────
MYSQL_ROOT_PASS=$(grep MYSQL_ROOT_PASSWORD .env_sql | cut -d= -f2 | tr -d '"' | tr -d "'")
PUSH_KEY=$(grep PUSH_SECURITY_KEY .env_push | cut -d= -f2 | tr -d '"' | tr -d "'")
PUSH_SUB_PORT=$(grep PUSH_SUB_PORT .env_push_sub | cut -d= -f2 | tr -d '"' | tr -d "'")
PUSH_PUB_PORT=$(grep PUSH_PUB_PORT .env_push_pub | cut -d= -f2 | tr -d '"' | tr -d "'")
REDIS_HOST="redis"
REDIS_PORT="6379"

WWW="${FTP_HOME}"           # /mnt/bitrix/www
BITRIX_DIR="${WWW}/bitrix"

# ── Ensure Bitrix directory structure exists ──────────────────────────────────
mkdir -p "${BITRIX_DIR}/php_interface"
chown -R 979:979 "${BITRIX_DIR}"

# ── Generate credentials if .settings.php doesn't exist yet ──────────────────
if [[ ! -f "${BITRIX_DIR}/.settings.php" ]]; then
    ok "No .settings.php found -- will create from scratch after DB setup"
    ok "Run this step again after completing the Bitrix install wizard"
    FRESH_INSTALL=1
else
    FRESH_INSTALL=0
    # Read existing DB credentials from .settings.php
    BITRIX_DB_PASS=$(php -r "
        \$s = include '${BITRIX_DIR}/.settings.php';
        echo \$s['connections']['value']['default']['password'] ?? '';
    " 2>/dev/null || grep -oP "'password' => '\K[^']*" "${BITRIX_DIR}/.settings.php" | head -1)
    BITRIX_DB_NAME=$(php -r "
        \$s = include '${BITRIX_DIR}/.settings.php';
        echo \$s['connections']['value']['default']['database'] ?? 'bitrix';
    " 2>/dev/null || echo "bitrix")
    BITRIX_DB_USER=$(php -r "
        \$s = include '${BITRIX_DIR}/.settings.php';
        echo \$s['connections']['value']['default']['login'] ?? 'bitrix';
    " 2>/dev/null || echo "bitrix")
    CRYPTO_KEY=$(php -r "
        \$s = include '${BITRIX_DIR}/.settings.php';
        echo \$s['crypto']['value']['crypto_key'] ?? '';
    " 2>/dev/null || grep -oP "'crypto_key' => '\K[^']*" "${BITRIX_DIR}/.settings.php" | head -1)
fi

# ── For fresh install: create bitrix DB user ─────────────────────────────────
if [[ ${FRESH_INSTALL:-0} -eq 1 ]]; then
    BITRIX_DB_USER="bitrix"
    BITRIX_DB_NAME="bitrix"
    BITRIX_DB_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    CRYPTO_KEY=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32)

    ok "Creating MySQL database and user..."
    docker exec bitrix_mysql mysql -uroot "-p${MYSQL_ROOT_PASS}" << SQL
CREATE DATABASE IF NOT EXISTS \`${BITRIX_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${BITRIX_DB_USER}'@'%' IDENTIFIED BY '${BITRIX_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${BITRIX_DB_NAME}\`.* TO '${BITRIX_DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
    ok "MySQL: database=${BITRIX_DB_NAME} user=${BITRIX_DB_USER} created"

    # Save credentials for summary
    echo "BITRIX_DB_USER=${BITRIX_DB_USER}"     > "${PROJECT_DIR}/.deploy_credentials"
    echo "BITRIX_DB_NAME=${BITRIX_DB_NAME}"    >> "${PROJECT_DIR}/.deploy_credentials"
    echo "BITRIX_DB_PASS=${BITRIX_DB_PASS}"    >> "${PROJECT_DIR}/.deploy_credentials"
    echo "BITRIX_CRYPTO_KEY=${CRYPTO_KEY}"     >> "${PROJECT_DIR}/.deploy_credentials"
    chmod 600 "${PROJECT_DIR}/.deploy_credentials"
else
    ok "Existing DB credentials preserved from .settings.php"
fi

# ── .settings.php ─────────────────────────────────────────────────────────────
ok "Writing ${BITRIX_DIR}/.settings.php ..."
cat > "${BITRIX_DIR}/.settings.php" << PHP
<?php
return array (
  'cache_flags' =>
  array (
    'value' =>
    array (
      'config_options' => 3600.0,
    ),
    'readonly' => false,
  ),
  'cookies' =>
  array (
    'value' =>
    array (
      'secure' => true,
      'http_only' => true,
    ),
    'readonly' => false,
  ),
  'exception_handling' =>
  array (
    'value' =>
    array (
      'debug' => false,
      'handled_errors_types' => 4437,
      'exception_errors_types' => 4437,
      'ignore_silence' => false,
      'assertion_throws_exception' => true,
      'assertion_error_type' => 256,
      'log' => NULL,
    ),
    'readonly' => false,
  ),
  'connections' =>
  array (
    'value' =>
    array (
      'default' =>
      array (
        'host' => 'mysql',
        'database' => '${BITRIX_DB_NAME}',
        'login' => '${BITRIX_DB_USER}',
        'password' => '${BITRIX_DB_PASS}',
        'options' => 2.0,
        'className' => '\\Bitrix\\Main\\DB\\MysqliConnection',
      ),
    ),
    'readonly' => true,
  ),
  'crypto' =>
  array (
    'value' =>
    array (
      'crypto_key' => '${CRYPTO_KEY}',
    ),
    'readonly' => true,
  ),
  'cache' =>
  array (
    'value' =>
    array (
      'type' =>
      array (
        'class_name' => '\\Bitrix\\Main\\Data\\CacheEngineRedis',
        'extension' => 'redis',
      ),
      'sid' => 'bitrix',
      'servers' =>
      array (
        0 =>
        array (
          'host' => '${REDIS_HOST}',
          'port' => ${REDIS_PORT},
        ),
      ),
    ),
    'readonly' => false,
  ),
  'session' =>
  array (
    'value' =>
    array (
      'mode' => 'default',
      'handlers' =>
      array (
        'general' =>
        array (
          'type' => 'redis',
          'host' => '${REDIS_HOST}',
          'port' => '${REDIS_PORT}',
        ),
      ),
    ),
    'readonly' => false,
  ),
  'messenger' =>
  array (
    'value' =>
    array (
      'run_mode' => NULL,
      'shuffle' => true,
      'brokers' =>
      array (
        'default' =>
        array (
          'type' => 'db',
          'params' =>
          array (
            'table' => 'Bitrix\\Main\\Messenger\\Internals\\Storage\\Db\\Model\\MessengerMessageTable',
          ),
        ),
      ),
      'queues' =>
      array (
      ),
    ),
    'readonly' => true,
  ),
);
PHP
chown 979:979 "${BITRIX_DIR}/.settings.php"
chmod 640 "${BITRIX_DIR}/.settings.php"
ok ".settings.php written (DB + Redis cache + Redis sessions)"

# ── .settings_extra.php -- push-server + OpenSearch ──────────────────────────
ok "Writing ${BITRIX_DIR}/.settings_extra.php ..."
cat > "${BITRIX_DIR}/.settings_extra.php" << PHP
<?php
return array(
  // Push & Pull server (Bitrix push-server containers)
  'pull' => array(
    'value' => array(
      'path_to_listener'          => '/bitrix/sub/',
      'path_to_listener_secure'   => '/bitrix/sub/',
      'path_to_modern_listener'   => '/bitrix/sub/',
      'path_to_modern_listener_secure' => '/bitrix/sub/',
      'path_to_publisher'         => 'http://push_pub:${PUSH_PUB_PORT}/bitrix/pub/',
      'path_to_publisher_mobile'  => 'http://push_pub:${PUSH_PUB_PORT}/bitrix/pub/',
      'nginx_version'             => 2,
      'nginx_command_per_hit'     => 100,
      'server_enabled'            => true,
      'security_key'              => '${PUSH_KEY}',
    ),
    'readonly' => false,
  ),

  // Full-text search via OpenSearch
  'search' => array(
    'value' => array(
      'type'    => 'opensearch',
      'servers' => array(
        array(
          'host'   => 'opensearch',
          'port'   => 9200,
          'scheme' => 'http',
        ),
      ),
    ),
    'readonly' => false,
  ),
);
PHP
chown 979:979 "${BITRIX_DIR}/.settings_extra.php"
chmod 640 "${BITRIX_DIR}/.settings_extra.php"
ok ".settings_extra.php written (push-server + OpenSearch)"

# ── dbconn.php ───────────────────────────────────────────────────────────────
ok "Writing ${BITRIX_DIR}/php_interface/dbconn.php ..."
cat > "${BITRIX_DIR}/php_interface/dbconn.php" << PHP
<?php
\$DBDebug = false;
\$DBDebugToFile = false;

define("BX_FILE_PERMISSIONS", 0644);
define("BX_DIR_PERMISSIONS", 0755);
@umask(~(BX_FILE_PERMISSIONS | BX_DIR_PERMISSIONS) & 0777);

@ini_set("memory_limit", "1024M");

define("BX_DISABLE_INDEX_PAGE", true);

mb_internal_encoding("UTF-8");
PHP
chown 979:979 "${BITRIX_DIR}/php_interface/dbconn.php"
chmod 640 "${BITRIX_DIR}/php_interface/dbconn.php"
ok "dbconn.php written"

# ── Bitrix cache dirs on SSD ──────────────────────────────────────────────────
CACHE_DIR="/mnt/bitrix/cache"
for d in cache managed_cache stack_cache html_pages; do
    mkdir -p "${CACHE_DIR}/${d}"
    chown -R 979:979 "${CACHE_DIR}/${d}"
done
ok "Cache dirs ready: ${CACHE_DIR}/{cache,managed_cache,stack_cache,html_pages}"

# ── /upload -> LV symlink inside www ─────────────────────────────────────────
# The upload directory must point to the dedicated LV
if [[ ! -L "${WWW}/upload" ]]; then
    [[ -d "${WWW}/upload" ]] && mv "${WWW}/upload" "${WWW}/upload.bak.$(date +%s)"
    ln -sfn /mnt/bitrix/upload "${WWW}/upload"
    ok "www/upload -> /mnt/bitrix/upload (symlink created)"
else
    ok "www/upload symlink already exists"
fi

# ── Mailer: check msmtp can reach postfix ────────────────────────────────────
ok "Testing mail relay (msmtp -> postfix)..."
MAIL_TEST=$(docker exec bitrix_php sh -c \
    '/usr/bin/msmtp --serverinfo --host=postfix --port=25 2>&1 | head -3' 2>/dev/null || echo "skip")
ok "msmtp test: ${MAIL_TEST:-ok}"

ok "Bitrix config complete"