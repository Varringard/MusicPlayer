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

async function getYouTubeMetadata(videoId) {
    if (!videoId) throw new Error('Video ID is required');

    const videoUrl = `https://www.youtube.com/watch?v=${videoId}`;
    const oembedUrl = `https://www.youtube.com/oembed?url=${encodeURIComponent(videoUrl)}&format=json`;

    try {
        const response = await fetch(oembedUrl, {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            }
        });

        if (!response.ok) {
            throw new Error(`YouTube responded with ${response.status}`);
        }

        const data = await response.json();

        return {
            id: videoId,
            title: data.title || 'YouTube Track',
            author: data.author_name || 'YouTube Creator',
            thumbnail: `https://img.youtube.com/vi/${videoId}/mqdefault.jpg`,
            thumbnailHigh: `https://img.youtube.com/vi/${videoId}/hqdefault.jpg`,
            url: videoUrl
        };
    } catch (err) {
        console.warn(`[YouTube oEmbed] Failed to get metadata for ${videoId}:`, err.message);
        return {
            id: videoId,
            title: `YouTube Video (${videoId})`,
            author: 'Unknown Artist',
            thumbnail: `https://img.youtube.com/vi/${videoId}/mqdefault.jpg`,
            thumbnailHigh: `https://img.youtube.com/vi/${videoId}/hqdefault.jpg`,
            url: videoUrl
        };
    }
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
