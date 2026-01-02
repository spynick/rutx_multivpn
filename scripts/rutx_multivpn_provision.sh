#!/bin/bash
#
# RUTX Multi-VPN Provisioning Script
# ====================================
# Richtet DNS-basiertes Multi-Tunnel Split-Tunneling ein
#
# Features:
#   - Mehrere WireGuard Tunnel gleichzeitig (DE, CH, AT)
#   - DNS-basiertes Routing (Domain -> ipset -> Tunnel)
#   - Nur Streaming Devices werden geroutet
#   - Management VPN (WG/MGMT/HOME/VPN) wird NIEMALS angefasst
#
# Dateinamen-Konvention: wg_<LAND>_<provider>.conf
#   Beispiel: wg_DE_surfshark.conf -> SS_DE
#
# Verwendung:
#   RUTX_HOST=192.168.110.1 ./rutx_multivpn_provision.sh
#

set -e

# =============================================================================
# KONFIGURATION
# =============================================================================

# Pfade
SCRIPT_DIR="/config/packages/rutx_multivpn"
PROFILES_DIR="$SCRIPT_DIR/profiles"
DOMAINS_DIR="$SCRIPT_DIR/domains"
SETUP_SCRIPT="$SCRIPT_DIR/scripts/rutx-multivpn-setup.sh"

# RUTX Verbindung
RUTX_HOST="${RUTX_HOST:-192.168.110.1}"
RUTX_USER="${RUTX_USER:-root}"

# RUTX Host in Datei speichern (fuer command_line sensor)
echo "$RUTX_HOST" > /config/.rutx_multivpn_host

# Streaming Devices (muss als Umgebungsvariable gesetzt werden!)
if [ -z "$STREAMING_DEVICES" ]; then
    error "STREAMING_DEVICES nicht gesetzt! Beispiel: STREAMING_DEVICES=192.168.1.100"
fi

# SSH Optionen
SSH_KEY="${SSH_KEY:-/config/.ssh/id_rsa}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# HA API Token (Long-Lived Access Token "RUTX-VPN")
# Token wird aus Datei gelesen, Fallback auf SUPERVISOR_TOKEN
HA_API_TOKEN_FILE="/config/.ha_api_token"
if [ -f "$HA_API_TOKEN_FILE" ]; then
    HA_API_TOKEN=$(cat "$HA_API_TOKEN_FILE")
elif [ -n "$SUPERVISOR_TOKEN" ]; then
    HA_API_TOKEN="$SUPERVISOR_TOKEN"
else
    HA_API_TOKEN=""
fi

# HA API URL (lokal in HA)
HA_API_URL="http://supervisor/core/api"

# Unser Tunnel Prefix (Streaming = SS)
TUNNEL_PREFIX="SS"

# =============================================================================
# FUNKTIONEN
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Notification bei Fehler senden
send_error_notification() {
    local message="$1"

    # Ohne Token keine Notification
    [ -z "$HA_API_TOKEN" ] && return 0

    message=$(echo "$message" | sed 's/"/\\"/g')

    curl -s -X POST \
        -H "Authorization: Bearer ${HA_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Multi-VPN Setup fehlgeschlagen\", \"message\": \"$message\", \"notification_id\": \"multivpn_provision\"}" \
        "${HA_API_URL}/services/persistent_notification/create" \
        >/dev/null 2>&1
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    send_error_notification "$1"
    exit 1
}

ssh_cmd() {
    ssh $SSH_OPTS ${RUTX_USER}@${RUTX_HOST} "$1"
}

scp_file() {
    scp $SSH_OPTS "$1" ${RUTX_USER}@${RUTX_HOST}:"$2"
}

# Extrahiert Land aus Dateiname: wg_DE_surfshark.conf -> DE
get_country_code() {
    local filename=$(basename "$1")
    echo "$filename" | sed -n 's/^wg_\([^_]*\)_.*/\1/p'
}

# Erstellt Interface Name: DE -> SS_DE
get_interface_name() {
    local country="$1"
    echo "${TUNNEL_PREFIX}_${country}"
}

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

log "=== RUTX Multi-VPN Provisioning Start ==="

# SSH Verbindung testen
log "Teste SSH Verbindung zu $RUTX_HOST..."
if ! ssh_cmd "echo OK" >/dev/null 2>&1; then
    error "SSH Verbindung zu $RUTX_HOST fehlgeschlagen. Ist der SSH Key eingerichtet?"
fi
log "SSH Verbindung OK"

# Pruefen ob .conf Dateien vorhanden
if [ ! -d "$PROFILES_DIR" ] || [ -z "$(ls -A $PROFILES_DIR/wg_*.conf 2>/dev/null)" ]; then
    error "Keine .conf Dateien mit korrekter Namenskonvention (wg_<LAND>_<provider>.conf) in $PROFILES_DIR gefunden"
fi

# Profile sammeln
PROFILE_LIST=""
PROFILE_COUNT=0
for conf_file in $PROFILES_DIR/wg_*.conf; do
    country=$(get_country_code "$conf_file")
    if [ -n "$country" ]; then
        # Nur ein Profil pro Land (erstes gefundenes)
        if ! echo "$PROFILE_LIST" | grep -q "$country"; then
            PROFILE_LIST="$PROFILE_LIST $country"
            PROFILE_COUNT=$((PROFILE_COUNT + 1))
        fi
    fi
done

log "Gefundene Laender ($PROFILE_COUNT):$PROFILE_LIST"

# Pruefen ob Setup Script vorhanden
if [ ! -f "$SETUP_SCRIPT" ]; then
    error "Setup Script nicht gefunden: $SETUP_SCRIPT"
fi

# =============================================================================
# SCHRITT 1: Verzeichnisse erstellen
# =============================================================================

log "=== Schritt 1: Verzeichnisse auf RUTX erstellen ==="

ssh_cmd "mkdir -p /root/multivpn /root/multivpn/domains"
log "Verzeichnisse erstellt"

# =============================================================================
# SCHRITT 2: WireGuard Configs hochladen und UCI konfigurieren
# =============================================================================

log "=== Schritt 2: WireGuard Profile hochladen und konfigurieren ==="

for country in $PROFILE_LIST; do
    # Erstes passendes Profil fuer dieses Land finden
    conf_file=$(ls $PROFILES_DIR/wg_${country}_*.conf 2>/dev/null | head -1)

    if [ -z "$conf_file" ]; then
        log "  WARNUNG: Kein Profil fuer $country gefunden"
        continue
    fi

    filename=$(basename "$conf_file")
    iface_name=$(get_interface_name "$country")

    log "  Uploading: $filename -> $iface_name"

    # Config hochladen
    scp_file "$conf_file" "/root/multivpn/${filename}"

    # WireGuard Config parsen (sed statt cut um = am Ende zu erhalten)
    PRIVATE_KEY=$(grep "^PrivateKey" "$conf_file" | sed 's/^PrivateKey *= *//' | tr -d ' ')
    ADDRESS=$(grep "^Address" "$conf_file" | sed 's/^Address *= *//' | tr -d ' ')
    PUBLIC_KEY=$(grep "^PublicKey" "$conf_file" | sed 's/^PublicKey *= *//' | tr -d ' ')
    ENDPOINT=$(grep "^Endpoint" "$conf_file" | sed 's/^Endpoint *= *//' | tr -d ' ')
    ENDPOINT_HOST=$(echo "$ENDPOINT" | cut -d':' -f1)
    ENDPOINT_PORT=$(echo "$ENDPOINT" | cut -d':' -f2)

    log "    Endpoint: $ENDPOINT_HOST:$ENDPOINT_PORT"

    # UCI Interface konfigurieren
    ssh_cmd "
        # Altes Interface loeschen falls vorhanden
        uci delete network.${iface_name} 2>/dev/null || true

        # Alle Peers fuer dieses Interface loeschen (anonyme Sections)
        while uci -q get network.@wireguard_${iface_name}[0] >/dev/null 2>&1; do
            uci delete network.@wireguard_${iface_name}[0]
        done

        # WireGuard Interface anlegen
        uci set network.${iface_name}=interface
        uci set network.${iface_name}.proto='wireguard'
        uci set network.${iface_name}.private_key='${PRIVATE_KEY}'
        uci add_list network.${iface_name}.addresses='${ADDRESS}'
        uci set network.${iface_name}.auto='0'

        # Peer als anonyme Section anlegen
        uci add network wireguard_${iface_name}
        uci set network.@wireguard_${iface_name}[-1].public_key='${PUBLIC_KEY}'
        uci set network.@wireguard_${iface_name}[-1].endpoint_host='${ENDPOINT_HOST}'
        uci set network.@wireguard_${iface_name}[-1].endpoint_port='${ENDPOINT_PORT}'
        uci add_list network.@wireguard_${iface_name}[-1].allowed_ips='0.0.0.0/0'
        uci set network.@wireguard_${iface_name}[-1].persistent_keepalive='25'
        uci set network.@wireguard_${iface_name}[-1].route_allowed_ips='0'
    "

    log "    UCI konfiguriert"
done

ssh_cmd "uci commit network"
log "Network Config gespeichert"

# =============================================================================
# SCHRITT 3: Domain Listen hochladen
# =============================================================================

log "=== Schritt 3: Domain Listen hochladen ==="

if [ -d "$DOMAINS_DIR" ]; then
    for domain_file in $DOMAINS_DIR/*.txt; do
        if [ -f "$domain_file" ]; then
            filename=$(basename "$domain_file")
            log "  Uploading: $filename"
            scp_file "$domain_file" "/root/multivpn/domains/${filename}"
        fi
    done
    log "Domain Listen hochgeladen"
else
    log "Keine Domain Listen gefunden (optional)"
fi

# =============================================================================
# SCHRITT 4: Setup Script hochladen und ausfuehren
# =============================================================================

log "=== Schritt 4: Setup Script hochladen und ausfuehren ==="

# Setup Script hochladen
scp_file "$SETUP_SCRIPT" "/root/multivpn/setup.sh"

# Config mit Streaming Devices erstellen
ssh_cmd "echo 'STREAMING_DEVICES=\"$STREAMING_DEVICES\"' > /root/multivpn/config"
log "Config mit STREAMING_DEVICES=$STREAMING_DEVICES erstellt"

log "Fuehre Setup Script aus..."
ssh_cmd "chmod +x /root/multivpn/setup.sh && sh /root/multivpn/setup.sh"

# =============================================================================
# SCHRITT 5: Network und Firewall neu laden
# =============================================================================

log "=== Schritt 5: Network und Firewall neu laden ==="

ssh_cmd "
    /etc/init.d/network reload
    sleep 2
    /etc/init.d/firewall reload
"
log "Network und Firewall neu geladen"

# =============================================================================
# FERTIG
# =============================================================================

log ""
log "=== Provisioning abgeschlossen! ==="
log ""
log "Konfigurierte Tunnel:"
TUNNEL_LIST=""
for country in $PROFILE_LIST; do
    iface_name=$(get_interface_name "$country")
    log "  - $iface_name ($country)"
    TUNNEL_LIST="$TUNNEL_LIST$iface_name, "
done
TUNNEL_LIST=$(echo "$TUNNEL_LIST" | sed 's/, $//')
log ""
log "Naechste Schritte:"
log "  1. In Home Assistant: Multi-VPN aktivieren"
log "  2. vpn-control.sh on  - Routing aktivieren"
log "  3. vpn-control.sh off - Routing deaktivieren"
log ""

# =============================================================================
# HA Notification senden
# =============================================================================

send_notification() {
    local title="$1"
    local message="$2"
    local notification_id="${3:-multivpn_provision}"

    # Ohne Token keine Notification
    [ -z "$HA_API_TOKEN" ] && return 0

    message=$(echo "$message" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')

    curl -s -X POST \
        -H "Authorization: Bearer ${HA_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"$title\", \"message\": \"$message\", \"notification_id\": \"$notification_id\"}" \
        "${HA_API_URL}/services/persistent_notification/create" \
        >/dev/null 2>&1
}

NOTIFY_MSG="**Tunnel:** $TUNNEL_LIST\n\n**Streaming Devices:** $STREAMING_DEVICES\n\nMulti-VPN kann jetzt aktiviert werden."
send_notification "Multi-VPN Setup erfolgreich" "$NOTIFY_MSG" "multivpn_provision"

exit 0
