#version=RHEL9
# ==============================================================================
# Kickstart: AlmaLinux 9 — Bitrix24 Stack
# Диски определяются автоматически в %pre (XCP-ng, KVM, bare metal)
# BIOS/UEFI определяется автоматически
#
# XCP-ng:    xvda / xvdb / xvdc
# KVM virtio: vda  / vdb  / vdc
# KVM SCSI / bare metal: sda / sdb / sdc
#
# Порядок дисков по размеру (от меньшего к большему):
#   1-й диск (меньший)  → vg-system   (HDD, ~400G)
#   2-й диск            → vg-project  (SSD, ~400G)
#   3-й диск (больший)  → vg-data     (NVMe, ~500G)
#
# Если диски одинакового размера — порядок по имени (алфавитный).
# ==============================================================================

# --- Установка ----------------------------------------------------------------
install
text
reboot

# --- Локаль и клавиатура ------------------------------------------------------
lang ru_RU.UTF-8
keyboard --vckeymap=ru --xlayouts=ru,us --switch=grp:alt_shift_toggle
timezone Europe/Moscow --utc

# --- Сеть (DHCP; для статики раскомментируйте и настройте) -------------------
network --bootproto=dhcp --device=link --onboot=yes --ipv6=auto --hostname=bitrix-server
# network --bootproto=static --ip=192.168.1.10 --netmask=255.255.255.0 \
#         --gateway=192.168.1.1 --nameserver=8.8.8.8 --device=eth0 \
#         --onboot=yes --hostname=crm.example.com

# --- Root пароль (ЗАМЕНИТЬ перед использованием!) ----------------------------
# Генерация: python3 -c "import crypt; print(crypt.crypt('ПАРОЛЬ', crypt.mksalt(crypt.METHOD_SHA512)))"
rootpw --iscrypted $6$REPLACE_THIS_HASH_BEFORE_USE

# --- SELinux и фаервол --------------------------------------------------------
selinux --enforcing
firewall --enabled --service=ssh

# ==============================================================================
# Разметка дисков (генерируется в %pre → /tmp/disk-setup.ks)
# ==============================================================================
%include /tmp/disk-setup.ks

# ==============================================================================
# Пакеты
# ==============================================================================
%packages --ignoremissing
@^minimal-environment
@standard
bash-completion
bind-utils
curl
git
htop
iotop
lsof
lvm2
mc
net-tools
nfs-utils
policycoreutils-python-utils
python3
rsync
screen
tar
tcpdump
telnet
tmux
unzip
wget
acl
audit
fail2ban
fail2ban-firewalld
firewalld
vsftpd
msmtp
sysstat
%end

# ==============================================================================
# %pre — определение дисков и BIOS/UEFI, генерация /tmp/disk-setup.ks
# ==============================================================================
%pre --log=/tmp/ks-pre.log
#!/bin/bash

echo "=== Kickstart %pre: определение дисков и режима загрузки ==="

# --- BIOS или UEFI? ---
if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="uefi"
else
    BOOT_MODE="bios"
fi
echo "Boot mode: $BOOT_MODE"

# --- Собираем список дисков (исключаем CD/DVD, loop, sr*) ---
declare -a ALL_DISKS
while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    TYPE=$(echo "$line" | awk '{print $2}')
    [ "$TYPE" = "disk" ] || continue
    # Пропускаем оптические приводы
    [[ "$NAME" =~ ^sr ]] && continue
    # Пропускаем loop-устройства
    [[ "$NAME" =~ ^loop ]] && continue
    ALL_DISKS+=("$NAME")
done < <(lsblk -ndo NAME,TYPE 2>/dev/null | sort)

echo "Все найденные диски: ${ALL_DISKS[*]:-none}"

# --- Фильтр: только диски >= 20 ГБ (исключает USB-инсталляторы) ---
declare -a DISKS
for D in "${ALL_DISKS[@]}"; do
    SIZE_BYTES=$(lsblk -ndbo SIZE "/dev/$D" 2>/dev/null || echo 0)
    if [ "$SIZE_BYTES" -gt $((20 * 1024 * 1024 * 1024)) ]; then
        DISKS+=("$D")
    else
        echo "Пропускаем /dev/$D (< 20GB, возможно USB-носитель)"
    fi
done

echo "Диски >= 20GB: ${DISKS[*]:-none}"

# --- Сортировка по размеру (от меньшего к большему) ---
declare -a SORTED_DISKS
while IFS= read -r line; do
    SORTED_DISKS+=("$line")
done < <(
    for D in "${DISKS[@]}"; do
        SIZE=$(lsblk -ndbo SIZE "/dev/$D" 2>/dev/null || echo 0)
        echo "$SIZE $D"
    done | sort -n | awk '{print $2}'
)

echo "Диски после сортировки по размеру: ${SORTED_DISKS[*]:-none}"

# --- Проверка: нужно минимум 3 диска ---
if [ ${#SORTED_DISKS[@]} -lt 3 ]; then
    echo "ОШИБКА: найдено только ${#SORTED_DISKS[@]} диска(ов) >= 20GB, нужно минимум 3!"
    echo "Используем fallback (xvda/vda/sda)..."
    # Определяем prefix по типу виртуализации
    if [ -d /sys/bus/xen ]; then
        SORTED_DISKS=("xvda" "xvdb" "xvdc")
    elif [ -d /sys/bus/virtio ]; then
        SORTED_DISKS=("vda" "vdb" "vdc")
    else
        SORTED_DISKS=("sda" "sdb" "sdc")
    fi
    echo "Fallback диски: ${SORTED_DISKS[*]}"
fi

D1="${SORTED_DISKS[0]}"   # 1-й (меньший)  → vg-system  (HDD)
D2="${SORTED_DISKS[1]}"   # 2-й            → vg-project (SSD)
D3="${SORTED_DISKS[2]}"   # 3-й (больший)  → vg-data    (NVMe)

echo "Назначение дисков:"
echo "  D1=/dev/$D1  → vg-system  (/, /var, /var/lib/docker, /var/log, /var/backup)"
echo "  D2=/dev/$D2  → vg-project (/mnt/bitrix/*, /var/spool/postfix)"
echo "  D3=/dev/$D3  → vg-data    (/var/lib/mysql, opensearch, redis)"

# --- Генерация /tmp/disk-setup.ks ---
{
    echo "# Автоматически сгенерировано %pre kickstart-скриптом"
    echo "# Boot mode: $BOOT_MODE"
    echo "# D1=/dev/$D1  D2=/dev/$D2  D3=/dev/$D3"
    echo ""

    # Загрузчик
    if [ "$BOOT_MODE" = "uefi" ]; then
        echo "bootloader --location=efi --boot-drive=${D1} --append=\"crashkernel=auto\""
    else
        echo "bootloader --location=mbr --boot-drive=${D1} --append=\"crashkernel=auto\""
    fi
    echo ""

    # Выбор дисков
    echo "ignoredisk --only-use=${D1},${D2},${D3}"
    echo "zerombr"
    echo "clearpart --all --initlabel --drives=${D1},${D2},${D3}"
    echo ""

    # ── D1: vg-system ──────────────────────────────────────────────────────
    echo "# ── D1: /dev/${D1} → vg-system"
    if [ "$BOOT_MODE" = "uefi" ]; then
        echo "part /boot/efi --fstype=efi --size=600 --ondisk=${D1} --fsoptions=\"umask=0077,shortname=winnt\""
    else
        echo "part biosboot  --fstype=biosboot --size=1 --ondisk=${D1}"
    fi
    echo "part /boot     --fstype=xfs     --size=1024 --ondisk=${D1}"
    echo "part pv.disk1  --fstype=lvmpv   --size=1    --ondisk=${D1} --grow"
    echo ""

    # ── D2: vg-project ─────────────────────────────────────────────────────
    echo "# ── D2: /dev/${D2} → vg-project (300G, 100G свободно для роста)"
    echo "part pv.disk2  --fstype=lvmpv   --size=307200 --ondisk=${D2}"
    echo ""

    # ── D3: vg-data ────────────────────────────────────────────────────────
    echo "# ── D3: /dev/${D3} → vg-data (440G, 60G свободно для роста)"
    echo "part pv.disk3  --fstype=lvmpv   --size=450560 --ondisk=${D3}"
    echo ""

    # Volume Groups
    echo "volgroup vg-system  pv.disk1"
    echo "volgroup vg-project pv.disk2"
    echo "volgroup vg-data    pv.disk3"
    echo ""

    # ── Logical Volumes: vg-system ──────────────────────────────────────────
    echo "# ── vg-system LVs"
    echo "logvol /               --vgname=vg-system  --name=root   --fstype=xfs --size=61440"
    echo "logvol /var            --vgname=vg-system  --name=var    --fstype=xfs --size=20480"
    echo "logvol /var/lib/docker --vgname=vg-system  --name=docker --fstype=xfs --size=153600"
    echo "logvol /var/log        --vgname=vg-system  --name=log    --fstype=xfs --size=30720"
    echo "logvol /var/backup     --vgname=vg-system  --name=backup --fstype=xfs --size=142336"
    echo ""

    # ── Logical Volumes: vg-project ─────────────────────────────────────────
    echo "# ── vg-project LVs"
    echo "logvol /mnt/bitrix/www     --vgname=vg-project --name=mnt_bitrix_www     --fstype=xfs --size=61440"
    echo "logvol /mnt/bitrix/cache   --vgname=vg-project --name=mnt_bitrix_cache   --fstype=xfs --size=122880"
    echo "logvol /mnt/bitrix/upload  --vgname=vg-project --name=mnt_bitrix_upload  --fstype=xfs --size=81920"
    echo "logvol /mnt/bitrix/session --vgname=vg-project --name=mnt_bitrix_session --fstype=xfs --size=10240"
    echo "logvol /mnt/bitrix/logs    --vgname=vg-project --name=mnt_bitrix_logs    --fstype=xfs --size=20480"
    echo "logvol /var/spool/postfix  --vgname=vg-project --name=postfix            --fstype=xfs --size=10240"
    echo ""

    # ── Logical Volumes: vg-data ────────────────────────────────────────────
    echo "# ── vg-data LVs"
    echo "logvol /var/lib/mysql      --vgname=vg-data --name=var_lib_mysql      --fstype=xfs --size=256000"
    echo "logvol /var/lib/opensearch --vgname=vg-data --name=var_lib_opensearch --fstype=xfs --size=153600"
    echo "logvol /var/lib/redis      --vgname=vg-data --name=var_lib_redis      --fstype=xfs --size=20480"
    echo "logvol /var/lib/mysql/tmp  --vgname=vg-data --name=mysqltmp           --fstype=xfs --size=20480"

} > /tmp/disk-setup.ks

echo "=== Сгенерированный /tmp/disk-setup.ks ==="
cat /tmp/disk-setup.ks

%end

# ==============================================================================
# %post (1/2): вне chroot — копируем проект из ISO в установленную систему
# ==============================================================================
%post --nochroot --log=/mnt/sysimage/root/ks-post-nochroot.log

SYSIMAGE="/mnt/sysimage"
TARBALL_NAME="bitrix-deploy.tar.gz"
TARBALL_DST="/tmp/${TARBALL_NAME}"

echo "=== Поиск tarball проекта на установочном носителе ==="

# Anaconda монтирует ISO-источник в /run/install/repo
if [ -f "/run/install/repo/deploy/${TARBALL_NAME}" ]; then
    cp "/run/install/repo/deploy/${TARBALL_NAME}" "${TARBALL_DST}"
    echo "Найден в /run/install/repo/deploy/"
else
    # Запасной вариант: монтируем CD/DVD явно
    FOUND=0
    for DEV in /dev/sr0 /dev/sr1 /dev/cdrom /dev/dvd /dev/hdc; do
        [ -b "$DEV" ] || continue
        mkdir -p /tmp/_cdmnt
        mount -o ro "$DEV" /tmp/_cdmnt 2>/dev/null || continue
        if [ -f "/tmp/_cdmnt/deploy/${TARBALL_NAME}" ]; then
            cp "/tmp/_cdmnt/deploy/${TARBALL_NAME}" "${TARBALL_DST}"
            echo "Найден на устройстве: $DEV"
            FOUND=1
        fi
        umount /tmp/_cdmnt
        [ $FOUND -eq 1 ] && break
    done
    if [ $FOUND -eq 0 ]; then
        echo "ВНИМАНИЕ: ${TARBALL_NAME} не найден на media — проект не скопирован!"
        exit 0
    fi
fi

echo "=== Извлечение проекта в ${SYSIMAGE}/opt/bitrix ==="
mkdir -p "${SYSIMAGE}/opt/bitrix"
tar xzf "${TARBALL_DST}" -C "${SYSIMAGE}/opt/bitrix"
rm -f "${TARBALL_DST}"

chmod +x "${SYSIMAGE}/opt/bitrix/"*.sh                2>/dev/null || true
chmod +x "${SYSIMAGE}/opt/bitrix/deploy/"*.sh         2>/dev/null || true
chmod 600 "${SYSIMAGE}/opt/bitrix/".env_*   2>/dev/null || true
chmod 600 "${SYSIMAGE}/opt/bitrix/docker-compose.yml" 2>/dev/null || true

echo "=== Проект успешно распакован ==="
ls -la "${SYSIMAGE}/opt/bitrix/"

%end

# ==============================================================================
# %post (2/2): в chroot — системные настройки
# ==============================================================================
%post --log=/root/ks-post-chroot.log

# --- sysctl ------------------------------------------------------------------
cat > /etc/sysctl.d/99-opensearch.conf << 'EOF'
vm.max_map_count=262144
EOF
sysctl -p /etc/sysctl.d/99-opensearch.conf 2>/dev/null || true

# --- Точки монтирования для вложенных LVM ------------------------------------
mkdir -p /var/lib/mysql/tmp
chmod 1777 /var/lib/mysql/tmp
mkdir -p /var/lib/docker
mkdir -p /var/log

# --- Директории проекта (на SSD LV) -----------------------------------------
mkdir -p /mnt/bitrix/www
mkdir -p /mnt/bitrix/cache
mkdir -p /mnt/bitrix/upload
mkdir -p /mnt/bitrix/session
mkdir -p /mnt/bitrix/logs/{nginx,mysql,opensearch}
mkdir -p /var/spool/postfix

# --- SELinux: метки файловых систем ------------------------------------------
restorecon -R /mnt/bitrix       2>/dev/null || true
restorecon -R /var/spool/postfix 2>/dev/null || true
restorecon -R /var/lib/mysql    2>/dev/null || true
restorecon -R /var/lib/redis    2>/dev/null || true
restorecon -R /var/lib/opensearch 2>/dev/null || true
restorecon -R /opt/bitrix       2>/dev/null || true

# --- SELinux booleans --------------------------------------------------------
setsebool -P ftpd_full_access on 2>/dev/null || true

# --- vsftpd: пассивные порты -------------------------------------------------
semanage port -a -t ftp_port_t -p tcp 21000-21010 2>/dev/null || true

# --- Docker CE repo ----------------------------------------------------------
dnf install -y dnf-plugins-core 2>/dev/null || true
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null || true

# --- /opt/bitrix (если не был скопирован из ISO) -----------------------------
mkdir -p /opt/bitrix

# --- /etc/motd ---------------------------------------------------------------
cat >> /etc/motd << 'MOTD'

============================================================
  Bitrix24 Stack Server — установка завершена
============================================================
  Диски (определены автоматически, см. /tmp/ks-pre.log):
    vg-system   / /var /var/log /var/lib/docker /var/backup
    vg-project  /mnt/bitrix/{www,cache,upload,session,logs}
    vg-data     /var/lib/{mysql,mysql/tmp,opensearch,redis}

  Проект: /opt/bitrix (все конфиги и скрипты уже на месте)

  Следующие шаги:
    bash /opt/bitrix/00_init.sh         # обновление ОС, guest tools, пакеты
    bash /opt/bitrix/deploy.sh          # запуск стека Bitrix24
    bash /opt/bitrix/download_bitrix.sh # скачать дистрибутив Bitrix
============================================================
MOTD

%end
