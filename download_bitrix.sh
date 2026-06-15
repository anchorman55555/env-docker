#!/usr/bin/env bash
# ==============================================================================
# download_bitrix.sh -- Downloads "1C-Bitrix: Internet-shop + CRM"
# Extracts to /mnt/bitrix/www ready for the install wizard
# ==============================================================================
set -euo pipefail
G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; RE='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${G}  [OK]${NC} $*"; }
warn() { echo -e "${Y}  [!!]${NC} $*"; }
fail() { echo -e "${RE}  [FAIL]${NC} $*"; exit 1; }
step() { echo; echo -e "${B}================================================================${NC}"; \
         echo -e "${B}  $*${NC}"; \
         echo -e "${B}================================================================${NC}"; }

WWW="${1:-/mnt/bitrix/www}"
DOMAIN="${DOMAIN:-crm.cifroweek.com}"
PROJECT_DIR="${PROJECT_DIR:-/opt/bitrix}"
DL_TMP="/var/tmp/bitrix_dist"

step "1/4 -- Preflight"
[[ $EUID -eq 0 ]] || fail "Run as root"
command -v curl &>/dev/null || dnf install -y curl
command -v tar  &>/dev/null || dnf install -y tar
mkdir -p "$DL_TMP"
ok "Preflight OK"

step "2/4 -- Download"

ok "Downloading bitrixsetup.php (self-installer, ~50KB)..."
curl -fL --progress-bar \
    "https://www.1c-bitrix.ru/download/scripts/bitrixsetup.php" \
    -o "${WWW}/bitrixsetup.php"
chown 979:979 "${WWW}/bitrixsetup.php"
ok "bitrixsetup.php ready -> https://${DOMAIN}/bitrixsetup.php"

echo
ok "Downloading 1C-Bitrix: Internet-shop + CRM (~400MB)..."
ok "  business_encode.tar.gz  = Internet-shop + CRM  <-- this product"
ok "  bitrix24_encode.tar.gz  = Bitrix24 Corporate Portal (alternative)"
curl -fL --progress-bar \
    "https://www.1c-bitrix.ru/download/business_encode.tar.gz" \
    -o "${DL_TMP}/business_encode.tar.gz"
ok "Downloaded: $(du -sh ${DL_TMP}/business_encode.tar.gz | cut -f1)"

step "3/4 -- Extract to ${WWW}"

EXISTING=$(ls -A "$WWW" 2>/dev/null | grep -vE "^lost\+found$|^upload$|^bitrixsetup" | head -1 || true)
if [[ -n "$EXISTING" ]]; then
    BACKUP="/var/backup/www_before_install_$(date +%Y%m%d_%H%M%S).tar.gz"
    warn "Files already exist in $WWW -- backing up to $BACKUP"
    tar czf "$BACKUP" -C "$WWW" . --exclude="./upload" 2>/dev/null || true
    ok "Backup saved: $BACKUP"
    find "$WWW" -mindepth 1 -maxdepth 1 \
        ! -name "upload" ! -name "bitrixsetup.php" -exec rm -rf {} +
fi

tar xzf "${DL_TMP}/business_encode.tar.gz" -C "$WWW"
rm -f "${DL_TMP}/business_encode.tar.gz"
ok "Extracted to $WWW"

step "4/4 -- Permissions"

chown -R 979:979 "$WWW"

# upload dir must point to dedicated SSD LV (80G), not inside www
if [[ -d "${WWW}/upload" && ! -L "${WWW}/upload" ]]; then
    rsync -a --ignore-existing "${WWW}/upload/" /mnt/bitrix/upload/ 2>/dev/null || true
    rm -rf "${WWW}/upload"
fi
[[ -L "${WWW}/upload" ]] || ln -sfn /mnt/bitrix/upload "${WWW}/upload"
chown 979:979 /mnt/bitrix/upload

restorecon -R "$WWW" 2>/dev/null || true
ok "Permissions done: owner=979:979, SELinux contexts restored"

echo
echo -e "${G}+------------------------------------------------------------------+${NC}"
echo -e "${G}|  1C-Bitrix: Internet-shop + CRM -- files ready!                  |${NC}"
echo -e "${G}+------------------------------------------------------------------+${NC}"
echo
echo "STEP 1 -- Open the installer in browser:"
echo "  Self-installer: https://${DOMAIN}/bitrixsetup.php"
echo "  Wizard direct : https://${DOMAIN}/bitrix/wizard/"
echo
echo "STEP 2 -- Wizard DB settings:"
echo "  Host     : mysql"
echo "  Database : bitrix"
echo "  User     : bitrix"
echo "  Password : (see ${PROJECT_DIR}/.deploy_credentials)"
echo "  Charset  : utf8mb4"
echo
echo "STEP 3 -- After wizard, apply Redis + OpenSearch config:"
echo "  bash ${PROJECT_DIR}/deploy/09_bitrix_config.sh"
echo
echo "STEP 4 -- Print all credentials:"
echo "  bash ${PROJECT_DIR}/deploy/10_summary.sh"
