#!/usr/bin/env bash
step "STEP 2/8 -- System packages + sysctl"

# Docker CE
if ! command -v docker &>/dev/null; then
  ok "Installing Docker CE..."
  dnf install -y dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  ok "Docker CE installed"
else
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ',') already installed"
fi

dnf install -y vsftpd fail2ban fail2ban-firewalld msmtp acl policycoreutils-python-utils
systemctl enable vsftpd fail2ban
ok "vsftpd, fail2ban, msmtp, acl installed"

# OpenSearch requires vm.max_map_count >= 262144
cat > /etc/sysctl.d/99-opensearch.conf << 'EOF'
vm.max_map_count=262144
EOF
sysctl -p /etc/sysctl.d/99-opensearch.conf >/dev/null
ok "sysctl: vm.max_map_count=262144"