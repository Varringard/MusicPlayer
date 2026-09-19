/**
 * YouTube Utility functions for extracting Video IDs, metadata, and searching alternatives
 */

function extractYouTubeId(urlOrId) {
    if (!urlOrId) return null;
    const trimmed = urlOrId.trim();

    // Direct 11-character ID
    if (/^[a-zA-Z0-9_-]{11}$/.test(trimmed)) {
        return trimmed;
    }

    // Standard YouTube URL patterns
    const patterns = [
        /(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/|youtube\.com\/shorts\/|music\.youtube\.com\/watch\?v=)([a-zA-Z0-9_-]{11})/,
        /^https?:\/\/(?:www\.)?youtube\.com\/live\/([a-zA-Z0-9_-]{11})/
    ];

    for (const pattern of patterns) {
        const match = trimmed.match(pattern);
        if (match && match[1]) {
            return match[1];
        }
    }

    return null;
}

const { exec } = require('child_process');
const fs = require('fs');

function getYtDlpBinary() {
    if (process.platform === 'win32') return 'python -m yt_dlp';
    if (fs.existsSync('/usr/local/bin/yt-dlp')) return '/usr/local/bin/yt-dlp';
    if (fs.existsSync('/usr/bin/yt-dlp')) return '/usr/bin/yt-dlp';
    return 'yt-dlp';
}

function getMetadataViaYtDlp(videoId) {
    return new Promise((resolve, reject) => {
        const bin = getYtDlpBinary();
        const cmd = `${bin} --skip-download --no-cache-dir --no-warnings --print "%(title)s///%(uploader)s" "https://www.youtube.com/watch?v=${videoId}"`;
        exec(cmd, { timeout: 25000 }, (err, stdout, stderr) => {
            if (err || !stdout || !stdout.trim()) return reject(err || new Error('Empty yt-dlp output'));
            const parts = stdout.trim().split('///');
            resolve({
                title: parts[0] || '',
                author: parts[1] || ''
            });
        });
    });
}

async function getYouTubeMetadata(videoId) {
    if (!videoId) throw new Error('Video ID is required');

    const videoUrl = `https://www.youtube.com/watch?v=${videoId}`;
    const oembedUrl = `https://www.youtube.com/oembed?url=${encodeURIComponent(videoUrl)}&format=json`;

    // 1. Быстрый путь: oEmbed с повторными попытками при сбросе соединения DPI
    for (let attempt = 1; attempt <= 2; attempt++) {
        try {
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 3500);

            const response = await fetch(oembedUrl, {
                signal: controller.signal,
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                }
            });
            clearTimeout(timeoutId);

            if (response.ok) {
                const data = await response.json();
                if (data.title) {
                    return {
                        id: videoId,
                        title: data.title,
                        author: data.author_name || 'YouTube Creator',
                        thumbnail: `https://img.youtube.com/vi/${videoId}/mqdefault.jpg`,
                        thumbnailHigh: `https://img.youtube.com/vi/${videoId}/hqdefault.jpg`,
                        url: videoUrl
                    };
                }
            }
        } catch (err) {
            if (attempt === 1) {
                await new Promise(r => setTimeout(r, 400));
            }
        }
    }

    // 2. Второй эшелон: yt-dlp (умеет обходить замедления и разрывы TLS от РКН/ТСПУ)
    try {
        console.log(`[Metadata] oEmbed не ответил для ${videoId}, запускаем yt-dlp...`);
        const ytdlpMeta = await getMetadataViaYtDlp(videoId);
        if (ytdlpMeta && ytdlpMeta.title) {
            return {
                id: videoId,
                title: ytdlpMeta.title,
                author: ytdlpMeta.author || 'YouTube Creator',
                thumbnail: `https://img.youtube.com/vi/${videoId}/mqdefault.jpg`,
                thumbnailHigh: `https://img.youtube.com/vi/${videoId}/hqdefault.jpg`,
                url: videoUrl
            };
        }
    } catch (e) {
        console.warn(`[Metadata] yt-dlp также не смог получить данные для ${videoId}:`, e.message);
    }

    // 3. Третий эшелон: парсинг HTML-страницы видео
    try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 4000);
        const res = await fetch(videoUrl, {
            signal: controller.signal,
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Accept-Language': 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7'
            }
        });
        clearTimeout(timeoutId);
        if (res.ok) {
            const html = await res.text();
            const titleMatch = html.match(/<title>([^<]+)<\/title>/i);
            if (titleMatch && titleMatch[1]) {
                const cleanTitle = titleMatch[1].replace(/\s*-\s*YouTube$/i, '').trim();
                if (cleanTitle && cleanTitle !== 'YouTube') {
                    return {
                        id: videoId,
                        title: cleanTitle,
                        author: 'YouTube Creator',
                        thumbnail: `https://img.youtube.com/vi/${videoId}/mqdefault.jpg`,
                        thumbnailHigh: `https://img.youtube.com/vi/${videoId}/hqdefault.jpg`,
                        url: videoUrl
                    };
                }
            }
        }
    } catch (e) {}

    // 4. Запасной вариант
    return {
        id: videoId,
        title: `YouTube Video (${videoId})`,
        author: 'Unknown Artist',
        thumbnail: `https://img.youtube.com/vi/${videoId}/mqdefault.jpg`,
        thumbnailHigh: `https://img.youtube.com/vi/${videoId}/hqdefault.jpg`,
        url: videoUrl
    };
}

// Search for a playable alternative when a track has embed/copyright restrictions
async function searchPlayableAlternative(query, originalId) {
    if (!query) return null;

    const cleanQuery = query
        .replace(/\[.*?\]|\(.*?\)/g, '')
        .replace(/[\/\\]/g, ' ')
        .replace(/\b(edit|amv|cinematic|remix|4k|hd|official video|music video)\b/gi, '')
        .trim();

    const searchQuery = cleanQuery.length > 2 ? cleanQuery : query;
    const searchUrl = `https://www.youtube.com/results?search_query=${encodeURIComponent(searchQuery + ' audio')}`;

    try {
        const response = await fetch(searchUrl, {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                'Accept-Language': 'en-US,en;q=0.9,ru;q=0.8'
            }
        });
        const html = await response.text();

        const matches = html.match(/\/watch\?v=([a-zA-Z0-9_-]{11})/g) || [];
        const ids = [...new Set(matches.map(m => m.replace('/watch?v=', '')))];

        const alternativeId = ids.find(id => id !== originalId);
        return alternativeId || null;
    } catch (e) {
        console.error('Failed to search alternative YouTube track:', e.message);
        return null;
    }
}

module.exports = {
    extractYouTubeId,
    getYouTubeMetadata,
    searchPlayableAlternative
};
