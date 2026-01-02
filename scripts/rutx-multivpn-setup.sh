#!/bin/sh
#
# RUTX Multi-VPN Setup Script (nslookup-basiert)
# ================================================
# Richtet Split-Tunneling fuer Streaming ein
# OHNE dnsmasq-full - nutzt nslookup + cronjob stattdessen
#
# Features:
#   - Mehrere WireGuard Tunnel gleichzeitig (dynamisch erkannt)
#   - nslookup-basiertes IP-Update (kein dnsmasq-full noetig!)
#   - Nur Streaming Devices werden geroutet
#   - Management VPN bleibt UNANGETASTET
#   - Ueberlebt Firmware Updates (Config in /etc/config/multivpn)
#
# WICHTIG: Folgende WireGuard Interfaces werden NIEMALS angefasst:
#   - WG, MGMT, HOME, VPN (und Varianten)
#

set -e

# =============================================================================
# KONFIGURATION
# =============================================================================

# Geschuetzte WireGuard Namen (NIEMALS anfassen!)
PROTECTED_PATTERNS="WG MGMT HOME VPN wg mgmt home vpn"

# Unser Prefix fuer Streaming Tunnel
TUNNEL_PREFIX="SS"

# Streaming Devices (wird vom Provisioning gesetzt)
STREAMING_DEVICES="${STREAMING_DEVICES:-}"

# Basis fuer Routing Tabellen und Marks (werden dynamisch vergeben)
RT_TABLE_BASE=110
MARK_BASE=16  # 0x10 = 16 dezimal

# Verzeichnisse
SCRIPT_DIR="/root/multivpn"
CONFIG_DIR="/etc/config/multivpn"
CONFIG_FILE="$CONFIG_DIR/config"
DOMAIN_DIR="$SCRIPT_DIR/domains"

# Config laden falls vorhanden (wird von Provisioning erstellt)
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi
# Fallback: Config in SCRIPT_DIR
if [ -f "$SCRIPT_DIR/config" ]; then
    . "$SCRIPT_DIR/config"
fi

# =============================================================================
# FUNKTIONEN
# =============================================================================

log() {
    echo "[$(date '+%H:%M:%S')] $1"
    logger -t multivpn-setup "$1"
}

error() {
    echo "[$(date '+%H:%M:%S')] ERROR: $1" >&2
    logger -t multivpn-setup "ERROR: $1"
    exit 1
}

# Prueft ob ein Name geschuetzt ist
is_protected() {
    local name="$1"
    for pattern in $PROTECTED_PATTERNS; do
        if [ "$name" = "$pattern" ]; then
            return 0  # ist geschuetzt
        fi
        case "$name" in
            ${pattern}*|*${pattern}) return 0 ;;
        esac
    done
    return 1  # nicht geschuetzt
}

# Prueft ob ein WireGuard Interface uns gehoert (SS_ Prefix)
is_our_tunnel() {
    local name="$1"
    case "$name" in
        ${TUNNEL_PREFIX}_*) return 0 ;;
        *) return 1 ;;
    esac
}

# Extrahiert Laendercode aus Interface Name: SS_DE -> de, SS_DE2 -> de
get_country_from_iface() {
    local iface="$1"
    echo "$iface" | sed 's/^SS_//' | sed 's/[0-9]*$//' | tr 'A-Z' 'a-z'
}

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

log "=== RUTX Multi-VPN Setup Start (nslookup-basiert) ==="

# Pruefen ob WireGuard verfuegbar
if ! command -v wg >/dev/null 2>&1; then
    error "WireGuard nicht installiert!"
fi

# Pruefen ob ipset verfuegbar
if ! command -v ipset >/dev/null 2>&1; then
    log "ipset nicht gefunden, installiere..."
    opkg update && opkg install ipset
fi

# nslookup sollte immer verfuegbar sein (BusyBox)
if ! command -v nslookup >/dev/null 2>&1; then
    error "nslookup nicht gefunden!"
fi

# =============================================================================
# VERZEICHNISSE ERSTELLEN
# =============================================================================

log "Erstelle Verzeichnisse..."
mkdir -p "$SCRIPT_DIR"
mkdir -p "$DOMAIN_DIR"
mkdir -p "$CONFIG_DIR"

# =============================================================================
# ROUTING TABELLEN EINRICHTEN
# =============================================================================

log "Richte Routing Tabellen ein..."

# Finde alle unsere SS_* Interfaces und erstelle Routing Tabellen
idx=0
for iface in $(uci show network 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u); do
    if is_our_tunnel "$iface"; then
        country=$(get_country_from_iface "$iface")
        table_id=$((RT_TABLE_BASE + idx))
        table_name="vpn_${country}"

        if ! grep -q "$table_name" /etc/iproute2/rt_tables 2>/dev/null; then
            echo "$table_id $table_name" >> /etc/iproute2/rt_tables
            log "  Routing Tabelle $table_name ($table_id) hinzugefuegt"
        fi
        idx=$((idx + 1))
    fi
done

chmod 755 /etc/iproute2 2>/dev/null || true
chmod 644 /etc/iproute2/rt_tables 2>/dev/null || true

# =============================================================================
# UPDATE-IPS SCRIPT ERSTELLEN (nslookup-basiert)
# =============================================================================

log "Erstelle IP-Update Script..."

cat > "$SCRIPT_DIR/update-ips.sh" << 'UPDATEEOF'
#!/bin/sh
#
# RUTX Multi-VPN IP Update Script
# ================================
# Loest Streaming-Hostnames per nslookup auf und fuellt ipsets
# Braucht KEIN dnsmasq-full!
#
# Verwendung:
#   /root/multivpn/update-ips.sh          # Alle Laender
#   /root/multivpn/update-ips.sh de       # Nur Deutschland
#
# Cronjob: 0 */4 * * * /root/multivpn/update-ips.sh
#

SCRIPT_DIR="/root/multivpn"
DOMAINS_DIR="$SCRIPT_DIR/domains"
LOG_TAG="multivpn-ipupdate"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%H:%M:%S')] $1"
}

# DNS Lookup - gibt alle IPs fuer einen Hostname zurueck
resolve_host() {
    local host="$1"
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

    # ipset erstellen falls nicht vorhanden (24h timeout)
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
    COUNTRIES="de ch at"
else
    COUNTRIES="$*"
fi

for country in $COUNTRIES; do
    update_country "$country"
done

log "=== IP Update Ende ==="
exit 0
UPDATEEOF

chmod +x "$SCRIPT_DIR/update-ips.sh"
log "  update-ips.sh erstellt"

# =============================================================================
# VPN CONTROL SCRIPT ERSTELLEN
# =============================================================================

log "Erstelle VPN Control Script..."

cat > "$SCRIPT_DIR/vpn-control.sh" << 'VPNEOF'
#!/bin/sh
#
# Multi-VPN Control Script
# Usage: vpn-control.sh [on|off|status]
#

SCRIPT_DIR="/root/multivpn"
CONFIG_DIR="/etc/config/multivpn"
CONFIG_FILE="$CONFIG_DIR/config"
TUNNEL_PREFIX="SS"
RT_TABLE_BASE=110
MARK_BASE=16

# Lade Config
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
[ -f "$SCRIPT_DIR/config" ] && . "$SCRIPT_DIR/config"

if [ -z "$STREAMING_DEVICES" ]; then
    echo "WARNUNG: Keine STREAMING_DEVICES konfiguriert!"
fi

get_country_from_iface() {
    echo "$1" | sed 's/^SS_//' | sed 's/[0-9]*$//' | tr 'A-Z' 'a-z'
}

get_our_interfaces() {
    uci show network 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | grep "^${TUNNEL_PREFIX}_" | sort -u
}

get_all_countries() {
    for iface in $(get_our_interfaces); do
        get_country_from_iface "$iface"
    done | sort -u
}

get_table_for_country() {
    case "$1" in
        at) echo $((RT_TABLE_BASE + 0)) ;;
        ch) echo $((RT_TABLE_BASE + 1)) ;;
        de) echo $((RT_TABLE_BASE + 2)) ;;
        *)  echo $RT_TABLE_BASE ;;
    esac
}

get_mark_for_country() {
    case "$1" in
        at) printf "0x%x" $((MARK_BASE + 0)) ;;
        ch) printf "0x%x" $((MARK_BASE + 1)) ;;
        de) printf "0x%x" $((MARK_BASE + 2)) ;;
        *)  printf "0x%x" $MARK_BASE ;;
    esac
}

get_mark_dec_for_country() {
    case "$1" in
        at) echo $((MARK_BASE + 0)) ;;
        ch) echo $((MARK_BASE + 1)) ;;
        de) echo $((MARK_BASE + 2)) ;;
        *)  echo $MARK_BASE ;;
    esac
}

get_iface_for_country() {
    local country_upper=$(echo "$1" | tr 'a-z' 'A-Z')
    echo "${TUNNEL_PREFIX}_${country_upper}"
}

case "$1" in
    on)
        echo "Aktiviere Multi-VPN Routing..."

        countries=$(get_all_countries)

        # ipsets erstellen (24h timeout)
        echo "  Erstelle ipsets..."
        for country in $countries; do
            ipset_name="${country}_ips"
            if ! ipset list "$ipset_name" >/dev/null 2>&1; then
                ipset create "$ipset_name" hash:ip timeout 86400
                echo "    ipset $ipset_name erstellt"
            fi
        done

        # IPs per nslookup auffuellen
        echo "  Fuehre IP-Update aus..."
        $SCRIPT_DIR/update-ips.sh

        # IP Rules
        for country in $countries; do
            table=$(get_table_for_country "$country")
            mark=$(get_mark_for_country "$country")
            ip rule del fwmark $mark table $table 2>/dev/null || true
            ip rule add fwmark $mark table $table priority $table
            echo "  Rule: $country mark=$mark -> table=$table"
        done

        # WireGuard aktivieren
        for iface in $(get_our_interfaces); do
            echo "  Aktiviere: $iface"
            ifup "$iface" 2>/dev/null || true
        done

        sleep 3

        # Routes setzen
        for country in $countries; do
            table=$(get_table_for_country "$country")
            for iface in $(get_our_interfaces); do
                iface_country=$(get_country_from_iface "$iface")
                if [ "$iface_country" = "$country" ]; then
                    if wg show "$iface" >/dev/null 2>&1; then
                        ip route replace default dev "$iface" table "$table"
                        echo "  Route: table $table -> $iface"
                    fi
                    break
                fi
            done
        done

        # FORWARD Regeln
        echo "  Erstelle FORWARD Regeln..."
        for country in $countries; do
            mark_dec=$(get_mark_dec_for_country "$country")
            iface=$(get_iface_for_country "$country")
            if ! iptables -C FORWARD -i br-lan -o "$iface" -m mark --mark $mark_dec -j ACCEPT 2>/dev/null; then
                iptables -I FORWARD -i br-lan -o "$iface" -m mark --mark $mark_dec -j ACCEPT
                echo "    FORWARD br-lan -> $iface (mark $mark_dec)"
            fi
        done

        # iptables MARK Regeln
        echo "  Erstelle iptables MARK Regeln..."
        for IP in $STREAMING_DEVICES; do
            for country in $countries; do
                ipset_name="${country}_ips"
                mark=$(get_mark_for_country "$country")
                if ipset list "$ipset_name" >/dev/null 2>&1; then
                    iptables -t mangle -C PREROUTING -s $IP -m set --match-set $ipset_name dst -j MARK --set-mark $mark 2>/dev/null || \
                    iptables -t mangle -A PREROUTING -s $IP -m set --match-set $ipset_name dst -j MARK --set-mark $mark
                fi
            done
        done

        echo "Multi-VPN Routing aktiviert"
        ;;

    off)
        echo "Deaktiviere Multi-VPN Routing..."

        countries=$(get_all_countries)

        # FORWARD Regeln entfernen
        for country in $countries; do
            mark_dec=$(get_mark_dec_for_country "$country")
            iface=$(get_iface_for_country "$country")
            iptables -D FORWARD -i br-lan -o "$iface" -m mark --mark $mark_dec -j ACCEPT 2>/dev/null || true
        done

        # iptables MARK entfernen
        for IP in $STREAMING_DEVICES; do
            for country in $countries; do
                ipset_name="${country}_ips"
                mark=$(get_mark_for_country "$country")
                iptables -t mangle -D PREROUTING -s $IP -m set --match-set $ipset_name dst -j MARK --set-mark $mark 2>/dev/null || true
            done
        done

        # IP Rules entfernen
        for country in $countries; do
            table=$(get_table_for_country "$country")
            mark=$(get_mark_for_country "$country")
            ip rule del fwmark $mark table $table 2>/dev/null || true
        done

        # WireGuard deaktivieren
        for iface in $(get_our_interfaces); do
            echo "  Deaktiviere: $iface"
            ifdown "$iface" 2>/dev/null || true
        done

        echo "Multi-VPN Routing deaktiviert"
        ;;

    status)
        tunnels_json="{"
        first=1
        for iface in $(get_our_interfaces); do
            country=$(get_country_from_iface "$iface" | tr 'a-z' 'A-Z')
            up="false"
            wg show "$iface" >/dev/null 2>&1 && up="true"
            [ $first -eq 1 ] && first=0 || tunnels_json="$tunnels_json,"
            tunnels_json="$tunnels_json\"$iface\":$up"
        done
        tunnels_json="$tunnels_json}"

        ipset_json="{"
        first=1
        for iface in $(get_our_interfaces); do
            country=$(get_country_from_iface "$iface")
            ipset_name="${country}_ips"
            count=$(ipset list "$ipset_name" 2>/dev/null | grep -c "^[0-9]" || echo 0)
            if ! echo "$ipset_json" | grep -q "\"$country\""; then
                [ $first -eq 1 ] && first=0 || ipset_json="$ipset_json,"
                ipset_json="$ipset_json\"$country\":$count"
            fi
        done
        ipset_json="$ipset_json}"

        routing_active="false"
        ip rule show | grep -q "fwmark 0x1" && routing_active="true"

        cat << STATUSEOF
{
  "active": $routing_active,
  "tunnels": $tunnels_json,
  "streaming_devices": "$STREAMING_DEVICES",
  "ipset_counts": $ipset_json
}
STATUSEOF
        ;;

    *)
        echo "Usage: $0 {on|off|status}"
        exit 1
        ;;
esac
VPNEOF

chmod +x "$SCRIPT_DIR/vpn-control.sh"
log "  vpn-control.sh erstellt"

# =============================================================================
# DEVICE MANAGEMENT SCRIPT
# =============================================================================

cat > "$SCRIPT_DIR/manage-devices.sh" << 'DEVEOF'
#!/bin/sh
#
# Streaming Device Management
# Usage: manage-devices.sh [list|add|remove|set] [IP]
#

SCRIPT_DIR="/root/multivpn"
CONFIG_DIR="/etc/config/multivpn"
CONFIG_FILE="$CONFIG_DIR/config"

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
[ -f "$SCRIPT_DIR/config" ] && . "$SCRIPT_DIR/config"
STREAMING_DEVICES="${STREAMING_DEVICES:-}"

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
# Multi-VPN Konfiguration (persistent)
STREAMING_DEVICES="$STREAMING_DEVICES"
EOF
    # Auch nach SCRIPT_DIR kopieren
    cp "$CONFIG_FILE" "$SCRIPT_DIR/config" 2>/dev/null || true
}

case "$1" in
    list)
        echo "Streaming Devices: $STREAMING_DEVICES"
        ;;
    add)
        [ -z "$2" ] && echo "Usage: $0 add <IP>" && exit 1
        if echo "$STREAMING_DEVICES" | grep -q "$2"; then
            echo "Device $2 bereits vorhanden"
        else
            STREAMING_DEVICES="$STREAMING_DEVICES $2"
            STREAMING_DEVICES=$(echo "$STREAMING_DEVICES" | xargs)
            save_config
            echo "Device $2 hinzugefuegt"
        fi
        ;;
    remove)
        [ -z "$2" ] && echo "Usage: $0 remove <IP>" && exit 1
        STREAMING_DEVICES=$(echo "$STREAMING_DEVICES" | sed "s/$2//g" | xargs)
        save_config
        echo "Device $2 entfernt"
        ;;
    set)
        shift
        STREAMING_DEVICES="$*"
        save_config
        echo "Devices gesetzt: $STREAMING_DEVICES"
        ;;
    *)
        echo "Usage: $0 {list|add|remove|set} [IP]"
        ;;
esac
DEVEOF

chmod +x "$SCRIPT_DIR/manage-devices.sh"
log "  manage-devices.sh erstellt"

# =============================================================================
# FIREWALL ZONE FUER VPN
# =============================================================================

log "Konfiguriere Firewall..."

our_interfaces=""
for iface in $(uci show network 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u); do
    if is_our_tunnel "$iface"; then
        our_interfaces="$our_interfaces $iface"
    fi
done

if ! uci get firewall.vpn_zone >/dev/null 2>&1; then
    uci set firewall.vpn_zone=zone
    uci set firewall.vpn_zone.name='vpn'
    uci set firewall.vpn_zone.input='REJECT'
    uci set firewall.vpn_zone.output='ACCEPT'
    uci set firewall.vpn_zone.forward='REJECT'
    uci set firewall.vpn_zone.masq='1'
    uci set firewall.vpn_zone.mtu_fix='1'

    for iface in $our_interfaces; do
        uci add_list firewall.vpn_zone.network="$iface"
    done

    uci commit firewall
    log "  VPN Firewall Zone erstellt mit: $our_interfaces"
else
    log "  VPN Firewall Zone existiert"
fi

if ! uci show firewall | grep -q "lan_vpn_forward"; then
    uci set firewall.lan_vpn_forward=forwarding
    uci set firewall.lan_vpn_forward.src='lan'
    uci set firewall.lan_vpn_forward.dest='vpn'
    uci commit firewall
    log "  LAN->VPN Forwarding erstellt"
fi

# =============================================================================
# CRONJOB FUER IP-UPDATE
# =============================================================================

log "Konfiguriere Cronjob fuer IP-Updates..."

CRON_ENTRY="0 */4 * * * /root/multivpn/update-ips.sh"

# Cronjob hinzufuegen falls nicht vorhanden
if ! crontab -l 2>/dev/null | grep -q "update-ips.sh"; then
    (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
    log "  Cronjob hinzugefuegt (alle 4 Stunden)"
else
    log "  Cronjob bereits vorhanden"
fi

# =============================================================================
# RC.LOCAL AUTOSTART
# =============================================================================

log "Konfiguriere Autostart..."

RC_LOCAL_ENTRY="/root/multivpn/vpn-control.sh on"

if [ -f /etc/rc.local ]; then
    if ! grep -q "multivpn/vpn-control.sh" /etc/rc.local; then
        sed -i "/^exit 0/i # Multi-VPN Autostart\n$RC_LOCAL_ENTRY\n" /etc/rc.local
        log "  rc.local Autostart hinzugefuegt"
    else
        log "  rc.local Autostart bereits vorhanden"
    fi
else
    cat > /etc/rc.local << 'RCEOF'
#!/bin/sh
# rc.local

# Multi-VPN Autostart
/root/multivpn/vpn-control.sh on

exit 0
RCEOF
    chmod +x /etc/rc.local
    log "  rc.local erstellt mit Autostart"
fi

# =============================================================================
# CONFIG SPEICHERN
# =============================================================================

log "Speichere Config..."

if [ -n "$STREAMING_DEVICES" ]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << CONFEOF
# Multi-VPN Konfiguration (persistent)
STREAMING_DEVICES="$STREAMING_DEVICES"
CONFEOF
    cp "$CONFIG_FILE" "$SCRIPT_DIR/config" 2>/dev/null || true
    log "  Config gespeichert in $CONFIG_FILE"
fi

# =============================================================================
# FERTIG
# =============================================================================

log ""
log "=== Setup abgeschlossen ==="
log ""
log "Gefundene Tunnel:"
for iface in $our_interfaces; do
    country=$(get_country_from_iface "$iface")
    log "  - $iface ($country)"
done
log ""
log "KEIN dnsmasq-full noetig!"
log "IPs werden per nslookup aufgeloest (Cronjob alle 4h)"
log ""
log "Config Verzeichnis: $CONFIG_DIR (ueberlebt Firmware Updates)"
log ""
log "Naechste Schritte:"
log "  1. vpn-control.sh on  - Routing aktivieren"
log "  2. vpn-control.sh off - Routing deaktivieren"
log "  3. vpn-control.sh status - Status anzeigen"
log "  4. update-ips.sh      - IPs manuell aktualisieren"
log ""
log "Autostart: VPN Routing wird nach Reboot automatisch aktiviert"
log ""

exit 0
