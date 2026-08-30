#!/usr/bin/env bash
# DuckDNS DNS-01 Cleanup Hook for Certbot
CONFIG_FILE="/opt/musicplayer/config.json"
TOKEN=""

if [ -f "$CONFIG_FILE" ]; then
    TOKEN=$(grep -o '"duckdnsToken": "[^"]*' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
fi

if [ -z "$TOKEN" ] && [ -n "$DUCKDNS_TOKEN" ]; then
    TOKEN="$DUCKDNS_TOKEN"
fi

if [ -n "$TOKEN" ]; then
    SUBDOMAIN=$(echo "$CERTBOT_DOMAIN" | sed 's/\.duckdns\.org//')
    curl -s "https://www.duckdns.org/update?domains=${SUBDOMAIN}&token=${TOKEN}&clear=true" >/dev/null
fi
