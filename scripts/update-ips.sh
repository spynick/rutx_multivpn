#!/bin/sh
#
# RUTX Multi-VPN IP Update Script
# ================================
# Loest Streaming-Hostnames per nslookup auf und fuellt ipsets
#
# Braucht KEIN dnsmasq-full - nur Standard-Tools!
#
# Verwendung:
#   /root/multivpn/update-ips.sh          # Alle Laender
#   /root/multivpn/update-ips.sh de       # Nur Deutschland
#   /root/multivpn/update-ips.sh ch at    # Schweiz + Oesterreich
#
# Cronjob (alle 4 Stunden):
#   0 */4 * * * /root/multivpn/update-ips.sh
#

SCRIPT_DIR="/root/multivpn"
DOMAINS_DIR="$SCRIPT_DIR/domains"
LOG_TAG="multivpn-ipupdate"

# Logging
log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%H:%M:%S')] $1"
}

# DNS Lookup - gibt alle IPs fuer einen Hostname zurueck
resolve_host() {
    local host="$1"
    # nslookup parsen, nur IPv4 Adressen extrahieren
    nslookup "$host" 2>/dev/null | \
        grep -E "^Address:" | \
        tail -n +2 | \
        awk '{print $2}' | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# Hostnames aus Datei lesen (ignoriert Kommentare und leere Zeilen)
get_hosts_from_file() {
    local file="$1"
    if [ -f "$file" ]; then
        grep -v '^#' "$file" | grep -v '^$' | tr -d ' '
    fi
}

# IPs fuer ein Land updaten
update_country() {
    local country="$1"
    local country_lower=$(echo "$country" | tr 'A-Z' 'a-z')
    local ipset_name="${country_lower}_ips"
    local domain_file="$DOMAINS_DIR/${country_lower}_streaming.txt"

    if [ ! -f "$domain_file" ]; then
        log "WARNUNG: Domain-Datei nicht gefunden: $domain_file"
        return 1
    fi

    # ipset erstellen falls nicht vorhanden
    if ! ipset list "$ipset_name" >/dev/null 2>&1; then
        ipset create "$ipset_name" hash:ip timeout 86400
        log "ipset $ipset_name erstellt"
    fi

    local host_count=0
    local ip_count=0

    for host in $(get_hosts_from_file "$domain_file"); do
        host_count=$((host_count + 1))
        for ip in $(resolve_host "$host"); do
            ipset add "$ipset_name" "$ip" -exist 2>/dev/null
            ip_count=$((ip_count + 1))
        done
    done

    log "$country: $host_count Hosts aufgeloest, $ip_count IPs in $ipset_name"
}

# Hauptprogramm
log "=== IP Update Start ==="

# Welche Laender?
if [ $# -eq 0 ]; then
    # Alle Laender
    COUNTRIES="de ch at"
else
    COUNTRIES="$*"
fi

for country in $COUNTRIES; do
    update_country "$country"
done

log "=== IP Update Ende ==="

exit 0
