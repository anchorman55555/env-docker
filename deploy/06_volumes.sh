#!/usr/bin/env bash
step "STEP 6/8 -- Volumes, permissions, msmtp"

# --- Symlinks: /opt/bitrix/volumes/ -> all LVM mount points ---
mkdir -p "${PROJECT_DIR}/volumes"
ln -sfn /mnt/bitrix/www          "${PROJECT_DIR}/volumes/www"
ln -sfn /mnt/bitrix/upload       "${PROJECT_DIR}/volumes/upload"
ln -sfn /mnt/bitrix/cache        "${PROJECT_DIR}/volumes/cache"
ln -sfn /mnt/bitrix/session      "${PROJECT_DIR}/volumes/session"
ln -sfn /mnt/bitrix/logs         "${PROJECT_DIR}/volumes/logs"
ln -sfn /var/spool/postfix       "${PROJECT_DIR}/volumes/postfix"
ln -sfn /var/lib/mysql           "${PROJECT_DIR}/volumes/mysql"
ln -sfn /var/lib/mysql/tmp       "${PROJECT_DIR}/volumes/mysql-tmp"
ln -sfn /var/lib/opensearch      "${PROJECT_DIR}/volumes/opensearch"
ln -sfn /var/lib/redis           "${PROJECT_DIR}/volumes/redis"
ln -sfn /var/lib/docker          "${PROJECT_DIR}/volumes/docker"
ln -sfn /var/backup              "${PROJECT_DIR}/volumes/backup"
ok "Symlinks created in ${PROJECT_DIR}/volumes/"

# --- Upload: migrate www/upload -> dedicated LV, fix owner ---
SRC="${FTP_HOME}/upload"
DST="/mnt/bitrix/upload"
if [[ -d "$SRC" ]] && [[ "$(ls -A "$SRC" 2>/dev/null)" ]]; then
  ok "Syncing ${SRC} -> ${DST} ..."
  rsync -a --ignore-existing "$SRC/" "$DST/"
fi
chown -R 979:979 "$DST"
mkdir -p "${DST}"/{tmp,resize_cache,iblock}
chown 979:979 "${DST}"/{tmp,resize_cache,iblock}
restorecon -R "$DST" 2>/dev/null || true
ok "Upload dir ready: /mnt/bitrix/upload (owner 979:979)"

# --- Directory permissions for DB volumes ---
chown -R 979:979 /var/lib/mysql/tmp 2>/dev/null || true
restorecon -R /var/lib/mysql/tmp 2>/dev/null || true
ok "MySQL tmpdir /var/lib/mysql/tmp (NVMe, owner 979:979)"

chown -R 979:979 /mnt/bitrix/session 2>/dev/null || true
restorecon -R /mnt/bitrix/session 2>/dev/null || true
ok "Session dir /mnt/bitrix/session (owner 979:979)"

mkdir -p /mnt/bitrix/logs/{nginx,mysql,opensearch}
restorecon -R /mnt/bitrix/logs 2>/dev/null || true
ok "Log subdirs: nginx, mysql, opensearch"

# --- SELinux: apply contexts on all Docker-mounted LVM paths ---
for dir in /mnt/bitrix/www /mnt/bitrix/cache /mnt/bitrix/upload \
           /mnt/bitrix/session /mnt/bitrix/logs \
           /var/lib/mysql /var/lib/mysql/tmp \
           /var/lib/opensearch /var/lib/redis /var/spool/postfix; do
  restorecon -R "$dir" 2>/dev/null || true
done
ok "SELinux contexts applied to all LVM paths"

# --- msmtp relay config for PHP/cron containers ---
mkdir -p "${PROJECT_DIR}/data/msmtp"
cat > "${PROJECT_DIR}/data/msmtp/msmtprc" << 'EOF'
defaults
auth           off
tls            off
logfile        /tmp/msmtp.log

account        relay
host           postfix
port           25

account default : relay
EOF
ok "msmtp config: PHP mail() -> postfix:25 -> smtp.mail.ru:587"