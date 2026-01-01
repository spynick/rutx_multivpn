#!/bin/sh
#
# RUTX Multi-VPN Setup Script
# ============================
# Richtet DNS-basiertes Split-Tunneling fuer Streaming ein
#
# Features:
#   - Mehrere WireGuard Tunnel gleichzeitig (DE, CH, AT)
#   - DNS-basiertes Routing (Domain -> ipset -> Tunnel)
#   - Nur Streaming Devices werden geroutet
#   - Management VPN bleibt UNANGETASTET
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

# Streaming Devices (wird vom Provisioning ueberschrieben)
STREAMING_DEVICES="192.168.110.100"

# Routing Tabellen
RT_TABLE_DE=110
RT_TABLE_CH=111
RT_TABLE_AT=112

# Firewall Marks
MARK_DE=0x10
MARK_CH=0x11
MARK_AT=0x12

# Verzeichnisse
SCRIPT_DIR="/root/multivpn"
CONFIG_FILE="$SCRIPT_DIR/config"
DOMAIN_DIR="$SCRIPT_DIR/domains"

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
        # Auch pruefen ob Name mit Pattern beginnt
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

# =============================================================================
# PREFLIGHT CHECKS
# =============================================================================

log "=== RUTX Multi-VPN Setup Start ==="

# Pruefen ob WireGuard verfuegbar
if ! command -v wg >/dev/null 2>&1; then
    error "WireGuard nicht installiert!"
fi

# Pruefen ob ipset verfuegbar
if ! command -v ipset >/dev/null 2>&1; then
    log "ipset nicht gefunden, installiere..."
    opkg update && opkg install ipset
fi

# =============================================================================
# VERZEICHNISSE ERSTELLEN
# =============================================================================

log "Erstelle Verzeichnisse..."
mkdir -p "$SCRIPT_DIR"
mkdir -p "$DOMAIN_DIR"

# =============================================================================
# ROUTING TABELLEN EINRICHTEN
# =============================================================================

log "Richte Routing Tabellen ein..."

# Tabellen in rt_tables eintragen (falls nicht vorhanden)
for entry in "$RT_TABLE_DE vpn_de" "$RT_TABLE_CH vpn_ch" "$RT_TABLE_AT vpn_at"; do
    table_id=$(echo "$entry" | cut -d' ' -f1)
    table_name=$(echo "$entry" | cut -d' ' -f2)
    if ! grep -q "$table_name" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "$table_id $table_name" >> /etc/iproute2/rt_tables
        log "  Routing Tabelle $table_name ($table_id) hinzugefuegt"
    fi
done

# Permissions fuer openvpn/wireguard User
chmod 755 /etc/iproute2
chmod 644 /etc/iproute2/rt_tables

# =============================================================================
# IPSETS ERSTELLEN
# =============================================================================

log "Erstelle ipsets..."

# ipsets fuer jedes Land (hash:ip fuer aufgeloeste IPs)
for country in de ch at; do
    ipset_name="${country}_ips"
    if ! ipset list "$ipset_name" >/dev/null 2>&1; then
        ipset create "$ipset_name" hash:ip timeout 3600
        log "  ipset $ipset_name erstellt"
    else
        log "  ipset $ipset_name existiert bereits"
    fi
done

# =============================================================================
# DNSMASQ KONFIGURATION
# =============================================================================

log "Konfiguriere dnsmasq..."

# dnsmasq ipset Config erstellen
cat > /etc/dnsmasq.d/multivpn-ipset.conf << 'DNSEOF'
# Multi-VPN DNS-basiertes Routing
# Domains werden bei DNS-Aufloesung in ipsets eingetragen

# Deutsche Streaming Dienste -> de_ips
ipset=/ardmediathek.de/daserste.de/ard.de/zdf.de/br.de/wdr.de/ndr.de/swr.de/mdr.de/hr.de/rbb-online.de/arte.tv/arte.de/joyn.de/de_ips
ipset=/rtl.de/rtlplus.de/tvnow.de/prosieben.de/sat1.de/kabeleins.de/sportschau.de/de_ips

# Schweizer Streaming Dienste -> ch_ips
ipset=/srf.ch/play.srf.ch/playsuisse.ch/rts.ch/rsi.ch/rtr.ch/srgssr.ch/ch_ips
ipset=/3plus.tv/tv24.ch/tv25.ch/s1.ch/ch_ips

# Oesterreichische Streaming Dienste -> at_ips
ipset=/orf.at/tvthek.orf.at/servustv.com/atv.at/puls4.com/puls24.at/at_ips
ipset=/krone.at/krone.tv/oe24.at/oe24.tv/at_ips
DNSEOF

log "  dnsmasq ipset Config erstellt"

# dnsmasq neu starten
/etc/init.d/dnsmasq restart
log "  dnsmasq neu gestartet"

# =============================================================================
# VPN SWITCH SCRIPT ERSTELLEN
# =============================================================================

log "Erstelle VPN Control Scripts..."

cat > "$SCRIPT_DIR/vpn-control.sh" << 'VPNEOF'
#!/bin/sh
#
# Multi-VPN Control Script
# Usage: vpn-control.sh [on|off|status]
#

SCRIPT_DIR="/root/multivpn"
CONFIG_FILE="$SCRIPT_DIR/config"

# Lade Config
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

STREAMING_DEVICES="${STREAMING_DEVICES:-192.168.110.100}"

# Marks und Tabellen
MARK_DE=0x10
MARK_CH=0x11
MARK_AT=0x12
RT_TABLE_DE=110
RT_TABLE_CH=111
RT_TABLE_AT=112

case "$1" in
    on)
        echo "Aktiviere Multi-VPN Routing..."

        # IP Rules fuer Marks -> Tabellen
        ip rule del fwmark $MARK_DE table $RT_TABLE_DE 2>/dev/null
        ip rule del fwmark $MARK_CH table $RT_TABLE_CH 2>/dev/null
        ip rule del fwmark $MARK_AT table $RT_TABLE_AT 2>/dev/null

        ip rule add fwmark $MARK_DE table $RT_TABLE_DE priority 100
        ip rule add fwmark $MARK_CH table $RT_TABLE_CH priority 101
        ip rule add fwmark $MARK_AT table $RT_TABLE_AT priority 102

        # WireGuard Interfaces aktivieren
        for iface in SS_DE SS_CH SS_AT; do
            if uci get network.$iface >/dev/null 2>&1; then
                ifup $iface 2>/dev/null || true
            fi
        done

        # Warte auf Tunnel
        sleep 3

        # Default Routes in Tabellen setzen
        for entry in "SS_DE $RT_TABLE_DE" "SS_CH $RT_TABLE_CH" "SS_AT $RT_TABLE_AT"; do
            iface=$(echo "$entry" | cut -d' ' -f1)
            table=$(echo "$entry" | cut -d' ' -f2)

            # Finde Gateway (Peer Endpoint)
            gw=$(wg show "$iface" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1)
            if [ -n "$gw" ]; then
                ip route replace default dev "$iface" table "$table"
            fi
        done

        # iptables Regeln aktivieren
        for IP in $STREAMING_DEVICES; do
            # DE Traffic
            iptables -t mangle -C PREROUTING -s $IP -m set --match-set de_ips dst -j MARK --set-mark $MARK_DE 2>/dev/null || \
            iptables -t mangle -A PREROUTING -s $IP -m set --match-set de_ips dst -j MARK --set-mark $MARK_DE

            # CH Traffic
            iptables -t mangle -C PREROUTING -s $IP -m set --match-set ch_ips dst -j MARK --set-mark $MARK_CH 2>/dev/null || \
            iptables -t mangle -A PREROUTING -s $IP -m set --match-set ch_ips dst -j MARK --set-mark $MARK_CH

            # AT Traffic
            iptables -t mangle -C PREROUTING -s $IP -m set --match-set at_ips dst -j MARK --set-mark $MARK_AT 2>/dev/null || \
            iptables -t mangle -A PREROUTING -s $IP -m set --match-set at_ips dst -j MARK --set-mark $MARK_AT
        done

        echo "Multi-VPN Routing aktiviert"
        ;;

    off)
        echo "Deaktiviere Multi-VPN Routing..."

        # iptables Regeln entfernen
        for IP in $STREAMING_DEVICES; do
            iptables -t mangle -D PREROUTING -s $IP -m set --match-set de_ips dst -j MARK --set-mark $MARK_DE 2>/dev/null
            iptables -t mangle -D PREROUTING -s $IP -m set --match-set ch_ips dst -j MARK --set-mark $MARK_CH 2>/dev/null
            iptables -t mangle -D PREROUTING -s $IP -m set --match-set at_ips dst -j MARK --set-mark $MARK_AT 2>/dev/null
        done

        # IP Rules entfernen
        ip rule del fwmark $MARK_DE table $RT_TABLE_DE 2>/dev/null
        ip rule del fwmark $MARK_CH table $RT_TABLE_CH 2>/dev/null
        ip rule del fwmark $MARK_AT table $RT_TABLE_AT 2>/dev/null

        # WireGuard Interfaces deaktivieren (nur unsere!)
        for iface in SS_DE SS_CH SS_AT; do
            ifdown $iface 2>/dev/null || true
        done

        echo "Multi-VPN Routing deaktiviert"
        ;;

    status)
        # JSON Status ausgeben
        de_up="false"
        ch_up="false"
        at_up="false"

        wg show SS_DE >/dev/null 2>&1 && de_up="true"
        wg show SS_CH >/dev/null 2>&1 && ch_up="true"
        wg show SS_AT >/dev/null 2>&1 && at_up="true"

        # Pruefen ob Routing aktiv
        routing_active="false"
        ip rule show | grep -q "fwmark 0x10" && routing_active="true"

        cat << STATUSEOF
{
  "active": $routing_active,
  "tunnels": {
    "DE": $de_up,
    "CH": $ch_up,
    "AT": $at_up
  },
  "streaming_devices": "$STREAMING_DEVICES",
  "ipset_counts": {
    "de": $(ipset list de_ips 2>/dev/null | grep -c "^[0-9]" || echo 0),
    "ch": $(ipset list ch_ips 2>/dev/null | grep -c "^[0-9]" || echo 0),
    "at": $(ipset list at_ips 2>/dev/null | grep -c "^[0-9]" || echo 0)
  }
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
CONFIG_FILE="$SCRIPT_DIR/config"

# Lade Config
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
STREAMING_DEVICES="${STREAMING_DEVICES:-}"

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
            echo "STREAMING_DEVICES=\"$STREAMING_DEVICES\"" > "$CONFIG_FILE"
            echo "Device $2 hinzugefuegt"
        fi
        ;;
    remove)
        [ -z "$2" ] && echo "Usage: $0 remove <IP>" && exit 1
        STREAMING_DEVICES=$(echo "$STREAMING_DEVICES" | sed "s/$2//g" | xargs)
        echo "STREAMING_DEVICES=\"$STREAMING_DEVICES\"" > "$CONFIG_FILE"
        echo "Device $2 entfernt"
        ;;
    set)
        shift
        STREAMING_DEVICES="$*"
        echo "STREAMING_DEVICES=\"$STREAMING_DEVICES\"" > "$CONFIG_FILE"
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
# CONFIG DATEI ERSTELLEN
# =============================================================================

log "Erstelle Config..."
cat > "$CONFIG_FILE" << CONFEOF
# Multi-VPN Konfiguration
STREAMING_DEVICES="$STREAMING_DEVICES"
CONFEOF

# =============================================================================
# FIREWALL ZONE FUER VPN
# =============================================================================

log "Konfiguriere Firewall..."

# Pruefen ob vpn Zone existiert
if ! uci get firewall.vpn_zone >/dev/null 2>&1; then
    uci set firewall.vpn_zone=zone
    uci set firewall.vpn_zone.name='vpn'
    uci set firewall.vpn_zone.input='REJECT'
    uci set firewall.vpn_zone.output='ACCEPT'
    uci set firewall.vpn_zone.forward='REJECT'
    uci set firewall.vpn_zone.masq='1'
    uci set firewall.vpn_zone.mtu_fix='1'
    uci add_list firewall.vpn_zone.network='SS_DE'
    uci add_list firewall.vpn_zone.network='SS_CH'
    uci add_list firewall.vpn_zone.network='SS_AT'
    uci commit firewall
    log "  VPN Firewall Zone erstellt"
else
    log "  VPN Firewall Zone existiert"
fi

# Forwarding von LAN zu VPN
if ! uci show firewall | grep -q "lan_vpn_forward"; then
    uci set firewall.lan_vpn_forward=forwarding
    uci set firewall.lan_vpn_forward.src='lan'
    uci set firewall.lan_vpn_forward.dest='vpn'
    uci commit firewall
    log "  LAN->VPN Forwarding erstellt"
fi

# =============================================================================
# FERTIG
# =============================================================================

log ""
log "=== Setup abgeschlossen ==="
log ""
log "Naechste Schritte:"
log "  1. WireGuard Configs hochladen (SS_DE, SS_CH, SS_AT)"
log "  2. vpn-control.sh on  - Routing aktivieren"
log "  3. vpn-control.sh off - Routing deaktivieren"
log ""

exit 0
