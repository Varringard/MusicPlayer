# 🎵 Stream Music Request & Twitch OBS Player

Система для заказа музыки с YouTube от зрителей на стриме с автоматическим воспроизведением в плеере стримера и красивым анимированным виджетом для OBS Studio / Streamlabs.

---

## ⚡ Развертывание в LXC (Proxmox / Debian / Ubuntu) одним скриптом

Проект полностью оптимизирован для быстрой установки в чистый **LXC-контейнер** (Proxmox VE, Debian 12 или Ubuntu 22.04 / 24.04).

Скрипт `install.sh` автоматически:
- Установит **Node.js 20 LTS**, **npm**, **Python 3**, **yt-dlp**, **Nginx** и **Certbot**;
- Развернет приложение в каталог `/opt/musicplayer`;
- Сконфигурирует **Nginx Reverse Proxy** с поддержкой WebSockets (Socket.IO);
- Бесплатно выпустит и настроит **SSL-сертификат Let's Encrypt** по вашему домену с автопродлением;
- Создаст и запустит системную службу **systemd** (`musicplayer.service`) для круглосуточной работы 24/7.

### 🚀 Установка одной командой в консоли контейнера:

Вставьте команду в консоль чистого контейнера:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Varringard/MusicPlayer/main/install.sh)"
```

Скрипт сам загрузит проект, установит всё окружение и запросит у вас домен и e-mail!

> **Полный автомат без лишних вопросов (замените домен и почту на свои):**
> ```bash
> bash -c "$(curl -fsSL https://raw.githubusercontent.com/Varringard/MusicPlayer/main/install.sh)" -- -d music.mydomain.com -e myemail@example.com -k "МойПарольСтримера" -y
> ```

---

## 🛠 Управление в LXC

- **Статус службы**: `systemctl status musicplayer`
- **Просмотр логов в реальном времени**: `journalctl -u musicplayer -f`
- **Перезапуск**: `systemctl restart musicplayer`
- **Быстрое обновление проекта**:
  ```bash
  bash /opt/musicplayer/scripts/update.sh
  ```

---

## 🚀 Ручной запуск (Linux / Тестирование)

1. Установите зависимости:
   ```bash
   npm install
   ```
2. Запустите сервер:
   ```bash
   npm start
   # или node server.js
   ```

---

## 🌐 Ссылки и страницы

- **Главная страница**: `https://<ваш_домен>/`
- **Страница заказа для зрителей**: `https://<ваш_домен>/order-music`  
  *Зрители вводят никнейм и ссылку на YouTube (видео, клип, Shorts). Трек автоматически добавляется в очередь.*
- **Панель стримера**: `https://<ваш_домен>/music-panel`  
  *Управление воспроизведением (Play/Pause, Skip, перемотка, громкость, история и очистка очереди). Защищена паролем.*
- **Виджет для OBS Studio / Streamlabs**: `https://<ваш_домен>/widget?key=<WIDGET_KEY>`  
  *Оверлей с прозрачным фоном и аудио-движком для сцены OBS.*

---

## 📺 Настройка в OBS Studio / Streamlabs

1. В OBS в блоке **Источники (Sources)** нажмите **`+`** и выберите **Браузер (Browser Source)**.
2. Назовите источник, например, `Music Widget`.
3. В поле **URL** укажите ссылку виджета:
   ```
   https://<ваш_домен>/widget?key=<WIDGET_KEY>
   ```
4. Рекомендуемые параметры:
   - **Ширина (Width)**: `600`
   - **Высота (Height)**: `200`
   - **Управление звуком через OBS**: включите по желанию, чтобы управлять громкостью виджета прямо в микшере OBS.
