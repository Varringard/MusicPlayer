#!/usr/bin/env bash
# ==============================================================================
#  🎵 MusicPlayer — Proxmox VE Helper Script (LXC Creator)
# ==============================================================================
#  Запускается прямо в Shell ноды Proxmox VE.
#  Автоматически создает LXC-контейнер Debian 12 и разворачивает MusicPlayer.
# ==============================================================================

set -e

# Цвета для красивого вывода в стиле Proxmox Helper Scripts
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "=================================================================="
echo "      🎵  MusicPlayer — Proxmox VE LXC Helper Script              "
echo "=================================================================="
echo -e "${NC}"

# 1. Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ОШИБКА] Этот скрипт должен быть запущен от root на хосте Proxmox VE!${NC}"
    exit 1
fi

# 2. Проверка, что скрипт запущен на хосте Proxmox VE
if ! command -v pveversion >/dev/null 2>&1; then
    echo -e "${RED}[ОШИБКА] Команда pveversion не найдена!${NC}"
    echo -e "Этот скрипт предназначен для запуска ${BOLD}на хосте Proxmox VE${NC} (в Shell ноды)."
    echo -e "Если вы уже находитесь внутри контейнера, используйте:"
    echo -e "  ${CYAN}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Varringard/MusicPlayer/main/install.sh)\"${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Обнаружен Proxmox VE: $(pveversion)${NC}\n"

# Функция для ввода с дефолтным значением
prompt_val() {
    local prompt_text="$1"
    local var_name="$2"
    local def_val="$3"
    local input_val=""

    if [ -t 0 ]; then
        read -rp "$(echo -e "${prompt_text} [${BOLD}${def_val}${NC}]: ")" input_val
    elif [ -e /dev/tty ]; then
        read -rp "$(echo -e "${prompt_text} [${BOLD}${def_val}${NC}]: ")" input_val < /dev/tty
    else
        read -rp "$prompt_text [$def_val]: " input_val
    fi

    input_val="${input_val:-$def_val}"
    eval "$var_name=\"\$input_val\""
}

# 3. Автоопределение настроек PVE
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "105")

# Определение хранилища для шаблонов
TMPL_STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')
TMPL_STORAGE=${TMPL_STORAGE:-local}

# Определение хранилища для дисков контейнеров
ROOT_STORAGE=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')
ROOT_STORAGE=${ROOT_STORAGE:-local-lvm}

echo -e "${BLUE}=== 1. Параметры контейнера LXC ===${NC}"
prompt_val "ID нового контейнера (CTID)" CTID "$NEXT_ID"

# Проверка, не занят ли ID
if pct status "$CTID" >/dev/null 2>&1; then
    echo -e "${RED}[ОШИБКА] Контейнер с ID $CTID уже существует! Выберите другой ID.${NC}"
    exit 1
fi

prompt_val "Имя хоста (Hostname)" CT_HOSTNAME "musicplayer"
prompt_val "Хранилище диска (Storage)" STORAGE "$ROOT_STORAGE"
prompt_val "Размер диска в GB" DISK_SIZE "4"
prompt_val "Оперативная память в MB" RAM_SIZE "1024"
prompt_val "Количество ядер CPU" CPU_CORES "1"
prompt_val "Сетевой мост (Bridge)" NET_BRIDGE "vmbr0"
prompt_val "IP адрес (dhcp или IP/маска, например 192.168.1.50/24)" NET_IP "dhcp"

NET_GW=""
if [ "$NET_IP" != "dhcp" ]; then
    prompt_val "Шлюз (Gateway)" NET_GW ""
fi

echo ""
echo -e "${BLUE}=== 2. Настройки домена и MusicPlayer ===${NC}"
DOMAIN=""
while [ -z "$DOMAIN" ]; do
    prompt_val "Ваш домен для стрима (например: music.example.com или duckdns)" DOMAIN ""
    DOMAIN=$(echo "$DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Домен обязателен для настройки SSL и работы плеера!${NC}"
    fi
done

prompt_val "Email для Let's Encrypt сертификата" EMAIL "admin@$DOMAIN"
DEFAULT_KEY=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)
prompt_val "Пароль стримера для панели" STREAMER_KEY "$DEFAULT_KEY"

echo ""
echo -e "${MAGENTA}------------------------------------------------------------------"
echo -e "Будет создан контейнер LXC со следующими параметрами:"
echo -e " • CT ID:     ${BOLD}$CTID${NC} ($CT_HOSTNAME)"
echo -e " • Ресурсы:   ${BOLD}${RAM_SIZE}MB RAM / ${CPU_CORES} CPU / ${DISK_SIZE}GB Диск (${STORAGE})${NC}"
echo -e " • Сеть:      ${BOLD}$NET_BRIDGE ($NET_IP)${NC}"
echo -e " • Домен:     ${BOLD}$DOMAIN${NC}"
echo -e " • Email:     ${BOLD}$EMAIL${NC}"
echo -e " • Пароль:    ${YELLOW}$STREAMER_KEY${NC}"
echo -e "------------------------------------------------------------------${NC}\n"

prompt_val "Начать создание и установку? (y/n)" CONFIRM "y"
if [[ ! "$CONFIRM" =~ ^[YyДд]$ ]]; then
    echo -e "${YELLOW}Установка отменена пользователем.${NC}"
    exit 0
fi

# 4. Поиск и загрузка шаблона Debian 12
echo ""
echo -e "${BLUE}[1/4] Подготовка шаблона ОС (Debian 12)...${NC}"
pveam update >/dev/null 2>&1 || true

DEBIAN_TMPL=$(pveam available -section system 2>/dev/null | grep -E 'debian-12-standard.*amd64' | tail -1 | awk '{print $2}')
if [ -z "$DEBIAN_TMPL" ]; then
    DEBIAN_TMPL="debian-12-standard_12.7-1_amd64.tar.zst"
fi

if ! pvesm list "$TMPL_STORAGE" 2>/dev/null | grep -q "$DEBIAN_TMPL"; then
    echo -e "Загрузка шаблона ${YELLOW}$DEBIAN_TMPL${NC} в ${TMPL_STORAGE}..."
    pveam download "$TMPL_STORAGE" "$DEBIAN_TMPL"
else
    echo -e "${GREEN}✓ Шаблон $DEBIAN_TMPL уже доступен в $TMPL_STORAGE.${NC}"
fi

TEMPLATE_PATH="${TMPL_STORAGE}:vztmpl/${DEBIAN_TMPL}"

# 5. Создание контейнера
echo ""
echo -e "${BLUE}[2/4] Создание непривилегированного LXC контейнера (CT $CTID)...${NC}"

NET_CONFIG="name=eth0,bridge=$NET_BRIDGE,ip=$NET_IP"
if [ -n "$NET_GW" ]; then
    NET_CONFIG="${NET_CONFIG},gw=$NET_GW"
fi

pct create "$CTID" "$TEMPLATE_PATH" \
    --ostype debian \
    --hostname "$CT_HOSTNAME" \
    --cores "$CPU_CORES" \
    --memory "$RAM_SIZE" \
    --swap 512 \
    --features nesting=1 \
    --unprivileged 1 \
    --net0 "$NET_CONFIG" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --onboot 1 \
    --description "MusicPlayer Stream Server (https://${DOMAIN})" \
    --start 0

echo -e "${GREEN}✓ Контейнер $CTID успешно создан.${NC}"

# 6. Запуск контейнера
echo ""
echo -e "${BLUE}[3/4] Запуск контейнера $CTID...${NC}"
pct start "$CTID"

echo -e "Ожидание инициализации сети и готовности контейнера..."
RETRIES=0
while [ $RETRIES -lt 25 ]; do
    if pct exec "$CTID" -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Сеть внутри контейнера активна!${NC}"
        break
    fi
    sleep 2
    RETRIES=$((RETRIES+1))
done

if [ $RETRIES -ge 25 ]; then
    echo -e "${YELLOW}⚠️ Предупреждение: Проверка ping не прошла. Продолжаем установку...${NC}"
fi

# Получаем назначенный IP
CONTAINER_IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "DHCP")

# 7. Выполнение установки MusicPlayer внутри контейнера
echo ""
echo -e "${BLUE}[4/4] Развертывание MusicPlayer и настройка SSL внутри контейнера...${NC}"

pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get update -q -y && apt-get install -q -y curl ca-certificates"

INSTALL_CMD="bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Varringard/MusicPlayer/main/install.sh)\" -- -d '$DOMAIN' -e '$EMAIL' -k '$STREAMER_KEY' -y"
pct exec "$CTID" -- bash -c "$INSTALL_CMD"

# 8. Финал
WIDGET_KEY=$(pct exec "$CTID" -- grep -o '"widgetKey": "[^"]*' /opt/musicplayer/config.json 2>/dev/null | cut -d'"' -f4 || echo "")

echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "        🎉 КОНТЕЙНЕР PROXMOX И MUSICPLAYER ГОТОВЫ!                "
echo "==================================================================${NC}"
echo -e "📦 ${BOLD}CT ID:${NC}                  ${CYAN}$CTID ($CT_HOSTNAME)${NC}"
echo -e "🔌 ${BOLD}Внутренний IP контейнера:${NC} ${CYAN}$CONTAINER_IP${NC}"
echo -e "🌐 ${BOLD}Главная страница:${NC}        https://${DOMAIN}/"
echo -e "🎵 ${BOLD}Заказ треков (зрители):${NC}   https://${DOMAIN}/order-music"
echo -e "🎛 ${BOLD}Панель стримера:${NC}         https://${DOMAIN}/music-panel"
echo -e "🔑 ${BOLD}Пароль стримера:${NC}         ${YELLOW}${STREAMER_KEY}${NC}"
echo -e "📺 ${BOLD}Виджет для OBS Studio:${NC}   https://${DOMAIN}/widget?key=${WIDGET_KEY}"
echo ""
echo -e "${BOLD}Полезные команды на хосте Proxmox:${NC}"
echo -e " • Панель управления (TUI):   ${YELLOW}${BOLD}pct enter $CTID${NC} и затем ${YELLOW}${BOLD}msui${NC}"
echo -e " • Вход в консоль контейнера: ${CYAN}pct enter $CTID${NC}"
echo -e " • Остановка контейнера:      ${CYAN}pct stop $CTID${NC}"
echo -e " • Запуск контейнера:         ${CYAN}pct start $CTID${NC}"
echo -e " • Перезапуск контейнера:     ${CYAN}pct reboot $CTID${NC}"
echo ""
echo -e "${YELLOW}ВАЖНО:${NC} Не забудьте пробросить порты 80 и 443 на вашем роутере на IP контейнера: ${BOLD}${CONTAINER_IP}${NC}"
echo -e "${GREEN}==================================================================${NC}"
