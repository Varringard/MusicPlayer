#!/usr/bin/env bash
# ==============================================================================
#  🔄 MusicPlayer Update Script
# ==============================================================================
#  Обновление файлов приложения, зависимостей npm и перезапуск службы.
# ==============================================================================

set -e

APP_DIR="/opt/musicplayer"
SERVICE_NAME="musicplayer"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите скрипт от имени root или через sudo."
    exit 1
fi

echo -e "${BLUE}=== Обновление MusicPlayer ===${NC}"

if [ -d "$APP_DIR/.git" ]; then
    echo -e "${YELLOW}Получение последних обновлений из Git...${NC}"
    cd "$APP_DIR"
    git pull
else
    echo -e "Папка $APP_DIR не является git-репозиторием. Пропуск git pull."
    cd "$APP_DIR"
fi

echo -e "${YELLOW}Обновление npm зависимостей...${NC}"
npm install --omit=dev --no-audit --no-fund

echo -e "${YELLOW}Перезапуск службы $SERVICE_NAME...${NC}"
systemctl restart "$SERVICE_NAME"

sleep 1
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "${GREEN}✓ MusicPlayer успешно обновлен и запущен!${NC}"
else
    echo -e "⚠️ Ошибка при перезапуске службы. Проверьте: journalctl -u $SERVICE_NAME -n 50"
fi
