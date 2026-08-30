#!/usr/bin/env bash
# ==============================================================================
#  🎵 MusicPlayer LXC / Linux Auto-Installer & SSL Setup Script
# ==============================================================================
#  Этот скрипт устанавливает MusicPlayer в LXC-контейнер (Debian / Ubuntu),
#  настраивает Nginx Reverse Proxy, выпускает SSL-сертификат Let's Encrypt
#  и запускает приложение как системную службу systemd.
# ==============================================================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

APP_DIR="/opt/musicplayer"
SERVICE_NAME="musicplayer"
PORT=3000

echo -e "${CYAN}${BOLD}"
echo "=================================================================="
echo "      🎵  MusicPlayer: Установка в LXC & Автоматический SSL        "
echo "=================================================================="
echo -e "${NC}"

# 1. Проверка прав суперпользователя (root)
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ОШИБКА] Этот скрипт должен быть запущен с правами root!${NC}"
    echo -e "Используйте: ${YELLOW}sudo bash $0${NC} или переключитесь на root."
    exit 1
fi

# 2. Обработка аргументов командной строки
DOMAIN=""
EMAIL=""
STREAMER_KEY=""
NON_INTERACTIVE=false

print_help() {
    echo "Использование: bash install.sh [ОПЦИИ]"
    echo ""
    echo "Опции:"
    echo "  -d, --domain <домен>     Доменное имя (например, music.example.com)"
    echo "  -e, --email <email>      Email для Let's Encrypt уведомлений"
    echo "  -k, --key <пароль>       Пароль стримера (по умолчанию: admin123 или текущий)"
    echo "  -y, --yes                Неинтерактивный режим (не задавать вопросы)"
    echo "  -h, --help               Показать это справочное сообщение"
    echo ""
    exit 0
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--domain) DOMAIN="$2"; shift ;;
        -e|--email) EMAIL="$2"; shift ;;
        -k|--key) STREAMER_KEY="$2"; shift ;;
        -y|--yes) NON_INTERACTIVE=true ;;
        -h|--help) print_help ;;
        *) echo -e "${RED}Неизвестный параметр: $1${NC}"; print_help ;;
    esac
    shift
done

# 3. Интерактивный ввод при отсутствии параметров
if [ -z "$DOMAIN" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        echo -e "${RED}[ОШИБКА] Домен (-d / --domain) обязателен в неинтерактивном режиме.${NC}"
        exit 1
    fi
    echo -e "${YELLOW}Введите ваше доменное имя (например: stream.mydomain.ru или myname.duckdns.org):${NC}"
    read -rp "Домен: " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
fi

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[ОШИБКА] Доменное имя не может быть пустым!${NC}"
    exit 1
fi

if [ -z "$EMAIL" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        EMAIL="admin@$DOMAIN"
    else
        echo -e "${YELLOW}Введите ваш email для Let's Encrypt (для уведомлений об истечении сертификата):${NC}"
        read -rp "Email (или нажмите Enter для admin@$DOMAIN): " EMAIL
        if [ -z "$EMAIL" ]; then
            EMAIL="admin@$DOMAIN"
        fi
    fi
fi

echo ""
echo -e "${BLUE}[1/7] Проверка системных пакетов и обновление...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q -y
apt-get install -q -y curl wget git nginx certbot python3-certbot-nginx python3 python3-pip ca-certificates gnupg dnsutils rsync

# 4. Проверка и установка Node.js (LTS 20.x)
echo ""
echo -e "${BLUE}[2/7] Проверка Node.js...${NC}"
NEED_NODE_INSTALL=true
if command -v node >/dev/null 2>&1; then
    NODE_VER=$(node -v | cut -d 'v' -f 2 | cut -d '.' -f 1)
    if [ "$NODE_VER" -ge 18 ]; then
        echo -e "${GREEN}✓ Node.js $(node -v) уже установлен.${NC}"
        NEED_NODE_INSTALL=false
    fi
fi

if [ "$NEED_NODE_INSTALL" = true ]; then
    echo -e "${YELLOW}Установка Node.js 20 LTS (NodeSource)...${NC}"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
    apt-get update -q -y
    apt-get install -q -y nodejs
    echo -e "${GREEN}✓ Node.js $(node -v) и npm $(npm -v) успешно установлены.${NC}"
fi

# 5. Установка свежей версии yt-dlp
echo ""
echo -e "${BLUE}[3/7] Установка утилиты yt-dlp (для резервного аудиопотока)...${NC}"
if ! command -v yt-dlp >/dev/null 2>&1; then
    curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
    chmod a+rx /usr/local/bin/yt-dlp
fi
echo -e "${GREEN}✓ yt-dlp доступен в /usr/local/bin/yt-dlp.${NC}"

# 6. Копирование и развертывание проекта в /opt/musicplayer
echo ""
echo -e "${BLUE}[4/7] Подготовка файлов приложения в $APP_DIR...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$APP_DIR"

if [ "$SCRIPT_DIR" != "$APP_DIR" ]; then
    echo -e "Копирование файлов из $SCRIPT_DIR в $APP_DIR..."
    rsync -av --exclude='node_modules' --exclude='.git' --exclude='ssl' --exclude='cache' "$SCRIPT_DIR/" "$APP_DIR/"
fi

cd "$APP_DIR"

# Установка npm зависимостей
echo -e "Установка npm зависимостей..."
npm install --omit=dev --no-audit --no-fund

# Настройка config.json
CONFIG_FILE="$APP_DIR/config.json"
CURRENT_STREAMER_KEY=""
CURRENT_WIDGET_KEY=""

if [ -f "$CONFIG_FILE" ]; then
    CURRENT_STREAMER_KEY=$(grep -o '"streamerKey": "[^"]*' "$CONFIG_FILE" | cut -d'"' -f4 || echo "")
    CURRENT_WIDGET_KEY=$(grep -o '"widgetKey": "[^"]*' "$CONFIG_FILE" | cut -d'"' -f4 || echo "")
fi

FINAL_STREAMER_KEY="${STREAMER_KEY:-${CURRENT_STREAMER_KEY:-admin123}}"
FINAL_WIDGET_KEY="${CURRENT_WIDGET_KEY:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)}"

cat <<EOF > "$CONFIG_FILE"
{
  "domain": "$DOMAIN",
  "streamerKey": "$FINAL_STREAMER_KEY",
  "widgetKey": "$FINAL_WIDGET_KEY"
}
EOF
chmod 600 "$CONFIG_FILE"

# 7. Конфигурация Nginx
echo ""
echo -e "${BLUE}[5/7] Настройка веб-сервера Nginx...${NC}"
NGINX_CONF="/etc/nginx/sites-available/musicplayer.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/musicplayer.conf"

cat <<EOF > "$NGINX_CONF"
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    client_max_body_size 25M;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;

        # WebSockets (Socket.IO) support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # Client and Host headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Timeouts for real-time sockets
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        # Disable buffering for live events
        proxy_buffering off;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# Удаляем default конфиг если он есть
if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
fi

ln -sf "$NGINX_CONF" "$NGINX_ENABLED"

nginx -t
systemctl reload nginx || systemctl restart nginx
echo -e "${GREEN}✓ Конфигурация Nginx успешно применена.${NC}"

# 8. Выпуск SSL через Certbot
echo ""
echo -e "${BLUE}[6/7] Выпуск SSL-сертификата Let's Encrypt для $DOMAIN...${NC}"
echo -e "${YELLOW}Попытка получения сертификата через Certbot...${NC}"

SSL_SUCCESS=false
if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect; then
    echo -e "${GREEN}✓ SSL сертификат успешно получен и настроен! Автопродление активировано.${NC}"
    SSL_SUCCESS=true
else
    echo -e "${RED}⚠️  Внимание: Certbot не смог автоматически выпустить сертификат.${NC}"
    echo -e "${YELLOW}Возможные причины:${NC}"
    echo -e " 1. Домен ${BOLD}$DOMAIN${NC}${YELLOW} ещё не указывает на публичный IP этого сервера.${NC}"
    echo -e " 2. Порты 80 (HTTP) и 443 (HTTPS) закрыты провайдером или роутером.${NC}"
    echo -e "${CYAN}Сервер продолжит работу по протоколу HTTP (http://$DOMAIN).${NC}"
    echo -e "${CYAN}После настройки DNS/портов вы сможете выпустить сертификат командой:${NC}"
    echo -e "  ${BOLD}certbot --nginx -d $DOMAIN${NC}"
fi

# 9. Настройка службы systemd
echo ""
echo -e "${BLUE}[7/7] Настройка службы systemd ($SERVICE_NAME)...${NC}"
NODE_BIN=$(which node)
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Stream Music Player Server
After=network.target nginx.service

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$NODE_BIN server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=NODE_ENV=production
Environment=PORT=$PORT
Environment=DOMAIN=$DOMAIN

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 2

# Проверка статуса
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "${GREEN}✓ Служба $SERVICE_NAME успешно запущена!${NC}"
else
    echo -e "${RED}⚠️  Ошибка: служба $SERVICE_NAME не запустилась. Проверьте логи: journalctl -u $SERVICE_NAME -n 50${NC}"
fi

# Итоговый вывод
PROTO="http"
if [ "$SSL_SUCCESS" = true ]; then
    PROTO="https"
fi

echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "            🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                        "
echo "==================================================================${NC}"
echo ""
echo -e "🌐 ${BOLD}Главная страница:${NC}      ${PROTO}://${DOMAIN}/"
echo -e "🎵 ${BOLD}Заказ треков (зрители):${NC} ${PROTO}://${DOMAIN}/order-music"
echo -e "🎛 ${BOLD}Панель стримера:${NC}       ${PROTO}://${DOMAIN}/music-panel"
echo -e "🔑 ${BOLD}Пароль стримера:${NC}       ${YELLOW}${FINAL_STREAMER_KEY}${NC}"
echo -e "📺 ${BOLD}Виджет для OBS Studio:${NC} ${PROTO}://${DOMAIN}/widget?key=${FINAL_WIDGET_KEY}"
echo ""
echo -e "${BOLD}Полезные команды управления в LXC:${NC}"
echo -e " • Статус службы:          ${CYAN}systemctl status $SERVICE_NAME${NC}"
echo -e " • Просмотр логов:         ${CYAN}journalctl -u $SERVICE_NAME -f${NC}"
echo -e " • Перезапуск приложения:  ${CYAN}systemctl restart $SERVICE_NAME${NC}"
echo -e " • Обновление сертификата: ${CYAN}certbot renew${NC}"
echo -e " • Папка проекта:          ${CYAN}$APP_DIR${NC}"
echo ""
echo -e "${GREEN}==================================================================${NC}"
