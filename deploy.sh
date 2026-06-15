#!/usr/bin/env bash
# ==============================================================================
# Bitrix24 Docker Stack -- Full Deploy Script
# Server: crm.cifroweek.com | AlmaLinux 9.x | 64 GB RAM | 30-core Xeon 8592+
# ==============================================================================
set -euo pipefail

export RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' CYAN='\033[0;36m' NC='\033[0m'
ok()   { echo -e "${GREEN}  [OK]${NC} $*"; }
warn() { echo -e "${YELLOW}  [!!]${NC} $*"; }
fail() { echo -e "${RED}  [FAIL]${NC} $*"; exit 1; }
step() { echo; echo -e "${BLUE}================================================================${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}================================================================${NC}"; }
export -f ok warn fail step

export SERVER_IP="${SERVER_IP:-91.239.143.137}"
export DOMAIN="${DOMAIN:-crm.cifroweek.com}"
export PROJECT_DIR="${PROJECT_DIR:-/opt/bitrix}"
export FTP_USER="${FTP_USER:-ftpadmin}"
export FTP_HOME="/mnt/bitrix/www"
export TRUSTED_IPS="195.54.32.168 37.28.181.201 77.37.135.235 82.149.208.58 91.239.143.134 91.239.143.135 91.239.143.136 91.239.143.137 91.239.143.138 91.239.143.139 82.149.214.118 192.168.1.0/24 192.168.10.0/24 172.16.10.0/24 107.173.149.222 88.84.205.109 92.50.195.50 83.219.151.30"

D="${PROJECT_DIR}/deploy"

bash "$D/01_preflight.sh"
bash "$D/02_packages.sh"
bash "$D/03_vsftpd.sh"
bash "$D/04_firewall.sh"
bash "$D/05_fail2ban.sh"
bash "$D/06_volumes.sh"
bash "$D/07_docker.sh"
bash "$D/08_verify.sh"
bash "$D/09_bitrix_config.sh"
bash "$D/10_summary.sh"
