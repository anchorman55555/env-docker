#!/usr/bin/env bash
# ==============================================================================
# 00_init.sh -- AlmaLinux 9: первоначальная настройка сервера
#
# Запускать ДО deploy.sh на свежеустановленной системе.
# Скрипт работает в двух фазах:
#   Фаза 1: DNF, EPEL, XCP-ng tools, полное обновление системы → перезагрузка
#   Фаза 2: установка пакетов, chrony, генерация SSH-ключей
#
# Использование:
#   bash 00_init.sh           — запустить (фаза 1 → автоперезагрузка → фаза 2)
#   bash 00_init.sh --phase2  — запустить только фазу 2 (вручную, если нужно)
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

PHASE_FLAG="/var/lib/.bitrix_init_phase1_done"
SCRIPT_ABS="$(readlink -f "$0")"
SERVICE_NAME="bitrix-init-phase2"

# ==============================================================================
# Определяем фазу
# ==============================================================================
PHASE=1
[[ "${1:-}" == "--phase2" ]] && PHASE=2
[[ -f "$PHASE_FLAG" && "$PHASE" -eq 1 ]] && PHASE=2

# ==============================================================================
# ФАЗА 1: DNF + EPEL + XCP-ng tools + обновление + перезагрузка
# ==============================================================================
phase1() {
    step "ФАЗА 1/2 — Первоначальная настройка и обновление системы"

    [[ $EUID -eq 0 ]] || fail "Запускать от root"

    # --- DNF: включить fastestmirror ------------------------------------------
    step "1.1 — Настройка DNF"
    dnf install -y dnf-plugins-core
    dnf config-manager --setopt=fastestmirror=1 --save
    dnf config-manager --setopt=max_parallel_downloads=10 --save
    ok "DNF настроен (fastestmirror, parallel downloads)"

    # --- EPEL -----------------------------------------------------------------
    step "1.2 — EPEL репозиторий"
    dnf install -y epel-release
    dnf config-manager --set-enabled epel
    ok "EPEL установлен"

    # --- XCP-ng guest tools ---------------------------------------------------
    step "1.3 — XCP-ng / Citrix guest tools"
    if dnf list available xe-guest-utilities-latest &>/dev/null; then
        dnf install -y xe-guest-utilities-latest
        systemctl enable --now xe-linux-distribution.service
        ok "XCP-ng guest tools установлены и запущены"
    else
        warn "xe-guest-utilities-latest не найден в репозиториях"
        warn "Если сервер на XCP-ng/XenServer — добавьте репозиторий xe-guest-utilities вручную:"
        warn "  dnf install -y https://kojipkgs.fedoraproject.org/.../xe-guest-utilities-latest.rpm"
        warn "Пропускаем (не критично для работы стека)"
    fi

    # --- Полное обновление системы -------------------------------------------
    step "1.4 — Обновление системы (dnf update + upgrade)"
    dnf update -y
    dnf upgrade --refresh -y
    ok "Система обновлена"

    # --- Регистрируем фазу 2 через systemd oneshot ----------------------------
    step "1.5 — Регистрация автозапуска фазы 2 после перезагрузки"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Bitrix Init Phase 2 (packages, chrony, SSH keys)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!${PHASE_FLAG}.p2done

[Service]
Type=oneshot
ExecStart=/usr/bin/bash ${SCRIPT_ABS} --phase2
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    touch "$PHASE_FLAG"
    ok "Служба ${SERVICE_NAME} зарегистрирована"

    echo
    echo -e "${YELLOW}================================================================${NC}"
    echo -e "${YELLOW}  Система перезагрузится через 5 секунд для применения обновлений${NC}"
    echo -e "${YELLOW}  Фаза 2 (установка пакетов, SSH-ключи) запустится автоматически${NC}"
    echo -e "${YELLOW}  Следите за выводом: journalctl -fu ${SERVICE_NAME}${NC}"
    echo -e "${YELLOW}================================================================${NC}"
    sleep 5
    systemctl --no-wall reboot
}

# ==============================================================================
# ФАЗА 2: пакеты + chrony + SSH-ключи (запускается после перезагрузки)
# ==============================================================================
phase2() {
    step "ФАЗА 2/2 — Установка пакетов, chrony, SSH-ключи"

    # --- Базовые и полезные пакеты -------------------------------------------
    step "2.1 — Установка пакетов"

    BASE_PKGS=(
        # Файловые менеджеры и редакторы
        mc nano vim-enhanced

        # Сетевые инструменты
        wget curl bind-utils net-tools tcpdump iftop nethogs nmap telnet

        # Git и работа с архивами
        git rsync tar gzip bzip2 xz unzip zip

        # Система и мониторинг
        htop iotop atop sysstat dstat ncdu lsof strace

        # Bash и автодополнение
        bash-completion screen tmux

        # Python и скрипты
        python3 python3-pip jq

        # LVM и файловые системы
        lvm2 xfsprogs e2fsprogs parted gdisk

        # SELinux
        policycoreutils-python-utils setroubleshoot-server audit

        # Chrony (NTP)
        chrony

        # ACL, прочее
        acl attr psmisc tree file

        # Производительность
        tuned numactl

        # Сборочные инструменты (нужны для некоторых pip-пакетов)
        gcc make
    )

    dnf install -y "${BASE_PKGS[@]}"
    ok "Пакеты установлены"

    # --- Chrony / NTP ---------------------------------------------------------
    step "2.2 — Настройка Chrony (NTP синхронизация)"
    systemctl enable --now chronyd
    chronyc makestep 2>/dev/null || true
    ok "Chrony запущен"
    chronyc tracking | grep -E "System time|Reference ID|Stratum" || true

    # --- Tuned: профиль производительности ------------------------------------
    step "2.3 — Tuned профиль"
    systemctl enable --now tuned
    tuned-adm profile throughput-performance
    ok "Tuned: профиль throughput-performance активирован"

    # --- Генерация SSH-ключей -------------------------------------------------
    step "2.4 — Генерация SSH-ключей для беспарольного доступа"
    generate_ssh_keys

    # --- Завершение -----------------------------------------------------------
    touch "${PHASE_FLAG}.p2done"
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ИНИЦИАЛИЗАЦИЯ СЕРВЕРА ЗАВЕРШЕНА                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "  Следующий шаг: запустить ${CYAN}deploy.sh${NC}"
    echo -e "    cd /opt/bitrix && bash deploy.sh"
    echo
}

# ==============================================================================
# Генерация SSH-ключей и инструкция для PuTTY
# ==============================================================================
generate_ssh_keys() {
    local SSH_DIR="/root/.ssh"
    local KEY_FILE="${SSH_DIR}/id_ed25519"
    local KEY_COMMENT="root@$(hostname -f 2>/dev/null || hostname)"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    if [[ -f "$KEY_FILE" ]]; then
        warn "Ключ ${KEY_FILE} уже существует — пропускаем генерацию"
    else
        ssh-keygen -t ed25519 -C "$KEY_COMMENT" -f "$KEY_FILE" -N ""
        ok "SSH ключ ed25519 сгенерирован: ${KEY_FILE}"
    fi

    # Добавляем публичный ключ в authorized_keys
    local PUB_KEY
    PUB_KEY=$(cat "${KEY_FILE}.pub")
    if ! grep -qF "$PUB_KEY" "${SSH_DIR}/authorized_keys" 2>/dev/null; then
        echo "$PUB_KEY" >> "${SSH_DIR}/authorized_keys"
        chmod 600 "${SSH_DIR}/authorized_keys"
        ok "Публичный ключ добавлен в authorized_keys"
    fi

    # --- Вывод приватного ключа и инструкции ----------------------------------
    local PRIV_KEY
    PRIV_KEY=$(cat "$KEY_FILE")
    local SERVER_IP
    SERVER_IP=$(hostname -I | awk '{print $1}')

    echo
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  SSH ПРИВАТНЫЙ КЛЮЧ — СОХРАНИТЕ В БЕЗОПАСНОЕ МЕСТО!                 ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  Скопируйте ВСЁ между линиями (включая BEGIN/END строки)            ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo "$PRIV_KEY"
    echo
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${CYAN}=== ИНСТРУКЦИЯ: Беспарольный вход через PuTTY (Windows) ===${NC}"
    echo
    echo -e "${GREEN}Вариант A — PuTTY 0.75+ (рекомендуется, поддерживает OpenSSH напрямую):${NC}"
    echo
    echo "  1. Сохраните ключ выше в файл: C:\\Users\\ВАШ_ПОЛЬЗОВАТЕЛЬ\\.ssh\\id_ed25519"
    echo "     (создайте папку .ssh если не существует)"
    echo
    echo "  2. Откройте PuTTY:"
    echo "     Session → Host Name: ${SERVER_IP}"
    echo "     Connection → SSH → Auth → Credentials:"
    echo "       'Private key file for authentication' → Browse → выберите id_ed25519"
    echo
    echo "  3. Session → Saved Sessions: введите имя → Save"
    echo
    echo "  4. Open → вход без пароля как root"
    echo
    echo -e "${GREEN}Вариант B — PuTTYgen (конвертация в .ppk формат):${NC}"
    echo
    echo "  1. Сохраните ключ выше в файл id_ed25519 (без расширения)"
    echo
    echo "  2. Откройте PuTTYgen:"
    echo "     Conversions → Import key → выберите id_ed25519"
    echo "     File → Save private key → сохраните как server.ppk"
    echo "     (на вопрос о парольной фразе — можно нажать Yes для беспарольного)"
    echo
    echo "  3. Откройте PuTTY:"
    echo "     Session → Host Name: ${SERVER_IP}  Port: 22"
    echo "     Connection → SSH → Auth → Credentials:"
    echo "       'Private key file' → Browse → выберите server.ppk"
    echo "     Session → Saved Sessions: введите имя → Save"
    echo
    echo "  4. Open → вход без пароля как root"
    echo
    echo -e "${GREEN}Вариант C — Windows Terminal / PowerShell (встроенный OpenSSH):${NC}"
    echo
    echo "  1. Сохраните ключ в: C:\\Users\\ВАШ_ПОЛЬЗОВАТЕЛЬ\\.ssh\\id_ed25519"
    echo
    echo "  2. В PowerShell:"
    echo "     icacls \"\$env:USERPROFILE\\.ssh\\id_ed25519\" /inheritance:r /grant:r \"\${env:USERNAME}:R\""
    echo
    echo "  3. Подключение:"
    echo "     ssh root@${SERVER_IP}"
    echo
    echo -e "${GREEN}Добавить в ~/.ssh/config (Windows: C:\\Users\\ВАШ_ПОЛЬЗОВАТЕЛЬ\\.ssh\\config):${NC}"
    echo
    echo "  Host bitrix-server"
    echo "      HostName ${SERVER_IP}"
    echo "      User root"
    echo "      IdentityFile ~/.ssh/id_ed25519"
    echo "      ServerAliveInterval 60"
    echo
    echo "  Затем: ssh bitrix-server"
    echo
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${CYAN}Публичный ключ сервера (уже в authorized_keys):${NC}"
    cat "${KEY_FILE}.pub"
    echo
}

# ==============================================================================
# Точка входа
# ==============================================================================
if [[ $PHASE -eq 1 ]]; then
    phase1
else
    phase2
fi
