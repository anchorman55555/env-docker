#!/usr/bin/env bash
step "STEP 3/8 -- vsftpd (FTPS)"

cat > /etc/vsftpd/vsftpd.conf << EOF
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
EOF

id "$FTP_USER" &>/dev/null || { useradd -d "$FTP_HOME" -M -s /sbin/nologin "$FTP_USER"; warn "FTP user created -- run: passwd $FTP_USER"; }
echo "$FTP_USER" > /etc/vsftpd/allowed_users
touch /var/log/vsftpd.log
setfacl -m  "u:${FTP_USER}:rwx" "$FTP_HOME" 2>/dev/null || true
setfacl -d -m "u:${FTP_USER}:rwx" "$FTP_HOME" 2>/dev/null || true
setsebool -P ftpd_full_access on 2>/dev/null || true
semanage port -a -t ftp_port_t -p tcp 21000-21010 2>/dev/null || semanage port -m -t ftp_port_t -p tcp 21000-21010 2>/dev/null || true
systemctl restart vsftpd
ok "vsftpd running (FTPS + passive 21000-21010)"