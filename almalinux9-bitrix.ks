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
# Pre-install script — nothing needed, partitioning is fully declarative
# ==============================================================================

# ==============================================================================
# Post-install script
# ==============================================================================
%post --log=/root/ks-post.log

# --- sysctl: OpenSearch requires vm.max_map_count >= 262144 ------------------
cat > /etc/sysctl.d/99-opensearch.conf << 'EOF'
vm.max_map_count=262144
EOF
sysctl -p /etc/sysctl.d/99-opensearch.conf 2>/dev/null || true

# --- Fix mount point dirs needed for nested LVM mounts -----------------------
# /var/lib/mysql/tmp is mounted OVER /var/lib/mysql, so the dir must exist
# on the mysql LV itself. We touch it so systemd mounts work correctly.
# (Anaconda should handle this, but we make sure)
mkdir -p /var/lib/mysql/tmp
chmod 1777 /var/lib/mysql/tmp

# /var/lib/docker is mounted over /var (which is also a separate LV)
# /var/log is mounted over /var — same
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

# --- SELinux booleans needed by the stack ------------------------------------
setsebool -P ftpd_full_access on 2>/dev/null || true

# --- vsftpd: register passive ports ------------------------------------------
semanage port -a -t ftp_port_t -p tcp 21000-21010 2>/dev/null || true

# --- Docker CE repo (so deploy.sh can install without extra steps) -----------
dnf install -y dnf-plugins-core 2>/dev/null || true
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null || true

# --- Clone Bitrix project repo (adjust URL before use) ----------------------
# git clone https://github.com/YOUR_ORG/bitrix-docker.git /opt/bitrix
# Uncomment above line and set correct repo URL

# --- Prepare /opt/bitrix dir -------------------------------------------------
mkdir -p /opt/bitrix

# --- Print disk layout summary after install ---------------------------------
cat >> /etc/motd << 'MOTD'

============================================================
  Bitrix24 Stack Server
============================================================
  Disk layout:
    xvda (HDD)   vg-system   /  /var  /var/log  /var/lib/docker  /var/backup
    xvdb (SSD)   vg-project  /mnt/bitrix/{www,cache,upload,session,logs}  /var/spool/postfix
    xvdc (NVMe)  vg-data     /var/lib/{mysql,mysql/tmp,opensearch,redis}

  Next steps:
    cd /opt/bitrix
    git clone <repo_url> .
    for f in *.example; do cp "$f" "${f%.example}"; done
    nano .env_sql .env_push docker-compose.yml
    bash deploy.sh
    bash download_bitrix.sh
============================================================
MOTD

%end
