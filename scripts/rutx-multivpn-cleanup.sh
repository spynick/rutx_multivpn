#!/bin/sh
#
# RUTX Multi-VPN Cleanup Script
# =============================
# Entfernt alle Streaming VPN Konfigurationen
#
# WICHTIG: Management VPNs werden NIEMALS angefasst!
# Geschuetzte Namen: WG, MGMT, HOME, VPN (und Varianten)
#
# Features:
#   - Entfernt alle SS_* WireGuard Tunnel
#   - Setzt dnsmasq-full zurueck auf Standard dnsmasq
#   - Bereinigt Firewall und Routing
#

set -e

# =============================================================================
# KONFIGURATION
# =============================================================================

# Geschuetzte WireGuard Namen (NIEMALS anfassen!)
PROTECTED_PATTERNS="WG MGMT HOME VPN wg mgmt home vpn"

# Unser Prefix fuer Streaming Tunnel
TUNNEL_PREFIX="SS"

# =============================================================================
# FUNKTIONEN
# =============================================================================

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

warn() {
    echo "[$(date '+%H:%M:%S')] WARNUNG: $1"
}

# Prueft ob ein Name geschuetzt ist
is_protected() {
    local name="$1"
    for pattern in $PROTECTED_PATTERNS; do
        if [ "$name" = "$pattern" ]; then
            return 0
        fi
        case "$name" in
            ${pattern}*|*${pattern}) return 0 ;;
        esac
    done
    return 1
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
# CLEANUP START
# =============================================================================

log "=== RUTX Multi-VPN Cleanup Start ==="
log ""
log "GESCHUETZTE Interfaces (werden NICHT angefasst):"
for pattern in $PROTECTED_PATTERNS; do
    log "  - $pattern*"
done
log ""

# =============================================================================
# SCHRITT 1: VPN ROUTING DEAKTIVIEREN
# =============================================================================

log "[1/7] Deaktiviere VPN Routing..."

# Routing Script ausfuehren falls vorhanden
if [ -x /root/multivpn/vpn-control.sh ]; then
    /root/multivpn/vpn-control.sh off 2>/dev/null || true
fi

# IP Rules entfernen
ip rule del fwmark 0x10 table 110 2>/dev/null || true
ip rule del fwmark 0x11 table 111 2>/dev/null || true
ip rule del fwmark 0x12 table 112 2>/dev/null || true

log "  Routing deaktiviert"

# =============================================================================
# SCHRITT 2: WIREGUARD INTERFACES ENTFERNEN (NUR SS_*)
# =============================================================================

log "[2/8] Entferne Streaming WireGuard Interfaces..."

# Alle Network Interfaces durchgehen (SS_* sind unsere)
for iface in $(uci show network 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u); do
    if is_protected "$iface"; then
        warn "  UEBERSPRINGE geschuetztes Interface: $iface"
        continue
    fi

    if is_our_tunnel "$iface"; then
        log "  Entferne: $iface"
        # Interface stoppen
        ifdown "$iface" 2>/dev/null || true

        # Anonyme Peer Sections loeschen (wireguard_SS_XX)
        while uci -q get network.@wireguard_${iface}[0] >/dev/null 2>&1; do
            uci delete network.@wireguard_${iface}[0] 2>/dev/null || true
        done

        # Interface Config loeschen
        uci delete "network.$iface" 2>/dev/null || true

        log "    Interface und Peers entfernt"
    fi
done

uci commit network 2>/dev/null || true

# Network neu laden damit Interfaces wirklich weg sind
/etc/init.d/network reload 2>/dev/null || true

log "  WireGuard Interfaces bereinigt"

# =============================================================================
# SCHRITT 3: IPSETS ENTFERNEN
# =============================================================================

log "[3/8] Entferne ipsets..."

for ipset_name in de_ips ch_ips at_ips; do
    if ipset list "$ipset_name" >/dev/null 2>&1; then
        ipset destroy "$ipset_name" 2>/dev/null || true
        log "  ipset $ipset_name entfernt"
    fi
done

# =============================================================================
# SCHRITT 4: DNSMASQ CONFIG ENTFERNEN
# =============================================================================

log "[4/8] Entferne dnsmasq Konfiguration..."

if [ -f /etc/dnsmasq.d/multivpn-ipset.conf ]; then
    rm -f /etc/dnsmasq.d/multivpn-ipset.conf
    log "  dnsmasq ipset Config entfernt"
else
    log "  Keine dnsmasq Config vorhanden"
fi

# dnsmasq confdir entfernen
if uci get dhcp.@dnsmasq[0].confdir >/dev/null 2>&1; then
    uci delete dhcp.@dnsmasq[0].confdir
    uci commit dhcp
    log "  dnsmasq confdir Einstellung entfernt"
fi

# =============================================================================
# SCHRITT 5: DNSMASQ-FULL ZURUECKSETZEN
# =============================================================================

log "[5/8] Setze dnsmasq zurueck..."

# Pruefen ob dnsmasq-full installiert ist
if opkg list-installed | grep -q "dnsmasq-full"; then
    log "  dnsmasq-full gefunden, setze zurueck auf Standard..."

    # Backup der aktuellen dnsmasq config
    cp /etc/config/dhcp /etc/config/dhcp.backup 2>/dev/null || true

    # dnsmasq-full entfernen und normales dnsmasq installieren
    opkg remove dnsmasq-full --force-depends 2>/dev/null || true
    opkg install dnsmasq 2>/dev/null || true

    # init.d zuruecksetzen (falls gepatcht)
    if grep -q "/usr/local/usr/sbin/dnsmasq" /etc/init.d/dnsmasq 2>/dev/null; then
        sed -i 's|PROG=/usr/local/usr/sbin/dnsmasq|PROG=/usr/sbin/dnsmasq|' /etc/init.d/dnsmasq
        log "  /etc/init.d/dnsmasq Pfad zurueckgesetzt"
    fi

    # Config restore
    cp /etc/config/dhcp.backup /etc/config/dhcp 2>/dev/null || true

    # OpenWRT Repo entfernen
    sed -i '/openwrt_base/d' /etc/opkg/customfeeds.conf 2>/dev/null || true

    log "  dnsmasq zurueckgesetzt"
else
    log "  Standard dnsmasq ist installiert"
fi

# dnsmasq neu starten
/etc/init.d/dnsmasq restart 2>/dev/null || true

# =============================================================================
# SCHRITT 6: FIREWALL REGELN ENTFERNEN
# =============================================================================

log "[6/8] Entferne Firewall Konfiguration..."

# VPN Zone entfernen (nur wenn sie unsere Tunnel enthaelt)
if uci get firewall.vpn_zone >/dev/null 2>&1; then
    # Pruefen ob nur unsere Interfaces drin sind
    networks=$(uci get firewall.vpn_zone.network 2>/dev/null || true)
    if echo "$networks" | grep -q "SS_"; then
        uci delete firewall.vpn_zone 2>/dev/null || true
        log "  VPN Firewall Zone entfernt"
    else
        warn "  VPN Zone enthaelt fremde Interfaces, ueberspringe"
    fi
fi

# Forwarding entfernen
if uci get firewall.lan_vpn_forward >/dev/null 2>&1; then
    uci delete firewall.lan_vpn_forward 2>/dev/null || true
    log "  LAN->VPN Forwarding entfernt"
fi

uci commit firewall 2>/dev/null || true

# =============================================================================
# SCHRITT 7: ROUTING TABELLEN BEREINIGEN
# =============================================================================

log "[7/8] Bereinige Routing Tabellen..."

# Eintraege aus rt_tables entfernen (lowercase und uppercase)
if [ -f /etc/iproute2/rt_tables ]; then
    sed -i '/vpn_de/d' /etc/iproute2/rt_tables
    sed -i '/vpn_ch/d' /etc/iproute2/rt_tables
    sed -i '/vpn_at/d' /etc/iproute2/rt_tables
    sed -i '/vpn_DE/d' /etc/iproute2/rt_tables
    sed -i '/vpn_CH/d' /etc/iproute2/rt_tables
    sed -i '/vpn_AT/d' /etc/iproute2/rt_tables
    log "  Routing Tabellen bereinigt"
fi

# =============================================================================
# SCHRITT 8: SCRIPTS UND CONFIGS ENTFERNEN
# =============================================================================

log "[8/8] Entferne Scripts und Konfiguration..."

if [ -d /root/multivpn ]; then
    rm -rf /root/multivpn
    log "  /root/multivpn entfernt"
fi

# =============================================================================
# FIREWALL NEU LADEN
# =============================================================================

log "Lade Firewall neu..."
/etc/init.d/firewall reload 2>/dev/null || true

# =============================================================================
# FERTIG
# =============================================================================

log ""
log "=== Cleanup abgeschlossen ==="
log ""
log "Geschuetzte Management VPNs wurden NICHT angefasst."
log "Der RUTX ist bereit fuer ein neues Setup."
log ""

exit 0
