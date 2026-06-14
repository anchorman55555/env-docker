#!/usr/bin/env bash
# =============================================================================
# Bitrix24 Docker Stack ? Deploy Script
# Server: crm.cifroweek.com (AlmaLinux 9.8, 64GB RAM, 30-core Xeon 8592+)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }
step() { echo -e "\n${BLUE}===> $*${NC}"; }
info() { echo -e "       $*"; }

# =============================================================================
# CONFIG ? change these if deploying to a different server
# =============================================================================
SERVER_IP="91.239.143.137"
DOMAIN="crm.cifroweek.com"
PROJECT_DIR="/opt/bitrix"

TRUSTED_IPS=(
  195.54.32.168 37.28.181.201 77.37.135.235 82.149.208.58
  91.239.143.134 91.239.143.135 91.239.143.136 91.239.143.137
  91.239.143.138 91.239.143.139 82.149.214.118
  192.168.1.0/24 192.168.10.0/24 172.16.10.0/24
  107.173.149.222 88.84.205.109 92.50.195.50 83.219.151.30
)

FTP_USER="ftpadmin"
FTP_HOME="/mnt/bitrix/www"

# =============================================================================
# 0. Preflight checks
# =============================================================================
step "0. Preflight checks"

[[ $EUID -eq 0 ]] || fail "Run as root (sudo -i)"
[[ -d "$PROJECT_DIR" ]] || fail "Project dir $PROJECT_DIR not found ? clone the repo first:
  git clone <repo_url> $PROJECT_DIR"

command -v docker &>/dev/null || fail "Docker not installed. Install Docker CE first:
  dnf install -y dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker"

# Verify LVM mounts
LVM_MOUNTS=(
  /mnt/bitrix/www /mnt/bitrix/cache /mnt/bitrix/upload
  /mnt/bitrix/session /mnt/bitrix/logs /mnt/bitrix/logs
  /var/spool/postfix /var/lib/mysql /var/lib/mysql/tmp
  /var/lib/opensearch /var/lib/redis
)
MISSING=0
for mp in "${LVM_MOUNTS[@]}"; do
  if ! mountpoint -q "$mp" 2>/dev/null; then
    warn "LVM volume not mounted: $mp"
    MISSING=$((MISSING+1))
  fi
done
[[ $MISSING -eq 0 ]] && ok "All LVM volumes mounted" || warn "$MISSING LVM mounts missing ? check /etc/fstab and LVM setup"

ok "Preflight done"

# =============================================================================
# 1. System packages
# =============================================================================
step "1. Installing system packages"

dnf install -y vsftpd fail2ban fail2ban-firewalld msmtp 2>/dev/null
systemctl enable vsftpd fail2ban
ok "vsftpd, fail2ban, msmtp installed"

# =============================================================================
# 2. vsftpd ? FTP server with FTPS
# =============================================================================
step "2. Configuring vsftpd"

cat > /etc/vsftpd/vsftpd.conf << VSFTPD
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
xferlog_std_format=NO
idle_session_timeout=600
data_connection_timeout=120
listen=YES
listen_ipv6=NO
pam_service_name=vsftpd
userlist_enable=YES
userlist_file=/etc/vsftpd/allowed_users
userlist_deny=NO
chroot_local_user=YES
allow_writeable_chroot=YES
pasv_enable=YES
pasv_min_port=21000
pasv_max_port=21010
pasv_address=${SERVER_IP}
ftpd_banner=Welcome
max_clients=20
max_per_ip=5
xferlog_file=/var/log/vsftpd.log
ssl_enable=YES
allow_anon_ssl=NO
force_local_data_ssl=NO
force_local_logins_ssl=NO
ssl_tlsv1_2=YES
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH
rsa_cert_file=${PROJECT_DIR}/data/ssl/${DOMAIN}.fullchain.cert.pem
rsa_private_key_file=${PROJECT_DIR}/data/ssl/${DOMAIN}.key.pem
VSFTPD

# FTP user
if ! id "$FTP_USER" &>/dev/null; then
  useradd -d "$FTP_HOME" -M -s /sbin/nologin "$FTP_USER"
  info "FTP user $FTP_USER created ? set password: passwd $FTP_USER"
fi
echo "$FTP_USER" > /etc/vsftpd/allowed_users

# Ensure vsftpd.log exists (fail2ban needs it even before first connection)
touch /var/log/vsftpd.log

# ACL: ftpadmin can read/write /mnt/bitrix/www
setfacl -m "u:${FTP_USER}:rwx" "$FTP_HOME" 2>/dev/null || true
setfacl -d -m "u:${FTP_USER}:rwx" "$FTP_HOME" 2>/dev/null || true

# SELinux
setsebool -P ftpd_full_access on 2>/dev/null || true
semanage port -a -t ftp_port_t -p tcp 21000-21010 2>/dev/null || \
  semanage port -m -t ftp_port_t -p tcp 21000-21010 2>/dev/null || true

systemctl restart vsftpd
ok "vsftpd configured and running"

# =============================================================================
# 3. firewalld ? mgmt zone for trusted IPs, public zone locked down
# =============================================================================
step "3. Configuring firewalld"

systemctl enable --now firewalld

# Create mgmt zone
firewall-cmd --permanent --new-zone=mgmt 2>/dev/null || true

# Trusted IPs ? mgmt zone
for ip in "${TRUSTED_IPS[@]}"; do
  firewall-cmd --permanent --zone=mgmt --add-source="$ip" 2>/dev/null || true
done

# mgmt zone: allow SSH, FTP, passive FTP ports
firewall-cmd --permanent --zone=mgmt --add-service=ssh
firewall-cmd --permanent --zone=mgmt --add-service=ftp
firewall-cmd --permanent --zone=mgmt --add-service=cockpit
firewall-cmd --permanent --zone=mgmt --add-port=21000-21010/tcp

# public zone: remove SSH (only accessible from trusted IPs via mgmt)
firewall-cmd --permanent --zone=public --remove-service=ssh 2>/dev/null || true
firewall-cmd --permanent --zone=public --remove-service=cockpit 2>/dev/null || true
# HTTP/HTTPS handled by Docker (iptables-nft), not firewalld

firewall-cmd --reload
ok "firewalld configured: mgmt zone with ${#TRUSTED_IPS[@]} trusted IPs, public locked"

# =============================================================================
# 4. fail2ban ? 5 jails (sshd, vsftpd, nginx-bitrix-admin, nginx-probe, nginx-limit-req)
# =============================================================================
step "4. Configuring fail2ban"

# Custom action: block Docker HTTP traffic via DOCKER-USER chain
cat > /etc/fail2ban/action.d/iptables-docker-user.conf << 'F2B_ACTION'
[Definition]
actionstart = iptables -N f2b-docker-user 2>/dev/null || true
              iptables -C DOCKER-USER -j f2b-docker-user 2>/dev/null || iptables -I DOCKER-USER 1 -j f2b-docker-user

actionstop =  iptables -D DOCKER-USER -j f2b-docker-user 2>/dev/null || true
              iptables -F f2b-docker-user 2>/dev/null || true
              iptables -X f2b-docker-user 2>/dev/null || true

actioncheck = iptables -n -L DOCKER-USER 2>/dev/null | grep -q f2b-docker-user

actionban =   iptables -I f2b-docker-user 1 -s <ip> -j DROP

actionunban = iptables -D f2b-docker-user -s <ip> -j DROP
F2B_ACTION

# Filter: Bitrix admin brute-force
cat > /etc/fail2ban/filter.d/nginx-bitrix-admin.conf << 'F2B_FILTER_ADMIN'
[Definition]
failregex = ^<HOST> -[^"]*"POST /bitrix/admin/[^ ]* HTTP/[0-9.]+" (302|200|401)
            ^<HOST> -[^"]*"(GET|POST) /bitrix/admin/\?login=yes[^ ]* HTTP/[0-9.]+" (302|200|401)
ignoreregex =
F2B_FILTER_ADMIN

# Filter: vulnerability scanners / bots
cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'F2B_FILTER_PROBE'
[Definition]
failregex = ^<HOST> -[^"]*"(GET|POST|HEAD) /(wp-admin|wp-login|phpmyadmin|pma|admin|administrator|xmlrpc\.php|\.env|\.git|shell|backdoor|c99|r57|eval)[^ ]* HTTP/[0-9.]+" (200|404|403|400|500)
            ^<HOST> -[^"]*"(GET|POST) /[^ ]*\.(php|asp|aspx|jsp|cgi)[^ ]* HTTP/[0-9.]+" 404
            ^<HOST> -[^"]*"-" 400 \d+
ignoreregex = ^<HOST> -[^"]*"/bitrix/
F2B_FILTER_PROBE

# Build ignoreip list
IGNOREIP="127.0.0.1/8 ::1"
for ip in "${TRUSTED_IPS[@]}"; do IGNOREIP="$IGNOREIP $ip"; done

# Main jail config
cat > /etc/fail2ban/jail.d/bitrix-security.conf << F2B_JAIL
[DEFAULT]
ignoreip = ${IGNOREIP}
bantime  = 3600
findtime = 300
maxretry = 5

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/secure
maxretry = 3
bantime  = 86400
action   = firewallcmd-rich-rules

[vsftpd]
enabled  = true
port     = ftp,ftp-data,ftps,ftps-data,21000:21010
filter   = vsftpd
logpath  = /var/log/vsftpd.log
maxretry = 3
bantime  = 3600
action   = firewallcmd-rich-rules

[nginx-bitrix-admin]
enabled  = true
port     = http,https
filter   = nginx-bitrix-admin
logpath  = /mnt/bitrix/logs/nginx/access.log
maxretry = 10
findtime = 60
bantime  = 3600
action   = iptables-docker-user

[nginx-probe]
enabled  = true
port     = http,https
filter   = nginx-probe
logpath  = /mnt/bitrix/logs/nginx/access.log
maxretry = 5
findtime = 60
bantime  = 86400
action   = iptables-docker-user

[nginx-limit-req]
enabled  = true
port     = http,https
filter   = nginx-limit-req
logpath  = /mnt/bitrix/logs/nginx/access.log
maxretry = 3
bantime  = 600
action   = iptables-docker-user
F2B_JAIL

systemctl restart fail2ban
ok "fail2ban configured: 5 jails active"

# =============================================================================
# 5. /opt/bitrix/volumes/ symlinks ? project-local access to all LVM mounts
# =============================================================================
step "5. Creating volume symlinks"

mkdir -p "${PROJECT_DIR}/volumes"

declare -A SYMLINKS=(
  ["www"]="/mnt/bitrix/www"
  ["upload"]="/mnt/bitrix/upload"
  ["cache"]="/mnt/bitrix/cache"
  ["session"]="/mnt/bitrix/session"
  ["logs"]="/mnt/bitrix/logs"
  ["postfix"]="/var/spool/postfix"
  ["mysql"]="/var/lib/mysql"
  ["mysql-tmp"]="/var/lib/mysql/tmp"
  ["opensearch"]="/var/lib/opensearch"
  ["redis"]="/var/lib/redis"
  ["docker"]="/var/lib/docker"
  ["backup"]="/var/backup"
)

for name in "${!SYMLINKS[@]}"; do
  ln -sfn "${SYMLINKS[$name]}" "${PROJECT_DIR}/volumes/${name}"
done
ok "Symlinks created in ${PROJECT_DIR}/volumes/"

# =============================================================================
# 6. Upload directory ? migrate from www/upload/ to dedicated LV
# =============================================================================
step "6. Setting up upload directory"

SRC="$FTP_HOME/upload"
DST="/mnt/bitrix/upload"

if [[ -d "$SRC" ]] && [[ "$(ls -A "$SRC" 2>/dev/null)" ]]; then
  info "Migrating $SRC ? $DST ..."
  rsync -a --ignore-existing "$SRC/" "$DST/"
  ok "Upload data migrated"
else
  ok "Upload source empty ? nothing to migrate"
fi

# Fix ownership (UID 979 = bitrix user inside containers)
chown -R 979:979 "$DST"
restorecon -R "$DST" 2>/dev/null || true
ok "Upload dir ownership fixed (979:979)"

# =============================================================================
# 7. MySQL tmpdir ownership (NVMe LV for large sort operations)
# =============================================================================
step "7. MySQL tmpdir setup"
chown -R 979:979 /var/lib/mysql/tmp 2>/dev/null || true
restorecon -R /var/lib/mysql/tmp 2>/dev/null || true
ok "MySQL tmpdir /var/lib/mysql/tmp ready"

# =============================================================================
# 8. msmtp config for PHP/cron containers
# =============================================================================
step "8. msmtp relay config"

mkdir -p "${PROJECT_DIR}/data/msmtp"
cat > "${PROJECT_DIR}/data/msmtp/msmtprc" << 'MSMTP'
# msmtp config: relay through postfix container (no auth needed inside Docker network)
defaults
auth           off
tls            off
logfile        /tmp/msmtp.log

account        relay
host           postfix
port           25

account default : relay
MSMTP
ok "msmtp config written"

# =============================================================================
# 9. Build Postfix Docker image
# =============================================================================
step "9. Building Postfix Docker image"
cd "${PROJECT_DIR}"
docker build -t bitrix_postfix:latest ./confs/postfix/
ok "Postfix image built"

# =============================================================================
# 10. Docker stack up
# =============================================================================
step "10. Starting Docker stack"
cd "${PROJECT_DIR}"
docker compose up -d
ok "Docker stack started"

# =============================================================================
# 11. Verification
# =============================================================================
step "11. Verification"

sleep 15  # wait for containers to stabilize

FAILED=0

# Check all containers running
CONTAINERS=(bitrix_redis bitrix_mysql bitrix_opensearch bitrix_php bitrix_cron bitrix_nginx bitrix_push_sub bitrix_push_pub bitrix_postfix bitrix_ssl)
for c in "${CONTAINERS[@]}"; do
  STATUS=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
  if [[ "$STATUS" == "running" ]]; then
    ok "  $c: running"
  else
    warn "  $c: $STATUS"
    FAILED=$((FAILED+1))
  fi
done

# HTTP check
HTTP_CODE=$(curl -skI "https://${DOMAIN}/" | head -1 | awk '{print $2}')
if [[ "$HTTP_CODE" == "200" ]]; then
  ok "  Site https://${DOMAIN}/ ? HTTP $HTTP_CODE"
else
  warn "  Site https://${DOMAIN}/ ? HTTP $HTTP_CODE"
  FAILED=$((FAILED+1))
fi

# fail2ban
F2B_STATUS=$(fail2ban-client ping 2>/dev/null | grep -c "pong" || echo 0)
[[ "$F2B_STATUS" -gt 0 ]] && ok "  fail2ban: running" || warn "  fail2ban: not responding"

echo
if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}============================================${NC}"
  echo -e "${GREEN}  Deploy complete ? all checks passed!${NC}"
  echo -e "${GREEN}============================================${NC}"
else
  echo -e "${YELLOW}============================================${NC}"
  echo -e "${YELLOW}  Deploy done with $FAILED warning(s)${NC}"
  echo -e "${YELLOW}  Check logs: docker logs <container_name>${NC}"
  echo -e "${YELLOW}============================================${NC}"
fi

echo
echo "Useful commands:"
echo "  docker ps                                  ? container status"
echo "  docker logs bitrix_mysql                   ? MySQL logs"
echo "  fail2ban-client status                     ? active jails"
echo "  fail2ban-client status nginx-probe         ? banned IPs"
echo "  docker exec bitrix_redis redis-cli -n 1 DBSIZE  ? PHP sessions in Redis"
