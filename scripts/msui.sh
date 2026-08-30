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

detect_external_port() {
    local dom="$1"
    [ -z "$dom" ] && return
    # Проверка порта 3000
    if curl -s -k --connect-timeout 2 "https://${dom}:3000/" >/dev/null 2>&1; then
        echo "3000"
        return
    fi
    # Проверка стандартного 443
    if curl -s -k --connect-timeout 2 "https://${dom}/" >/dev/null 2>&1; then
        echo "443"
        return
    fi
    # Проверка 8443
    if curl -s -k --connect-timeout 2 "https://${dom}:8443/" >/dev/null 2>&1; then
        echo "8443"
        return
    fi
    echo ""
}

menu_links() {
    clear
    echo -e "${CYAN}${BOLD}=== 🔗 Ссылки для стрима и ключи доступа ===${NC}\n"
    local domain=$(get_config_val "domain")
    local skey=$(get_config_val "streamerKey")
    local wkey=$(get_config_val "widgetKey")
    local ext_port=$(get_config_val "externalPort")

    # Автоматическое определение порта при первом открытии
    if [ -z "$ext_port" ] && [ -n "$domain" ]; then
        local detected=$(detect_external_port "$domain")
        if [ -n "$detected" ]; then
            ext_port="$detected"
            set_config_val "externalPort" "$detected"
        fi
    fi
    
    local proto="http"
    if certbot certificates 2>/dev/null | grep -q "$domain"; then
        proto="https"
    fi

    local port_str=""
    if [ -n "$ext_port" ] && [ "$ext_port" != "80" ] && [ "$ext_port" != "443" ]; then
        port_str=":$ext_port"
    fi

    local full_host="${domain}${port_str}"

    echo -e "🎵 ${BOLD}Заказ музыки для зрителей:${NC}"
    echo -e "   ${CYAN}${proto}://${full_host}/order-music${NC}\n"

    echo -e "🎛 ${BOLD}Панель стримера (управление плеером):${NC}"
    echo -e "   ${CYAN}${proto}://${full_host}/music-panel${NC}"
    echo -e "   🔑 Пароль стримера: ${YELLOW}${BOLD}${skey}${NC}\n"

    echo -e "📺 ${BOLD}Виджет для OBS Studio / Streamlabs (Browser Source):${NC}"
    echo -e "   ${CYAN}${proto}://${full_host}/widget?key=${wkey}${NC}\n"

    echo -e "🌐 ${BOLD}Главная страница:${NC}"
    echo -e "   ${CYAN}${proto}://${full_host}/${NC}\n"

    if [ -z "$port_str" ]; then
        echo -e "${DIM}💡 Если на роутере проброшен нестандартный порт (например, 3000), укажите его в пункте 3 меню (Смена портов).${NC}\n"
    fi

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
    echo -e "5) ${YELLOW}${BOLD}🦆 Настроить DuckDNS (авто-IP каждые 5 мин + SSL БЕЗ 80 порта)${NC}"
    echo "0) Назад в главное меню"
    echo ""
    read -rp "Выберите действие [0-5]: " choice

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
        5)
            echo -e "\n${CYAN}${BOLD}=== Настройка DuckDNS (Авто-IP + SSL без открытого 80 порта) ===${NC}\n"
            read -rp "Введите ваш домен [$domain]: " input_domain
            input_domain=${input_domain:-$domain}
            subdomain=$(echo "$input_domain" | sed 's/\.duckdns\.org//')

            current_token=$(get_config_val "duckdnsToken")
            read -rp "Введите ваш DuckDNS Token [$current_token]: " input_token
            input_token=${input_token:-$current_token}

            if [ -z "$input_token" ]; then
                echo -e "${RED}[ОШИБКА] Токен DuckDNS не может быть пустым!${NC}"
                pause_key
                return
            fi

            # Проверяем токен
            echo -e "\n${YELLOW}Проверка токена через DuckDNS API...${NC}"
            check_res=$(curl -s "https://www.duckdns.org/update?domains=${subdomain}&token=${input_token}&ip=")
            if [ "$check_res" != "OK" ]; then
                echo -e "${RED}Ошибка ответа от DuckDNS: $check_res. Проверьте правильность домена и токена.${NC}"
                pause_key
                return
            fi
            echo -e "${GREEN}✓ Связь с DuckDNS успешна! (IP синхронизирован)${NC}"

            # Сохраняем токен и домен в config.json
            set_config_val "duckdnsToken" "$input_token"
            set_config_val "domain" "$input_domain"

            # 1. Настраиваем cron на автообновление динамического IP каждые 5 минут
            echo -e "\n${YELLOW}Настройка автообновления динамического IP каждые 5 минут...${NC}"
            cat <<EOF > /etc/cron.d/duckdns
*/5 * * * * root curl -s "https://www.duckdns.org/update?domains=${subdomain}&token=${input_token}&ip=" >/dev/null 2>&1
EOF
            chmod 644 /etc/cron.d/duckdns
            echo -e "${GREEN}✓ Автообновление динамического IP активировано (/etc/cron.d/duckdns)${NC}"

            # 2. Выпуск SSL через DNS-01 Challenge
            read -rp "Введите email для Let's Encrypt [admin@$input_domain]: " input_email
            input_email=${input_email:-"admin@$input_domain"}

            chmod +x "$APP_DIR/scripts/duckdns-auth.sh" 2>/dev/null || true
            chmod +x "$APP_DIR/scripts/duckdns-cleanup.sh" 2>/dev/null || true

            echo -e "\n${YELLOW}Запуск выпуска сертификата через DNS-запись DuckDNS (займет ~40 сек)...${NC}"
            export DUCKDNS_TOKEN="$input_token"

            if certbot certonly \
                --manual \
                --preferred-challenges dns \
                --manual-auth-hook "$APP_DIR/scripts/duckdns-auth.sh" \
                --manual-cleanup-hook "$APP_DIR/scripts/duckdns-cleanup.sh" \
                -d "$input_domain" \
                --non-interactive \
                --agree-tos \
                -m "$input_email"; then

                echo -e "\n${GREEN}✓ SSL сертификат успешно получен без использования 80 порта!${NC}"

                # Настраиваем Nginx с SSL
                cat <<EOF > "$NGINX_CONF"
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen [::]:80;
    server_name $input_domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $input_domain;

    ssl_certificate /etc/letsencrypt/live/$input_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$input_domain/privkey.pem;

    client_max_body_size 25M;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
                nginx -t && systemctl reload nginx
                echo -e "${GREEN}${BOLD}✓ Nginx успешно переключен на HTTPS! Сайт доступен по https://$input_domain/${NC}"
            else
                echo -e "${RED}Не удалось выпустить сертификат через DuckDNS. Проверьте логи: /var/log/letsencrypt/letsencrypt.log${NC}"
            fi
            pause_key
            ;;
        *) ;;
    esac
}

menu_ports() {
    clear
    echo -e "${CYAN}${BOLD}=== ⚙️ Настройка портов (Внешний порт и Nginx) ===${NC}\n"
    local current_ext_port=$(get_config_val "externalPort")
    current_ext_port=${current_ext_port:-"443 (стандартный)"}

    echo -e "Текущий внешний порт для ссылок: ${YELLOW}${BOLD}${current_ext_port}${NC}\n"
    echo "1) Указать внешний порт роутера для ссылок (например: 3000)"
    echo "2) Изменить внутренние порты в конфиге Nginx"
    echo "0) Назад"
    echo ""
    read -rp "Выберите действие [0-2]: " port_choice

    case $port_choice in
        1)
            echo ""
            read -rp "Введите внешний порт роутера (например, 3000 или 443): " new_ext_port
            new_ext_port=$(echo "$new_ext_port" | tr -d ' ')
            if [ -n "$new_ext_port" ]; then
                set_config_val "externalPort" "$new_ext_port"
                echo -e "\n${GREEN}✓ Внешний порт $new_ext_port сохранен! Теперь все ссылки будут генерироваться с :$new_ext_port${NC}"
                systemctl restart "$SERVICE_NAME"
            fi
            pause_key
            ;;
        2)
            if [ ! -f "$NGINX_CONF" ]; then
                echo -e "${RED}Конфигурационный файл $NGINX_CONF не найден!${NC}"
                pause_key
                return
            fi

            echo "Текущие порты в Nginx:"
            grep -E "listen " "$NGINX_CONF" | sed -e 's/^[[:space:]]*//'
            echo ""
            read -rp "Хотите изменить порты в конфигурации Nginx? (y/n): " confirm
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
            ;;
        *) ;;
    esac
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
