const express = require('express');
const http = require('http');
const https = require('https');
const { Server } = require('socket.io');
const path = require('path');
const cors = require('cors');
const crypto = require('crypto');
const fs = require('fs');
const { exec } = require('child_process');
const { extractYouTubeId, getYouTubeMetadata } = require('./services/youtube');

const app = express();

// Check for SSL certificates in ./ssl/
const sslDir = path.join(__dirname, 'ssl');
const certPath = [
    path.join(sslDir, 'fullchain.pem'),
    path.join(sslDir, 'cert.pem'),
    path.join(sslDir, 'certificate.crt')
].find(p => fs.existsSync(p));

const keyPath = [
    path.join(sslDir, 'privkey.pem'),
    path.join(sslDir, 'key.pem'),
    path.join(sslDir, 'private.key')
].find(p => fs.existsSync(p));

let server;
let isHttps = false;

if (certPath && keyPath) {
    try {
        const sslOptions = {
            cert: fs.readFileSync(certPath),
            key: fs.readFileSync(keyPath)
        };
        server = https.createServer(sslOptions, app);
        isHttps = true;
        console.log(`[SSL] HTTPS enabled using ${path.basename(certPath)} & ${path.basename(keyPath)}`);
    } catch (err) {
        console.error('[SSL] Failed to load certificates, falling back to HTTP:', err.message);
        server = http.createServer(app);
    }
} else {
    server = http.createServer(app);
}

const io = new Server(server, {
    cors: {
        origin: '*',
        methods: ['GET', 'POST']
    }
});

const PORT = process.env.PORT || 3000;

// Config file for persistent streamer & widget keys
const CONFIG_FILE = path.join(__dirname, 'config.json');
let config = {
    streamerKey: 'admin123',
    widgetKey: crypto.randomBytes(6).toString('hex')
};

if (fs.existsSync(CONFIG_FILE)) {
    try {
        config = { ...config, ...JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8')) };
    } catch (e) {}
} else {
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
}

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public'), { index: false }));

// Persistent state file — survives server restarts
const STATE_FILE = path.join(__dirname, 'state.json');

function loadPersistedState() {
    if (fs.existsSync(STATE_FILE)) {
        try {
            const saved = JSON.parse(fs.readFileSync(STATE_FILE, 'utf-8'));
            return {
                currentTrack: saved.currentTrack || null,
                isPlaying: false,          // Always start paused after restart
                volume: saved.volume || 80,
                currentTime: 0,            // Reset time on restart
                duration: 0,
                queue: saved.queue || [],
                history: saved.history || [],
                settings: saved.settings || { maxQueueSize: 50, cooldownSeconds: 20 }
            };
        } catch (e) {}
    }
    return {
        currentTrack: null,
        isPlaying: false,
        volume: 80,
        currentTime: 0,
        duration: 0,
        queue: [],
        history: [],
        settings: { maxQueueSize: 50, cooldownSeconds: 20 }
    };
}

let saveStateTimer = null;
function saveState() {
    // Debounced save — avoids hammering disk on rapid events
    if (saveStateTimer) clearTimeout(saveStateTimer);
    saveStateTimer = setTimeout(() => {
        try {
            fs.writeFileSync(STATE_FILE, JSON.stringify({
                currentTrack: state.currentTrack,
                volume: state.volume,
                queue: state.queue,
                history: state.history,
                settings: state.settings
            }, null, 2));
        } catch (e) {
            console.error('Failed to save state:', e.message);
        }
    }, 500);
}

let state = loadPersistedState();

const userCooldowns = new Map();


function broadcastState() {
    io.emit('state_update', {
        currentTrack: state.currentTrack,
        isPlaying: state.isPlaying,
        volume: state.volume,
        currentTime: state.currentTime,
        duration: state.duration,
        queue: state.queue,
        history: state.history.slice(-15).reverse()
    });
}

function playNextTrack() {
    if (state.currentTrack) {
        state.history.push({
            ...state.currentTrack,
            playedAt: new Date().toISOString()
        });
        if (state.history.length > 50) {
            state.history.shift();
        }
    }

    if (state.queue.length > 0) {
        state.currentTrack = state.queue.shift();
        state.isPlaying = true;
        state.currentTime = 0;
        state.duration = 0;
    } else {
        state.currentTrack = null;
        state.isPlaying = false;
        state.currentTime = 0;
        state.duration = 0;
    }

    broadcastState();
    saveState();
}

// REST Endpoints
app.get('/api/state', (req, res) => {
    res.json({
        currentTrack: state.currentTrack,
        isPlaying: state.isPlaying,
        volume: state.volume,
        currentTime: state.currentTime,
        duration: state.duration,
        queue: state.queue,
        history: state.history.slice(-15).reverse()
    });
});

app.post('/api/auth/verify-widget', (req, res) => {
    const { key } = req.body;
    if (key === config.widgetKey) {
        return res.json({ success: true });
    }
    return res.status(401).json({ error: 'Недействительный ключ виджета' });
});

app.post('/api/auth/verify', (req, res) => {
    const { key } = req.body;
    if (key === config.streamerKey) {
        return res.json({ success: true, widgetKey: config.widgetKey });
    }
    return res.status(401).json({ error: 'Неверный пароль стримера' });
});

app.post('/api/auth/change-key', (req, res) => {
    const { currentKey, newKey } = req.body;
    if (currentKey !== config.streamerKey) {
        return res.status(401).json({ error: 'Неверный текущий пароль' });
    }
    if (!newKey || newKey.length < 4) {
        return res.status(400).json({ error: 'Новый пароль должен содержать минимум 4 символа' });
    }
    config.streamerKey = newKey;
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
    return res.json({ success: true, message: 'Пароль успешно обновлен' });
});

// Fallback Direct Audio Stream URL Cache & Extractor via yt-dlp
const audioUrlCache = new Map();

function getDirectAudioUrl(videoId) {
    return new Promise((resolve, reject) => {
        if (audioUrlCache.has(videoId)) {
            const cached = audioUrlCache.get(videoId);
            if (Date.now() - cached.time < 3 * 3600 * 1000) { // 3h cache
                return resolve(cached.url);
            }
        }

        const ytdlpBin = process.platform === 'win32'
            ? 'python -m yt_dlp'
            : (fs.existsSync('/usr/local/bin/yt-dlp') ? '/usr/local/bin/yt-dlp' : (fs.existsSync('/usr/bin/yt-dlp') ? '/usr/bin/yt-dlp' : 'python3 -m yt_dlp'));
        const cmd = `${ytdlpBin} -f "ba/b" -g "https://www.youtube.com/watch?v=${videoId}"`;
        exec(cmd, { timeout: 15000 }, (error, stdout, stderr) => {
            if (error) {
                console.error(`yt-dlp error for ${videoId}:`, error.message);
                return reject(error);
            }
            const lines = stdout.trim().split('\n').map(l => l.trim()).filter(l => l.startsWith('http'));
            if (lines.length > 0) {
                const url = lines[0];
                audioUrlCache.set(videoId, { url, time: Date.now() });
                resolve(url);
            } else {
                reject(new Error('No stream URL extracted'));
            }
        });
    });
}

app.get('/api/find-alternative/:videoId', async (req, res) => {
    const { videoId } = req.params;
    const title = req.query.title || (state.currentTrack ? state.currentTrack.title : '');

    try {
        const alternativeId = await searchPlayableAlternative(title || videoId, videoId);
        if (alternativeId) {
            return res.json({ success: true, alternativeId });
        }
        return res.json({ success: false });
    } catch (e) {
        return res.status(500).json({ error: 'Search failed' });
    }
});

app.post('/api/request', async (req, res) => {
    const { url, requesterName } = req.body;
    const clientIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress || 'unknown';

    const lastRequestTime = userCooldowns.get(clientIp);
    const now = Date.now();
    if (lastRequestTime && (now - lastRequestTime) < state.settings.cooldownSeconds * 1000) {
        const remaining = Math.ceil((state.settings.cooldownSeconds * 1000 - (now - lastRequestTime)) / 1000);
        return res.status(429).json({ error: `Подождите ${remaining} сек. перед следующим заказом` });
    }

    const videoId = extractYouTubeId(url);
    if (!videoId) {
        return res.status(400).json({ error: 'Неверная ссылка на YouTube видео' });
    }

    if (state.queue.length >= state.settings.maxQueueSize) {
        return res.status(400).json({ error: 'Очередь переполнена' });
    }

    try {
        const metadata = await getYouTubeMetadata(videoId);
        const track = {
            orderId: 'tr_' + Math.random().toString(36).substring(2, 9),
            ...metadata,
            requestedBy: (requesterName || 'Анонимный зритель').trim().substring(0, 30),
            addedAt: new Date().toISOString()
        };

        if (!state.currentTrack) {
            state.currentTrack = track;
            state.isPlaying = true;
            state.currentTime = 0;
            state.duration = 0;
        } else {
            state.queue.push(track);
        }

        userCooldowns.set(clientIp, now);
        broadcastState();
        saveState();

        io.emit('new_request_notification', track);

        return res.json({ success: true, track });
    } catch (err) {
        console.error('Error handling track request:', err);
        return res.status(500).json({ error: 'Не удалось получить информацию о треке' });
    }
});

// Socket.io Real-Time Synchronization Handling
let lastEndedTrackId = null;

io.on('connection', (socket) => {
    // Send current full state to newly connected client so panel can restore on reconnect
    socket.emit('state_update', {
        currentTrack: state.currentTrack,
        isPlaying: state.isPlaying,
        volume: state.volume,
        currentTime: state.currentTime,
        duration: state.duration,
        queue: state.queue,
        history: state.history.slice(-15).reverse()
    });

    socket.on('preview_track', async (url, callback) => {
        const videoId = extractYouTubeId(url);
        if (!videoId) {
            return callback({ error: 'Некорректная ссылка на YouTube' });
        }
        try {
            const meta = await getYouTubeMetadata(videoId);
            callback({ success: true, metadata: meta });
        } catch (err) {
            callback({ error: 'Не удалось загрузить данные видео' });
        }
    });

    // ─── WIDGET is the master audio source ───────────────────────────
    // Widget (always open in OBS) reports progress — server stores it
    socket.on('widget_progress', (data) => {
        if (data && data.widgetKey === config.widgetKey) {
            state.currentTime = data.currentTime || 0;
            state.duration = data.duration || 0;
            // Broadcast progress to everyone else (panel etc.)
            socket.broadcast.emit('progress_update', {
                currentTime: state.currentTime,
                duration: state.duration
            });
        }
    });

    // Widget reports track ended → advance queue
    socket.on('widget_track_ended', (widgetKey) => {
        if (widgetKey !== config.widgetKey) return;
        if (state.currentTrack && state.currentTrack.orderId === lastEndedTrackId) return;
        if (state.currentTrack) {
            lastEndedTrackId = state.currentTrack.orderId;
        }
        playNextTrack();
    });

    // ─── PANEL can also report progress as fallback (when widget offline) ─
    socket.on('player_progress', (data) => {
        if (data && data.authKey === config.streamerKey) {
            // Only update if widget hasn't reported recently (widget is preferred master)
            state.currentTime = data.currentTime || 0;
            state.duration = data.duration || 0;
            socket.broadcast.emit('progress_update', {
                currentTime: state.currentTime,
                duration: state.duration
            });
        }
    });

    socket.on('player_state_change', ({ isPlaying, authKey }) => {
        if (authKey !== config.streamerKey) return;
        state.isPlaying = !!isPlaying;
        io.emit('play_state_update', state.isPlaying);
    });

    socket.on('player_track_ended', (authKey) => {
        if (authKey !== config.streamerKey) return;
        if (state.currentTrack && state.currentTrack.orderId === lastEndedTrackId) return;
        if (state.currentTrack) {
            lastEndedTrackId = state.currentTrack.orderId;
        }
        playNextTrack();
    });

    // ─── Remote Controls from Panel ──────────────────────────────────
    socket.on('control_play_pause', (authKey) => {
        if (authKey !== config.streamerKey) return;
        state.isPlaying = !state.isPlaying;
        io.emit('command_play_pause', state.isPlaying);
        io.emit('play_state_update', state.isPlaying);
    });

    // Force-set play/pause state (used when syncing native YouTube player controls)
    socket.on('control_play_pause_force', ({ isPlaying, authKey }) => {
        if (authKey !== config.streamerKey) return;
        state.isPlaying = !!isPlaying;
        io.emit('command_play_pause', state.isPlaying);
        io.emit('play_state_update', state.isPlaying);
    });

    socket.on('control_skip', (authKey) => {
        if (authKey !== config.streamerKey) return;
        playNextTrack();
        io.emit('command_play_next');
    });

    socket.on('control_seek', ({ time, authKey }) => {
        if (authKey !== config.streamerKey) return;
        state.currentTime = Number(time) || 0;
        io.emit('command_seek', state.currentTime);
        io.emit('progress_update', { currentTime: state.currentTime, duration: state.duration });
    });

    socket.on('control_set_volume', ({ volume, authKey }) => {
        if (authKey !== config.streamerKey) return;
        state.volume = Math.max(0, Math.min(100, Number(volume) || 80));
        io.emit('command_set_volume', state.volume);
        saveState();
    });

    socket.on('control_remove_track', ({ orderId, authKey }) => {
        if (authKey !== config.streamerKey) return;
        state.queue = state.queue.filter(item => item.orderId !== orderId);
        broadcastState();
        saveState();
    });

    socket.on('control_clear_queue', (authKey) => {
        if (authKey !== config.streamerKey) return;
        state.queue = [];
        broadcastState();
        saveState();
    });

    // Replay from history: skip current track and play the history track immediately
    socket.on('control_replay_from_history', ({ orderId, authKey }) => {
        if (authKey !== config.streamerKey) return;
        const track = state.history.find(t => t.orderId === orderId);
        if (!track) return;

        // Move current track to history if one is playing
        if (state.currentTrack) {
            state.history.push({ ...state.currentTrack, playedAt: new Date().toISOString() });
            if (state.history.length > 50) state.history.shift();
        }

        // Start the history track immediately with a fresh ID
        state.currentTrack = {
            ...track,
            orderId: 'tr_' + Math.random().toString(36).substring(2, 9),
            addedAt: new Date().toISOString()
        };
        state.isPlaying = true;
        state.currentTime = 0;
        state.duration = 0;
        lastEndedTrackId = null;

        broadcastState();
        saveState();
    });

    // Add from history back into the queue (at end)
    socket.on('control_add_from_history', ({ orderId, authKey }) => {
        if (authKey !== config.streamerKey) return;
        const track = state.history.find(t => t.orderId === orderId);
        if (!track) return;

        const newTrack = {
            ...track,
            orderId: 'tr_' + Math.random().toString(36).substring(2, 9),
            addedAt: new Date().toISOString()
        };

        if (!state.currentTrack) {
            // Nothing playing — start immediately
            state.currentTrack = newTrack;
            state.isPlaying = true;
            state.currentTime = 0;
            state.duration = 0;
        } else {
            state.queue.push(newTrack);
        }

        broadcastState();
        saveState();
    });
});

app.get('/music-panel', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'player.html'));
});

app.get('/player', (req, res) => {
    res.redirect('/music-panel');
});

app.get('/order-music', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'order.html'));
});

app.get('/widget', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'widget.html'));
});

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'home.html'));
});

server.listen(PORT, () => {
    const proto = isHttps ? 'https' : 'http';
    const domain = config.domain || process.env.DOMAIN;
    const baseHost = domain ? `${proto}://${domain}` : `${proto}://localhost:${PORT}`;
    console.log(`====================================================`);
    console.log(`Stream Music Request System Running [${proto.toUpperCase()}]`);
    console.log(`Ссылка для зрителей:   ${baseHost}/order-music`);
    console.log(`Главная страница:      ${baseHost}/`);
    console.log(`Панель стримера:       ${baseHost}/music-panel`);
    console.log(`Пароль стримера:       ${config.streamerKey}`);
    console.log(`Виджет для OBS:        ${baseHost}/widget?key=${config.widgetKey}`);
    console.log(`====================================================`);
});
