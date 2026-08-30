#!/usr/bin/env bash
# DuckDNS DNS-01 Authenticator Hook for Certbot
CONFIG_FILE="/opt/musicplayer/config.json"
TOKEN=""

if [ -f "$CONFIG_FILE" ]; then
    TOKEN=$(grep -o '"duckdnsToken": "[^"]*' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
fi

if [ -z "$TOKEN" ] && [ -n "$DUCKDNS_TOKEN" ]; then
    TOKEN="$DUCKDNS_TOKEN"
fi

if [ -z "$TOKEN" ]; then
    echo "ERROR: DuckDNS Token not found in $CONFIG_FILE" >&2
    exit 1
fi

SUBDOMAIN=$(echo "$CERTBOT_DOMAIN" | sed 's/\.duckdns\.org//')

# Set TXT record on DuckDNS
curl -s "https://www.duckdns.org/update?domains=${SUBDOMAIN}&token=${TOKEN}&txt=${CERTBOT_VALIDATION}" >/dev/null

# Wait for DuckDNS DNS propagation (30s is recommended by DuckDNS)
sleep 30
