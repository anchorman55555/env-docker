#!/usr/bin/env bash
step "STEP 1/8 -- Preflight checks"

[[ $EUID -eq 0 ]] || fail "Must run as root: sudo bash deploy.sh"
cd "$PROJECT_DIR" || fail "Project dir $PROJECT_DIR not found. git clone <url> $PROJECT_DIR"

# .env files
echo; ok "Checking .env files..."
MISSING=0
for f in .env .env_php .env_sql .env_redis .env_ssl .env_push .env_push_pub .env_push_sub; do
  [[ -f "$f" ]] && ok "  $f" || { warn "  MISSING: $f  (copy ${f}.example and fill secrets)"; MISSING=$((MISSING+1)); }
done
[[ $MISSING -gt 0 ]] && fail "$MISSING env file(s) missing"

# LVM mounts
echo; ok "Checking LVM mounts..."
WARN=0
for mp in \
  "/mnt/bitrix/www:/SSD 60G - site files" \
  "/mnt/bitrix/cache:/SSD 120G - Bitrix cache" \
  "/mnt/bitrix/upload:/SSD 80G - uploads" \
  "/mnt/bitrix/session:/SSD 10G - PHP sessions" \
  "/mnt/bitrix/logs:/SSD 20G - project logs" \
  "/var/spool/postfix:/SSD 10G - mail queue" \
  "/var/lib/mysql:/NVMe 250G - MySQL data" \
  "/var/lib/mysql/tmp:/NVMe 20G - MySQL tmpdir" \
  "/var/lib/opensearch:/NVMe 150G - OpenSearch" \
  "/var/lib/redis:/NVMe 20G - Redis"; do
  mnt="${mp%%:*}"; desc="${mp##*:}"
  mountpoint -q "$mnt" 2>/dev/null && ok "  $mnt  ($desc)" || { warn "  NOT MOUNTED: $mnt ($desc)"; WARN=$((WARN+1)); }
done
[[ $WARN -gt 0 ]] && warn "$WARN LVM volumes not mounted -- check /etc/fstab"

ok "Preflight done"