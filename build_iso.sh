#!/usr/bin/env bash
# ==============================================================================
# build_iso.sh -- Создание кастомного ISO AlmaLinux 9
#
# Что делает:
#   1. Устанавливает инструменты (xorriso, syslinux, isomd5sum)
#   2. Скачивает AlmaLinux 9 minimal ISO (если нет кэша)
#   3. Извлекает ISO, модифицирует boot-меню (авто-старт с KS)
#   4. Создаёт tarball проекта /opt/bitrix (включая credentials)
#   5. Перепаковывает ISO, добавляет MD5, делает гибридным (USB+CD)
#   6. Выводит путь и команду для скачивания
#
# Запускать от root на сервере AlmaLinux 9:
#   bash build_iso.sh
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  [OK]${NC} $*"; }
warn() { echo -e "${YELLOW}  [!!]${NC} $*"; }
fail() { echo -e "${RED}  [FAIL]${NC} $*"; exit 1; }
step() {
    echo
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

[[ $EUID -eq 0 ]] || fail "Запускать от root"

# ------------------------------------------------------------------------------
# Конфигурация
# ------------------------------------------------------------------------------
ALMA_ISO_URL="https://repo.almalinux.org/almalinux/9/isos/x86_64/AlmaLinux-9-latest-x86_64-minimal.iso"
ALMA_SHA_URL="https://repo.almalinux.org/almalinux/9/isos/x86_64/CHECKSUM"

ORIG_ISO="/var/tmp/almalinux9-minimal.iso"
WORK_DIR="/var/tmp/alma9_iso_build"
MOUNT_DIR="/var/tmp/alma9_iso_mount"
OUTPUT_ISO="/var/tmp/almalinux9-bitrix-$(date +%Y%m%d).iso"

PROJECT_DIR="${PROJECT_DIR:-/opt/bitrix}"
KS_FILE="${PROJECT_DIR}/almalinux9-bitrix.ks"

# ==============================================================================
step "1/6 — Установка инструментов"
# ==============================================================================
dnf install -y xorriso syslinux isomd5sum genisoimage
ok "xorriso, syslinux, isomd5sum установлены"

# ==============================================================================
step "2/6 — Скачивание AlmaLinux 9 minimal ISO"
# ==============================================================================
if [[ -f "$ORIG_ISO" ]]; then
    warn "ISO уже есть: $ORIG_ISO ($(du -sh "$ORIG_ISO" | cut -f1))"
    warn "Пропускаем скачивание. Удалите файл для повторного скачивания."
else
    ok "Скачиваем AlmaLinux 9 minimal ISO (~1.5 GB)..."
    curl -fL --progress-bar "$ALMA_ISO_URL" -o "$ORIG_ISO"
    ok "Скачано: $(du -sh "$ORIG_ISO" | cut -f1)"

    ok "Проверяем контрольную сумму..."
    CHECKSUM_FILE="/var/tmp/alma9_CHECKSUM"
    curl -fsSL "$ALMA_SHA_URL" -o "$CHECKSUM_FILE"
    EXPECTED_SHA=$(grep "$(basename "$ORIG_ISO")" "$CHECKSUM_FILE" | grep SHA256 | awk '{print $NF}')
    if [[ -n "$EXPECTED_SHA" ]]; then
        ACTUAL_SHA=$(sha256sum "$ORIG_ISO" | awk '{print $1}')
        if [[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]]; then
            ok "SHA256 совпадает"
        else
            fail "SHA256 НЕ совпадает! Скачайте ISO заново."
        fi
    else
        warn "Не удалось найти контрольную сумму в CHECKSUM-файле — пропускаем проверку"
    fi
fi

# ==============================================================================
step "3/6 — Извлечение ISO"
# ==============================================================================
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$MOUNT_DIR"

ok "Монтируем ISO..."
mount -o loop,ro "$ORIG_ISO" "$MOUNT_DIR"

ok "Копируем содержимое ISO..."
rsync -a --info=progress2 "$MOUNT_DIR/" "$WORK_DIR/"
sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

chmod -R u+w "$WORK_DIR"

# Определяем Volume ID оригинального ISO
ORIG_LABEL=$(isoinfo -d -i "$ORIG_ISO" 2>/dev/null | grep "Volume id:" | awk '{print $3}')
[[ -z "$ORIG_LABEL" ]] && ORIG_LABEL=$(blkid -s LABEL -o value "$ORIG_ISO" 2>/dev/null || echo "AlmaLinux-9-x86_64")
ok "Volume ID оригинального ISO: ${ORIG_LABEL}"

# ==============================================================================
step "4/6 — Добавление Kickstart + проекта"
# ==============================================================================

# --- Kickstart ----------------------------------------------------------------
[[ -f "$KS_FILE" ]] || fail "Kickstart не найден: $KS_FILE"
cp "$KS_FILE" "${WORK_DIR}/ks.cfg"
ok "Kickstart скопирован → /ks.cfg"

# --- Tarball проекта ----------------------------------------------------------
DEPLOY_DIR="${WORK_DIR}/deploy"
TARBALL="${DEPLOY_DIR}/bitrix-deploy.tar.gz"
mkdir -p "$DEPLOY_DIR"

ok "Создаём tarball проекта ${PROJECT_DIR}..."
tar czf "$TARBALL" \
    -C "$PROJECT_DIR" \
    --exclude='.git' \
    --exclude='volumes' \
    --exclude='*.log' \
    --exclude='data/ssl/root_ca/private' \
    --exclude='data/ssl/intermediate_ca/private' \
    --exclude='data/ssl/servers/private' \
    --exclude='data/ssl/*.key.pem' \
    .
ok "Tarball создан: $(du -sh "$TARBALL" | cut -f1)"

# --- Модификация boot меню (BIOS + UEFI) --------------------------------------
KS_PARAM="inst.ks=cdrom:/ks.cfg inst.text"

# BIOS: isolinux/isolinux.cfg
if [[ -f "${WORK_DIR}/isolinux/isolinux.cfg" ]]; then
    # Добавляем KS-параметры ко всем строкам append
    sed -i "/append/ s|$| ${KS_PARAM}|" "${WORK_DIR}/isolinux/isolinux.cfg"
    # Устанавливаем таймаут 1 сек (syslinux: timeout в 1/10 сек = 10)
    sed -i 's/^timeout [0-9]*/timeout 10/' "${WORK_DIR}/isolinux/isolinux.cfg"
    # Если timeout отсутствует — добавляем
    grep -q "^timeout" "${WORK_DIR}/isolinux/isolinux.cfg" || \
        sed -i '1s/^/timeout 10\n/' "${WORK_DIR}/isolinux/isolinux.cfg"
    ok "BIOS boot: isolinux.cfg обновлён"
else
    warn "isolinux/isolinux.cfg не найден (возможно UEFI-only ISO)"
fi

# UEFI: EFI/BOOT/grub.cfg
for GRUB_CFG in \
    "${WORK_DIR}/EFI/BOOT/grub.cfg" \
    "${WORK_DIR}/boot/grub2/grub.cfg"; do
    if [[ -f "$GRUB_CFG" ]]; then
        sed -i "/linuxefi/ s|$| ${KS_PARAM}|" "$GRUB_CFG"
        sed -i 's/set timeout=[0-9]*/set timeout=1/' "$GRUB_CFG"
        ok "UEFI boot: $(basename $(dirname $GRUB_CFG))/grub.cfg обновлён"
    fi
done

# ==============================================================================
step "5/6 — Перепаковка ISO"
# ==============================================================================

# Путь к MBR-блоку для гибридной загрузки (USB + CD)
ISOHDPFX=""
for p in /usr/share/syslinux/isohdpfx.bin /usr/lib/syslinux/bios/isohdpfx.bin; do
    [[ -f "$p" ]] && ISOHDPFX="$p" && break
done

XORRISO_OPTS=(
    -as mkisofs
    -o "${OUTPUT_ISO}"
    -R -J -T -v
    -V "${ORIG_LABEL}"
)

# BIOS boot (isolinux)
if [[ -f "${WORK_DIR}/isolinux/isolinux.bin" ]]; then
    XORRISO_OPTS+=(
        -b isolinux/isolinux.bin
        -c isolinux/boot.cat
        -no-emul-boot
        -boot-load-size 4
        -boot-info-table
    )
fi

# UEFI boot (efiboot.img)
if [[ -f "${WORK_DIR}/images/efiboot.img" ]]; then
    XORRISO_OPTS+=(
        -eltorito-alt-boot
        -e images/efiboot.img
        -no-emul-boot
        -isohybrid-gpt-basdat
    )
fi

# Hybrid MBR для загрузки с USB
if [[ -n "$ISOHDPFX" ]]; then
    XORRISO_OPTS+=(--isohybrid-mbr "$ISOHDPFX")
    ok "Hybrid MBR: $ISOHDPFX"
else
    warn "isohdpfx.bin не найден — ISO не будет загружаться с USB (только CD/DVD)"
fi

ok "Запускаем xorriso..."
xorriso "${XORRISO_OPTS[@]}" "${WORK_DIR}/"

ok "Встраиваем ISO MD5 для проверки media при загрузке..."
implantisomd5 "${OUTPUT_ISO}" 2>/dev/null || warn "implantisomd5 не выполнен (не критично)"

ISO_SIZE=$(du -sh "${OUTPUT_ISO}" | cut -f1)
ISO_SHA256=$(sha256sum "${OUTPUT_ISO}" | awk '{print $1}')
ok "ISO создан: ${OUTPUT_ISO} (${ISO_SIZE})"

# ==============================================================================
step "6/6 — Результат"
# ==============================================================================

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              КАСТОМНЫЙ ISO СОЗДАН УСПЕШНО                           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  Файл   : ${CYAN}${OUTPUT_ISO}${NC}"
echo -e "  Размер : ${ISO_SIZE}"
echo -e "  SHA256 : ${ISO_SHA256}"
echo
echo -e "${YELLOW}  Содержимое ISO:${NC}"
echo "    /ks.cfg                     — Kickstart (авто-разметка дисков)"
echo "    /deploy/bitrix-deploy.tar.gz — Проект /opt/bitrix со всеми конфигами"
echo "    /isolinux/, /EFI/BOOT/      — BIOS + UEFI загрузчики (авто-старт)"
echo
echo -e "${YELLOW}  Скачать ISO на Windows:${NC}"
echo "    scp root@$(hostname -I | awk '{print $1}'):${OUTPUT_ISO} ."
echo
echo -e "${YELLOW}  ⚠  ISO содержит credentials (SMTP пароли, MySQL, push-key).${NC}"
echo -e "${YELLOW}     Не публикуйте и не передавайте посторонним.${NC}"
echo
echo -e "${YELLOW}  Установка:${NC}"
echo "    1. Записать ISO на USB: Rufus (Windows) или dd (Linux)"
echo "       dd if=$(basename $OUTPUT_ISO) of=/dev/sdX bs=4M status=progress"
echo "    2. Загрузиться с USB/CD на целевом сервере"
echo "    3. Установка запустится автоматически (таймаут 1 сек)"
echo "    4. После установки и перезагрузки:"
echo "       bash /opt/bitrix/00_init.sh   # финальная инициализация"
echo "       bash /opt/bitrix/deploy.sh    # деплой стека"
echo

# Очистка рабочей директории
read -r -t 10 -p "Удалить рабочую директорию ${WORK_DIR}? [Y/n] " CLEAN || CLEAN="Y"
if [[ "${CLEAN,,}" != "n" ]]; then
    rm -rf "$WORK_DIR"
    ok "Рабочая директория удалена"
fi
