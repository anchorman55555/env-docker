#version=RHEL9
# ==============================================================================
# Kickstart: AlmaLinux 9 — Bitrix24 Stack
# Disk layout per CLAUDE.md / lsblk verified from crm.cifroweek.com
#
# Disks:
#   xvda  400G  HDD   vg-system   OS + Docker + logs + backup
#   xvdb  400G  SSD   vg-project  Bitrix www/cache/upload/session/logs/postfix
#   xvdc  500G  NVMe  vg-data     MySQL + OpenSearch + Redis
#
# Adjust disk names if not Xen (e.g. sda/sdb/sdc for KVM, nvme0n1 for NVMe bare-metal)
# ==============================================================================

# --- Installation mode --------------------------------------------------------
text
install
reboot

# --- Locale & keyboard --------------------------------------------------------
lang ru_RU.UTF-8
keyboard --vckeymap=ru --xlayouts=ru,us --switch=grp:alt_shift_toggle
timezone Europe/Moscow --utc

# --- Network (DHCP on first interface; adjust for static) ---------------------
network --bootproto=dhcp --device=eth0 --onboot=yes --ipv6=auto --hostname=crm.cifroweek.com

# --- Root password (change before use!) ---------------------------------------
# Generate with: python3 -c "import crypt; print(crypt.crypt('PASSWORD', crypt.mksalt(crypt.METHOD_SHA512)))"
rootpw --iscrypted $6$CHANGE_THIS_HASH

# --- SELinux & firewall -------------------------------------------------------
selinux --enforcing
firewall --enabled --service=ssh

# --- Bootloader ---------------------------------------------------------------
# BIOS mode (Xen/older AWS/KVM without UEFI)
bootloader --location=mbr --boot-drive=xvda --append="crashkernel=auto"
# For UEFI: comment above, uncomment below and swap biosboot for efi partition
# bootloader --location=none

# --- Disk selection -----------------------------------------------------------
ignoredisk --only-use=xvda,xvdb,xvdc
zerombr
clearpart --all --initlabel --drives=xvda,xvdb,xvdc

# ==============================================================================
# DISK: xvda (400G HDD) — vg-system
# Layout: 1M biosboot + 1G /boot + rest as LVM PV
# ==============================================================================
part biosboot       --fstype=biosboot  --size=1      --ondisk=xvda
# For UEFI instead of biosboot:
# part /boot/efi    --fstype=efi       --size=600    --ondisk=xvda --fsoptions="umask=0077"
part /boot          --fstype=xfs       --size=1024   --ondisk=xvda
part pv.xvda        --fstype=lvmpv     --size=1      --ondisk=xvda --grow

volgroup vg-system pv.xvda

#  60G  /                   OS root
logvol /              --vgname=vg-system --name=root   --fstype=xfs --size=61440

#  20G  /var                системные данные (перед остальными /var/* LVs!)
logvol /var           --vgname=vg-system --name=var    --fstype=xfs --size=20480

# 150G  /var/lib/docker     Docker images / overlay2
logvol /var/lib/docker --vgname=vg-system --name=docker --fstype=xfs --size=153600

#  30G  /var/log            системные логи
logvol /var/log       --vgname=vg-system --name=log    --fstype=xfs --size=30720

# 139G  /var/backup         локальные резервные копии
logvol /var/backup    --vgname=vg-system --name=backup --fstype=xfs --size=142336

# ==============================================================================
# DISK: xvdb (400G SSD) — vg-project
# Layout: 300G LVM PV (100G оставить нераспределёнными для расширения)
# ==============================================================================
part pv.xvdb          --fstype=lvmpv     --size=307200 --ondisk=xvdb

volgroup vg-project pv.xvdb

#  60G  /mnt/bitrix/www     код сайтов
logvol /mnt/bitrix/www     --vgname=vg-project --name=mnt_bitrix_www     --fstype=xfs --size=61440

# 120G  /mnt/bitrix/cache   Bitrix кэш (managed_cache + stack_cache)
logvol /mnt/bitrix/cache   --vgname=vg-project --name=mnt_bitrix_cache   --fstype=xfs --size=122880

#  80G  /mnt/bitrix/upload  загрузки / фото товаров
logvol /mnt/bitrix/upload  --vgname=vg-project --name=mnt_bitrix_upload  --fstype=xfs --size=81920

#  10G  /mnt/bitrix/session PHP сессии (резервный файловый хранилище, primary = Redis)
logvol /mnt/bitrix/session --vgname=vg-project --name=mnt_bitrix_session --fstype=xfs --size=10240

#  20G  /mnt/bitrix/logs    логи проектов (nginx, mysql, opensearch)
logvol /mnt/bitrix/logs    --vgname=vg-project --name=mnt_bitrix_logs    --fstype=xfs --size=20480

#  10G  /var/spool/postfix  почтовая очередь
logvol /var/spool/postfix  --vgname=vg-project --name=postfix            --fstype=xfs --size=10240

# ==============================================================================
# DISK: xvdc (500G NVMe) — vg-data
# Layout: 440G LVM PV (60G нераспределённые для расширения)
# ==============================================================================
part pv.xvdc          --fstype=lvmpv     --size=450560 --ondisk=xvdc

volgroup vg-data pv.xvdc

# 250G  /var/lib/mysql      MySQL data directory
logvol /var/lib/mysql      --vgname=vg-data --name=var_lib_mysql      --fstype=xfs --size=256000

# 150G  /var/lib/opensearch OpenSearch индексы
logvol /var/lib/opensearch --vgname=vg-data --name=var_lib_opensearch --fstype=xfs --size=153600

#  20G  /var/lib/redis      Redis AOF / RDB snapshots
logvol /var/lib/redis      --vgname=vg-data --name=var_lib_redis      --fstype=xfs --size=20480

#  20G  /var/lib/mysql/tmp  MySQL tmp tables (примонтируется поверх /var/lib/mysql)
logvol /var/lib/mysql/tmp  --vgname=vg-data --name=mysqltmp           --fstype=xfs --size=20480

# ==============================================================================
# Packages
# ==============================================================================
%packages --ignoremissing
@^minimal-environment
@standard
# Core tools
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
# Security
acl
audit
fail2ban
fail2ban-firewalld
firewalld
# FTP
vsftpd
# Mail
msmtp
# Monitoring
sysstat
# Will be installed by deploy.sh (need EPEL / Docker CE repo):
# docker-ce docker-ce-cli containerd.io docker-compose-plugin
%end

# ==============================================================================
# Post (1/2): вне chroot — копируем проект из ISO в установленную систему
# Запускается до chroot-секции; имеет доступ к /mnt/sysimage и к media.
# ==============================================================================
%post --nochroot --log=/mnt/sysimage/root/ks-post-nochroot.log

SYSIMAGE="/mnt/sysimage"
TARBALL_NAME="bitrix-deploy.tar.gz"
TARBALL_DST="/tmp/${TARBALL_NAME}"

echo "=== Поиск tarball проекта ==="

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
    [ $FOUND -eq 0 ] && echo "ВНИМАНИЕ: ${TARBALL_NAME} не найден на media!" && exit 0
fi

echo "=== Извлечение проекта в ${SYSIMAGE}/opt/bitrix ==="
mkdir -p "${SYSIMAGE}/opt/bitrix"
tar xzf "${TARBALL_DST}" -C "${SYSIMAGE}/opt/bitrix"
rm -f "${TARBALL_DST}"

# Права на скрипты
chmod +x "${SYSIMAGE}/opt/bitrix/"*.sh                    2>/dev/null || true
chmod +x "${SYSIMAGE}/opt/bitrix/deploy/"*.sh             2>/dev/null || true
chmod 600 "${SYSIMAGE}/opt/bitrix/".env_* 2>/dev/null || true
chmod 600 "${SYSIMAGE}/opt/bitrix/docker-compose.yml" 2>/dev/null || true

echo "=== Проект успешно распакован ==="
ls -la "${SYSIMAGE}/opt/bitrix/"

%end

# ==============================================================================
# Post (2/2): в chroot — системные настройки
# ==============================================================================
%post --log=/root/ks-post-chroot.log

# --- sysctl: OpenSearch requires vm.max_map_count >= 262144 ------------------
cat > /etc/sysctl.d/99-opensearch.conf << 'EOF'
vm.max_map_count=262144
EOF
sysctl -p /etc/sysctl.d/99-opensearch.conf 2>/dev/null || true

# --- Fix mount point dirs needed for nested LVM mounts -----------------------
mkdir -p /var/lib/mysql/tmp
chmod 1777 /var/lib/mysql/tmp
mkdir -p /var/lib/docker
mkdir -p /var/log

# Bitrix project dirs (on SSD LVs)
mkdir -p /mnt/bitrix/www
mkdir -p /mnt/bitrix/cache
mkdir -p /mnt/bitrix/upload
mkdir -p /mnt/bitrix/session
mkdir -p /mnt/bitrix/logs/{nginx,mysql,opensearch}
mkdir -p /var/spool/postfix

# --- SELinux: label all LVM paths correctly before first boot ----------------
restorecon -R /mnt/bitrix 2>/dev/null || true
restorecon -R /var/spool/postfix 2>/dev/null || true
restorecon -R /var/lib/mysql 2>/dev/null || true
restorecon -R /var/lib/redis 2>/dev/null || true
restorecon -R /var/lib/opensearch 2>/dev/null || true
restorecon -R /opt/bitrix 2>/dev/null || true

# --- SELinux booleans needed by the stack ------------------------------------
setsebool -P ftpd_full_access on 2>/dev/null || true

# --- vsftpd: register passive ports ------------------------------------------
semanage port -a -t ftp_port_t -p tcp 21000-21010 2>/dev/null || true

# --- Docker CE repo (чтобы 00_init.sh не качал его заново) ------------------
dnf install -y dnf-plugins-core 2>/dev/null || true
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null || true

# --- /etc/motd с инструкцией -------------------------------------------------
cat >> /etc/motd << 'MOTD'

============================================================
  Bitrix24 Stack Server — установка завершена
============================================================
  Диски:
    xvda (HDD)   vg-system   /  /var  /var/log  /var/lib/docker  /var/backup
    xvdb (SSD)   vg-project  /mnt/bitrix/{www,cache,upload,session,logs}
    xvdc (NVMe)  vg-data     /var/lib/{mysql,mysql/tmp,opensearch,redis}

  Проект: /opt/bitrix (все конфиги и скрипты уже на месте)

  Следующие шаги:
    bash /opt/bitrix/00_init.sh    # обновление ОС, пакеты, SSH-ключи
    bash /opt/bitrix/deploy.sh     # запуск стека Bitrix24
    bash /opt/bitrix/download_bitrix.sh  # скачать дистрибутив Bitrix
============================================================
MOTD

%end
