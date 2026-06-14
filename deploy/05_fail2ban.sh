#!/usr/bin/env bash
step "STEP 5/8 -- fail2ban (5 jails)"

cat > /etc/fail2ban/action.d/iptables-docker-user.conf << 'EOF'
[Definition]
actionstart = iptables -N f2b-docker-user 2>/dev/null || true
              iptables -C DOCKER-USER -j f2b-docker-user 2>/dev/null || iptables -I DOCKER-USER 1 -j f2b-docker-user
actionstop  = iptables -D DOCKER-USER -j f2b-docker-user 2>/dev/null || true
              iptables -F f2b-docker-user 2>/dev/null || true
              iptables -X f2b-docker-user 2>/dev/null || true
actioncheck = iptables -n -L DOCKER-USER 2>/dev/null | grep -q f2b-docker-user
actionban   = iptables -I f2b-docker-user 1 -s <ip> -j DROP
actionunban = iptables -D f2b-docker-user -s <ip> -j DROP
EOF

cat > /etc/fail2ban/filter.d/nginx-bitrix-admin.conf << 'EOF'
[Definition]
failregex = ^<HOST> -[^"]*"POST /bitrix/admin/[^ ]* HTTP/[0-9.]+" (302|200|401)
            ^<HOST> -[^"]*"(GET|POST) /bitrix/admin/\?login=yes[^ ]* HTTP/[0-9.]+" (302|200|401)
ignoreregex =
EOF

cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'EOF'
[Definition]
failregex = ^<HOST> -[^"]*"(GET|POST|HEAD) /(wp-admin|wp-login|phpmyadmin|pma|admin|administrator|xmlrpc\.php|\.env|\.git|shell|backdoor|c99|r57|eval)[^ ]* HTTP/[0-9.]+" (200|404|403|400|500)
            ^<HOST> -[^"]*"(GET|POST) /[^ ]*\.(php|asp|aspx|jsp|cgi)[^ ]* HTTP/[0-9.]+" 404
            ^<HOST> -[^"]*"-" 400 \d+
ignoreregex = ^<HOST> -[^"]*"/bitrix/
EOF

IGNOREIP="127.0.0.1/8 ::1 $TRUSTED_IPS"

cat > /etc/fail2ban/jail.d/bitrix-security.conf << EOF
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
EOF

systemctl restart fail2ban
ok "fail2ban: 5 jails active"