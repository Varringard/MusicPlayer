#!/usr/bin/env bash
# ==============================================================================
#  🎵 msui — MusicPlayer Server Terminal Control Panel
# ==============================================================================
#  Интерактивная консольная панель управления MusicPlayer для Linux / LXC.
# ==============================================================================

APP_DIR="/opt/musicplayer"
CONFIG_FILE="$APP_DIR/config.json"
STATE_FILE="$APP_DIR/state.json"
NGINX_CONF="/etc/nginx/sites-available/musicplayer.conf"
SERVICE_NAME="musicplayer"

# Цветовая палитра
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ОШИБКА] msui требует прав суперпользователя. Запустите: sudo msui${NC}"
    exit 1
fi

get_config_val() {
    local key="$1"
    if [ -f "$CONFIG_FILE" ]; then
        grep -o "\"$key\": \"[^\"]*" "$CONFIG_FILE" | cut -d'"' -f4 || echo ""
    fi
}

set_config_val() {
    local key="$1"
    local val="$2"
    if [ -f "$CONFIG_FILE" ]; then
        node -e "
            const fs = require('fs');
            const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
            cfg['$key'] = '$val';
            fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
        " 2>/dev/null || true
    fi
}

pause_key() {
    echo ""
    read -rp "Нажмите [Enter] для возврата в меню..."
}

show_header() {
    clear
    local domain=$(get_config_val "domain")
    domain=${domain:-"не настроен"}

    local mp_status="${RED}● остановлен${NC}"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        local mem=$(ps -o rss= -C node 2>/dev/null | awk '{sum+=$1} END {printf "%.1f MB", sum/1024}')
        mp_status="${GREEN}● активен${NC} ${DIM}(RAM: ${mem:-"~60MB"})${NC}"
    fi

    local nginx_status="${RED}● остановлен${NC}"
    if systemctl is-active --quiet nginx; then
        nginx_status="${GREEN}● активен${NC}"
    fi

    local ssl_status="${YELLOW}HTTP (без SSL)${NC}"
    if certbot certificates 2>/dev/null | grep -q "$domain"; then
        local expire=$(certbot certificates 2>/dev/null | grep "Expiry Date:" | head -1 | sed -e 's/^[[:space:]]*//')
        ssl_status="${GREEN}HTTPS (активен)${NC} ${DIM}${expire}${NC}"
    fi

    echo -e "${CYAN}${BOLD}========================================================================"
    echo -e "       🎵  MUSICPLAYER — ПАНЕЛЬ УПРАВЛЕНИЯ СЕРВЕРОМ (msui)             "
    echo -e "========================================================================${NC}"
    echo -e " 🌐 Домен:         ${BOLD}${domain}${NC}"
    echo -e " ⚙️ Служба плеера:  ${mp_status}"
    echo -e " 🌐 Веб-сервер:    ${nginx_status}"
    echo -e " 🔒 Статус SSL:    ${ssl_status}"
    echo -e "${CYAN}------------------------------------------------------------------------${NC}"
}

menu_links() {
    clear
    echo -e "${CYAN}${BOLD}=== 🔗 Ссылки для стрима и ключи доступа ===${NC}\n"
    local domain=$(get_config_val "domain")
    local skey=$(get_config_val "streamerKey")
    local wkey=$(get_config_val "widgetKey")
    
    local proto="http"
    if certbot certificates 2>/dev/null | grep -q "$domain"; then
        proto="https"
    fi

    echo -e "🎵 ${BOLD}Заказ музыки для зрителей:${NC}"
    echo -e "   ${CYAN}${proto}://${domain}/order-music${NC}\n"

    echo -e "🎛 ${BOLD}Панель стримера (управление плеером):${NC}"
    echo -e "   ${CYAN}${proto}://${domain}/music-panel${NC}"
    echo -e "   🔑 Пароль стримера: ${YELLOW}${BOLD}${skey}${NC}\n"

    echo -e "📺 ${BOLD}Виджет для OBS Studio / Streamlabs (Browser Source):${NC}"
    echo -e "   ${CYAN}${proto}://${domain}/widget?key=${wkey}${NC}\n"

    echo -e "🌐 ${BOLD}Главная страница:${NC}"
    echo -e "   ${CYAN}${proto}://${domain}/${NC}\n"

    pause_key
}

menu_ssl() {
    clear
    local domain=$(get_config_val "domain")
    echo -e "${CYAN}${BOLD}=== 🔒 Управление SSL-сертификатами Let's Encrypt ===${NC}\n"
    echo -e "Текущий домен: ${BOLD}${domain}${NC}\n"
    echo "1) Выпустить / Перевыпустить сертификат (certbot --nginx)"
    echo "2) Принудительно продлить сертификат (certbot renew --force-renewal)"
    echo "3) Проверить статус сертификатов (certbot certificates)"
    echo "4) Тестовая проверка автопродления (dry-run)"
    echo "0) Назад в главное меню"
    echo ""
    read -rp "Выберите действие [0-4]: " choice

    case $choice in
        1)
            echo ""
            read -rp "Введите домен [$domain]: " input_domain
            input_domain=${input_domain:-$domain}
            read -rp "Введите email для Let's Encrypt: " input_email
            input_email=${input_email:-"admin@$input_domain"}
            echo -e "\n${YELLOW}Запуск Certbot...${NC}"
            certbot --nginx -d "$input_domain" --non-interactive --agree-tos -m "$input_email" --redirect
            if [ "$input_domain" != "$domain" ]; then
                set_config_val "domain" "$input_domain"
            fi
            systemctl reload nginx
            pause_key
            ;;
        2)
            echo -e "\n${YELLOW}Продление сертификатов...${NC}"
            certbot renew --force-renewal
            systemctl reload nginx
            pause_key
            ;;
        3)
            echo ""
            certbot certificates
            pause_key
            ;;
        4)
            echo -e "\n${YELLOW}Тестирование автопродления (dry-run)...${NC}"
            certbot renew --dry-run
            pause_key
            ;;
        *) ;;
    esac
}

menu_ports() {
    clear
    echo -e "${CYAN}${BOLD}=== ⚙️ Смена портов веб-сервера (Nginx) ===${NC}\n"

    if [ ! -f "$NGINX_CONF" ]; then
        echo -e "${RED}Конфигурационный файл $NGINX_CONF не найден!${NC}"
        pause_key
        return
    fi

    echo "Текущие порты в Nginx:"
    grep -E "listen " "$NGINX_CONF" | sed -e 's/^[[:space:]]*//'
    echo ""
    echo "Вы можете изменить внешний порт HTTP или HTTPS."
    echo "Например: если порт 80 или 443 заняты, можно указать 8080 или 8443."
    echo ""
    read -rp "Хотите изменить порты в конфигурации? (y/n): " confirm
    if [[ "$confirm" =~ ^[YyДд]$ ]]; then
        read -rp "Новый порт HTTP (Enter чтобы оставить по умолчанию 80): " new_http
        read -rp "Новый порт HTTPS (Enter чтобы оставить по умолчанию 443): " new_https

        if [ -n "$new_http" ]; then
            sed -i -E "s/listen [0-9]+;/listen $new_http;/g" "$NGINX_CONF"
            sed -i -E "s/listen \[::\]:[0-9]+;/listen [::]:$new_http;/g" "$NGINX_CONF"
        fi

        if [ -n "$new_https" ]; then
            sed -i -E "s/listen [0-9]+ ssl;/listen $new_https ssl;/g" "$NGINX_CONF"
            sed -i -E "s/listen \[::\]:[0-9]+ ssl;/listen [::]:$new_https ssl;/g" "$NGINX_CONF"
        fi

        echo -e "\n${YELLOW}Проверка синтаксиса Nginx...${NC}"
        if nginx -t; then
            systemctl reload nginx
            echo -e "${GREEN}✓ Порты успешно обновлены и применены!${NC}"
        else
            echo -e "${RED}Ошибка в конфигурации Nginx! Проверьте файл $NGINX_CONF${NC}"
        fi
    fi
    pause_key
}

menu_change_domain() {
    clear
    echo -e "${CYAN}${BOLD}=== 🌐 Смена привязанного домена ===${NC}\n"
    local current_domain=$(get_config_val "domain")
    echo -e "Текущий домен: ${BOLD}${current_domain}${NC}\n"

    read -rp "Введите новый домен (например: stream.mydomain.ru): " new_domain
    new_domain=$(echo "$new_domain" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

    if [ -n "$new_domain" ] && [ "$new_domain" != "$current_domain" ]; then
        set_config_val "domain" "$new_domain"
        
        # Обновляем server_name в Nginx
        if [ -f "$NGINX_CONF" ]; then
            sed -i -E "s/server_name [^;]+;/server_name $new_domain;/g" "$NGINX_CONF"
            nginx -t && systemctl reload nginx
        fi

        systemctl restart "$SERVICE_NAME"
        echo -e "\n${GREEN}✓ Домен успешно изменен на $new_domain!${NC}"
        
        read -rp "Выпустить SSL-сертификат для нового домена прямо сейчас? (y/n): " do_ssl
        if [[ "$do_ssl" =~ ^[YyДд]$ ]]; then
            read -rp "Email для Let's Encrypt [admin@$new_domain]: " ssl_email
            ssl_email=${ssl_email:-"admin@$new_domain"}
            certbot --nginx -d "$new_domain" --non-interactive --agree-tos -m "$ssl_email" --redirect
            systemctl reload nginx
        fi
    else
        echo -e "${YELLOW}Домен не изменен.${NC}"
    fi
    pause_key
}

menu_change_password() {
    clear
    echo -e "${CYAN}${BOLD}=== 🔑 Смена пароля стримера ===${NC}\n"
    local current_key=$(get_config_val "streamerKey")
    echo -e "Текущий пароль стримера: ${YELLOW}${BOLD}${current_key}${NC}\n"

    read -rp "Введите новый пароль стримера (минимум 4 символа): " new_key
    if [ ${#new_key} -ge 4 ]; then
        set_config_val "streamerKey" "$new_key"
        systemctl restart "$SERVICE_NAME"
        echo -e "\n${GREEN}✓ Пароль стримера успешно обновлен на: ${YELLOW}${BOLD}${new_key}${NC}"
    else
        echo -e "\n${RED}[ОШИБКА] Пароль должен быть длиной не менее 4 символов.${NC}"
    fi
    pause_key
}

menu_logs() {
    clear
    echo -e "${CYAN}${BOLD}=== 📜 Логи MusicPlayer (для выхода нажмите Ctrl + C) ===${NC}\n"
    journalctl -u "$SERVICE_NAME" -f -n 50
}

menu_service_control() {
    clear
    echo -e "${CYAN}${BOLD}=== 🔄 Управление системными службами ===${NC}\n"
    echo "1) Перезапустить MusicPlayer (systemctl restart musicplayer)"
    echo "2) Остановить MusicPlayer (systemctl stop musicplayer)"
    echo "3) Запустить MusicPlayer (systemctl start musicplayer)"
    echo "4) Перезапустить Nginx (systemctl restart nginx)"
    echo "5) Полный статус службы (systemctl status musicplayer)"
    echo "0) Назад"
    echo ""
    read -rp "Выберите действие [0-5]: " choice

    case $choice in
        1)
            systemctl restart "$SERVICE_NAME"
            echo -e "${GREEN}✓ MusicPlayer перезапущен!${NC}"
            pause_key
            ;;
        2)
            systemctl stop "$SERVICE_NAME"
            echo -e "${YELLOW}MusicPlayer остановлен.${NC}"
            pause_key
            ;;
        3)
            systemctl start "$SERVICE_NAME"
            echo -e "${GREEN}✓ MusicPlayer запущен!${NC}"
            pause_key
            ;;
        4)
            systemctl restart nginx
            echo -e "${GREEN}✓ Nginx перезапущен!${NC}"
            pause_key
            ;;
        5)
            echo ""
            systemctl status "$SERVICE_NAME" --no-pager
            pause_key
            ;;
        *) ;;
    esac
}

menu_reset_state() {
    clear
    echo -e "${RED}${BOLD}=== 🗑️ Сброс очереди и истории треков ===${NC}\n"
    echo -e "${YELLOW}Это действие очистит текущую очередь треков и историю проигранного.${NC}"
    echo -e "Настройки и пароли останутся нетронутыми.\n"
    read -rp "Вы уверены? (y/n): " confirm
    if [[ "$confirm" =~ ^[YyДд]$ ]]; then
        cat <<EOF > "$STATE_FILE"
{
  "currentTrack": null,
  "isPlaying": false,
  "volume": 80,
  "currentTime": 0,
  "duration": 0,
  "queue": [],
  "history": [],
  "settings": {
    "maxQueueSize": 50,
    "cooldownSeconds": 20
  }
}
EOF
        systemctl restart "$SERVICE_NAME"
        echo -e "\n${GREEN}✓ Очередь и история успешно очищены!${NC}"
    else
        echo -e "\nДействие отменено."
    fi
    pause_key
}

menu_update_app() {
    clear
    echo -e "${CYAN}${BOLD}=== ⬆️ Обновление MusicPlayer из GitHub ===${NC}\n"
    if [ -f "$APP_DIR/scripts/update.sh" ]; then
        bash "$APP_DIR/scripts/update.sh"
    else
        echo -e "${YELLOW}Скрипт update.sh не найден, выполняется прямое обновление...${NC}"
        cd "$APP_DIR" && git pull && npm install --omit=dev && systemctl restart "$SERVICE_NAME"
    fi
    pause_key
}

# Главный цикл меню
while true; do
    show_header
    echo " 1) 🔗 Показать ссылки для стрима и пароли"
    echo " 2) 🔒 Управление SSL-сертификатом (создать, продлить, статус)"
    echo " 3) ⚙️ Изменить порты веб-сервера (HTTP / HTTPS)"
    echo " 4) 🌐 Сменить привязанный домен"
    echo " 5) 🔑 Сменить пароль стримера"
    echo " 6) 📜 Просмотр логов в реальном времени (journalctl)"
    echo " 7) 🔄 Управление службой (перезапуск, остановка, статус)"
    echo " 8) 🗑️ Очистить очередь и историю треков"
    echo " 9) ⬆️ Проверить и установить обновления с GitHub"
    echo " 0) 🚪 Выход из msui"
    echo -e "${CYAN}------------------------------------------------------------------------${NC}"
    read -rp "Выберите пункт меню [0-9]: " action

    case $action in
        1) menu_links ;;
        2) menu_ssl ;;
        3) menu_ports ;;
        4) menu_change_domain ;;
        5) menu_change_password ;;
        6) menu_logs ;;
        7) menu_service_control ;;
        8) menu_reset_state ;;
        9) menu_update_app ;;
        0) clear; echo -e "${GREEN}До свидания! Панель всегда доступна по команде: ${BOLD}msui${NC}\n"; exit 0 ;;
        *) ;;
    esac
done
