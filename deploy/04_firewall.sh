#!/usr/bin/env bash
step "STEP 4/8 -- firewalld"

systemctl enable --now firewalld
firewall-cmd --permanent --new-zone=mgmt 2>/dev/null || true

for ip in $TRUSTED_IPS; do
  firewall-cmd --permanent --zone=mgmt --add-source="$ip" 2>/dev/null || true
done

firewall-cmd --permanent --zone=mgmt --add-service=ssh
firewall-cmd --permanent --zone=mgmt --add-service=ftp
firewall-cmd --permanent --zone=mgmt --add-service=cockpit
firewall-cmd --permanent --zone=mgmt --add-port=21000-21010/tcp

# Lock down public zone (HTTP/HTTPS handled by Docker iptables-nft)
firewall-cmd --permanent --zone=public --remove-service=ssh     2>/dev/null || true
firewall-cmd --permanent --zone=public --remove-service=cockpit 2>/dev/null || true

firewall-cmd --reload
ok "firewalld: mgmt zone with $(echo $TRUSTED_IPS | wc -w) trusted IPs, public locked"