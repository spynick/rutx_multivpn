#!/bin/sh
#
# RUTX Multi-VPN Setup Script
# ============================
# Richtet DNS-basiertes Split-Tunneling fuer Streaming ein
#
# Features:
#   - Mehrere WireGuard Tunnel gleichzeitig (dynamisch erkannt)
#   - DNS-basiertes Routing (Domain -> ipset -> Tunnel)
#   - Nur Streaming Devices werden geroutet
#   - Management VPN bleibt UNANGETASTET
#   - Automatische dnsmasq-full Installation (mit ipset Support)
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

# Basis fuer Routing Tabellen und Marks (werden dynamisch vergeben)
RT_TABLE_BASE=110
MARK_BASE=16  # 0x10 = 16 dezimal

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

# Extrahiert Laendercode aus Interface Name: SS_DE -> de, SS_DE2 -> de
get_country_from_iface() {
    local iface="$1"
    # Entferne SS_ prefix und trailing Ziffern
    echo "$iface" | sed 's/^SS_//' | sed 's/[0-9]*$//' | tr '[:upper:]' '[:lower:]'
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
# DNSMASQ-FULL INSTALLATION (mit ipset Support)
# =============================================================================

log "Pruefe dnsmasq ipset Support..."

# Pruefen ob dnsmasq ipset unterstuetzt (--version zeigt compile options)
if dnsmasq --version 2>&1 | grep -q "no-ipset"; then
    log "  dnsmasq hat KEINEN ipset Support, installiere dnsmasq-full..."

    # Backup der aktuellen dnsmasq config
    cp /etc/config/dhcp /etc/config/dhcp.backup 2>/dev/null || true

    # OpenWRT Repo hinzufuegen falls nicht vorhanden
    if ! grep -q "openwrt_base" /etc/opkg/customfeeds.conf 2>/dev/null; then
        log "  Fuege OpenWRT Repository hinzu..."
        echo "src/gz openwrt_base https://downloads.openwrt.org/releases/21.02.0/packages/arm_cortex-a7_neon-vfpv4/base" >> /etc/opkg/customfeeds.conf
    fi

    # Paketlisten aktualisieren
    log "  Aktualisiere Paketlisten..."
    opkg update

    # dnsmasq entfernen und dnsmasq-full installieren
    log "  Ersetze dnsmasq durch dnsmasq-full..."
    opkg remove dnsmasq --force-depends
    opkg install dnsmasq-full

    # Restore config
    cp /etc/config/dhcp.backup /etc/config/dhcp 2>/dev/null || true

    log "  dnsmasq-full installiert"
fi

# dnsmasq init.d patchen (Teltonika nutzt anderen Pfad fuer OpenWRT packages)
# Muss NACH Installation UND bei jedem Setup geprueft werden
if [ -f /usr/local/usr/sbin/dnsmasq ]; then
    # Pruefen ob das Binary ipset Support hat
    if /usr/local/usr/sbin/dnsmasq --version 2>&1 | grep -q " ipset"; then
        if ! grep -q "/usr/local/usr/sbin/dnsmasq" /etc/init.d/dnsmasq 2>/dev/null; then
            log "  Patche /etc/init.d/dnsmasq fuer dnsmasq-full Pfad..."
            sed -i 's|PROG=/usr/sbin/dnsmasq|PROG=/usr/local/usr/sbin/dnsmasq|' /etc/init.d/dnsmasq
            # Flag fuer Reboot am Ende setzen
            touch /tmp/.multivpn_needs_reboot
        fi
    fi
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

# Permissions fuer openvpn/wireguard User
chmod 755 /etc/iproute2 2>/dev/null || true
chmod 644 /etc/iproute2/rt_tables 2>/dev/null || true

# =============================================================================
# IPSETS ERSTELLEN
# =============================================================================

log "Erstelle ipsets..."

# ipsets fuer jedes Land (basierend auf gefundenen Interfaces)
for iface in $(uci show network 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u); do
    if is_our_tunnel "$iface"; then
        country=$(get_country_from_iface "$iface")
        ipset_name="${country}_ips"

        if ! ipset list "$ipset_name" >/dev/null 2>&1; then
            ipset create "$ipset_name" hash:ip timeout 3600
            log "  ipset $ipset_name erstellt"
        else
            log "  ipset $ipset_name existiert bereits"
        fi
    fi
done

# =============================================================================
# DNSMASQ KONFIGURATION
# =============================================================================

log "Konfiguriere dnsmasq..."

# dnsmasq.d Verzeichnis erstellen falls nicht vorhanden
mkdir -p /etc/dnsmasq.d

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

# dnsmasq soll conf-dir benutzen (UCI Methode fuer OpenWRT)
if ! uci get dhcp.@dnsmasq[0].confdir >/dev/null 2>&1; then
    uci set dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
    uci commit dhcp
    log "  dnsmasq confdir konfiguriert"
fi

# dnsmasq neu starten
/etc/init.d/dnsmasq restart
log "  dnsmasq neu gestartet"

# =============================================================================
# VPN SWITCH SCRIPT ERSTELLEN (DYNAMISCH)
# =============================================================================

log "Erstelle VPN Control Scripts..."

cat > "$SCRIPT_DIR/vpn-control.sh" << 'VPNEOF'
#!/bin/sh
#
# Multi-VPN Control Script (Dynamisch)
# Usage: vpn-control.sh [on|off|status]
#

SCRIPT_DIR="/root/multivpn"
CONFIG_FILE="$SCRIPT_DIR/config"
TUNNEL_PREFIX="SS"
RT_TABLE_BASE=110
MARK_BASE=16

# Lade Config
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
STREAMING_DEVICES="${STREAMING_DEVICES:-192.168.110.100}"

# Extrahiert Laendercode aus Interface Name: SS_DE -> de, SS_DE2 -> de
get_country_from_iface() {
    echo "$1" | sed 's/^SS_//' | sed 's/[0-9]*$//' | tr '[:upper:]' '[:lower:]'
}

# Finde alle SS_* Interfaces
get_our_interfaces() {
    uci show network 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | grep "^${TUNNEL_PREFIX}_" | sort -u
}

# Hole alle Laender (einfache Version ohne Pipe-Probleme)
get_all_countries() {
    for iface in $(get_our_interfaces); do
        get_country_from_iface "$iface"
    done | sort -u
}

# Berechne Table fuer ein Land
get_table_for_country() {
    local country="$1"
    case "$country" in
        at) echo $((RT_TABLE_BASE + 0)) ;;
        ch) echo $((RT_TABLE_BASE + 1)) ;;
        de) echo $((RT_TABLE_BASE + 2)) ;;
        *)  echo $RT_TABLE_BASE ;;
    esac
}

# Berechne Mark fuer ein Land
get_mark_for_country() {
    local country="$1"
    case "$country" in
        at) printf "0x%x" $((MARK_BASE + 0)) ;;
        ch) printf "0x%x" $((MARK_BASE + 1)) ;;
        de) printf "0x%x" $((MARK_BASE + 2)) ;;
        *)  printf "0x%x" $MARK_BASE ;;
    esac
}

case "$1" in
    on)
        echo "Aktiviere Multi-VPN Routing..."

        # Sammle alle Laender
        countries=$(get_all_countries)

        # IP Rules aufsetzen
        for country in $countries; do
            table=$(get_table_for_country "$country")
            mark=$(get_mark_for_country "$country")

            ip rule del fwmark $mark table $table 2>/dev/null || true
            ip rule add fwmark $mark table $table priority $table
            echo "  Rule: $country mark=$mark -> table=$table"
        done

        # WireGuard Interfaces aktivieren
        for iface in $(get_our_interfaces); do
            echo "  Aktiviere: $iface"
            ifup "$iface" 2>/dev/null || true
        done

        # Warte auf Tunnel
        sleep 3

        # Routes in Tabellen setzen (erstes Interface pro Land)
        for country in $countries; do
            table=$(get_table_for_country "$country")
            # Finde erstes Interface fuer dieses Land
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

        # iptables Regeln aktivieren
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

        # Sammle alle Laender
        countries=$(get_all_countries)

        # iptables Regeln entfernen
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

        # WireGuard Interfaces deaktivieren
        for iface in $(get_our_interfaces); do
            echo "  Deaktiviere: $iface"
            ifdown "$iface" 2>/dev/null || true
        done

        echo "Multi-VPN Routing deaktiviert"
        ;;

    status)
        # JSON Status ausgeben
        tunnels_json="{"
        first=1
        for iface in $(get_our_interfaces); do
            country=$(get_country_from_iface "$iface" | tr '[:lower:]' '[:upper:]')
            up="false"
            wg show "$iface" >/dev/null 2>&1 && up="true"

            if [ $first -eq 1 ]; then
                first=0
            else
                tunnels_json="$tunnels_json,"
            fi
            tunnels_json="$tunnels_json\"$iface\":$up"
        done
        tunnels_json="$tunnels_json}"

        # ipset counts
        ipset_json="{"
        first=1
        for iface in $(get_our_interfaces); do
            country=$(get_country_from_iface "$iface")
            ipset_name="${country}_ips"
            count=$(ipset list "$ipset_name" 2>/dev/null | grep -c "^[0-9]" || echo 0)

            # Nur einmal pro Land
            if ! echo "$ipset_json" | grep -q "\"$country\""; then
                if [ $first -eq 1 ]; then
                    first=0
                else
                    ipset_json="$ipset_json,"
                fi
                ipset_json="$ipset_json\"$country\":$count"
            fi
        done
        ipset_json="$ipset_json}"

        # Pruefen ob Routing aktiv
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
# FIREWALL ZONE FUER VPN (DYNAMISCH)
# =============================================================================

log "Konfiguriere Firewall..."

# Sammle alle unsere Interfaces fuer die Firewall Zone
our_interfaces=""
for iface in $(uci show network 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u); do
    if is_our_tunnel "$iface"; then
        our_interfaces="$our_interfaces $iface"
    fi
done

# Pruefen ob vpn Zone existiert
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
log "Gefundene Tunnel:"
for iface in $our_interfaces; do
    country=$(get_country_from_iface "$iface")
    log "  - $iface ($country)"
done
log ""
log "Naechste Schritte:"
log "  1. vpn-control.sh on  - Routing aktivieren"
log "  2. vpn-control.sh off - Routing deaktivieren"
log "  3. vpn-control.sh status - Status anzeigen"
log ""

# =============================================================================
# REBOOT (falls dnsmasq-full installiert wurde)
# =============================================================================

if [ -f /tmp/.multivpn_needs_reboot ]; then
    rm -f /tmp/.multivpn_needs_reboot
    log "HINWEIS: dnsmasq-full wurde installiert."
    log "         System wird in 5 Sekunden neu gestartet..."
    sleep 5
    reboot
fi

exit 0
