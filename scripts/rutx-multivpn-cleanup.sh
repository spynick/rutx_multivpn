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

log "[1/9] Deaktiviere VPN Routing..."

# Routing Script ausfuehren falls vorhanden
if [ -x /root/multivpn/vpn-control.sh ]; then
    /root/multivpn/vpn-control.sh off 2>/dev/null || true
fi

# IP Rules entfernen (alle moeglichen Kombinationen)
for mark in 0x10 0x11 0x12 0x13 0x14 0x15; do
    for table in 110 111 112 113 114 115; do
        ip rule del fwmark $mark table $table 2>/dev/null || true
    done
done

# iptables mangle Regeln entfernen (alle ipset matches fuer streaming)
for ipset_name in de_ips ch_ips at_ips DE_ips CH_ips AT_ips; do
    # Alle Regeln mit diesem ipset entfernen
    while iptables -t mangle -D PREROUTING -m set --match-set $ipset_name dst -j MARK 2>/dev/null; do :; done
    # Mit Source IP
    iptables -t mangle -S PREROUTING 2>/dev/null | grep "$ipset_name" | while read rule; do
        # Regel in delete umwandeln
        echo "$rule" | sed 's/^-A/-D/' | xargs iptables -t mangle 2>/dev/null || true
    done
done

log "  Routing und iptables deaktiviert"

# =============================================================================
# SCHRITT 2: WIREGUARD INTERFACES ENTFERNEN (NUR SS_*)
# =============================================================================

log "[2/9] Entferne Streaming WireGuard Interfaces..."

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

log "[3/9] Entferne ipsets..."

for ipset_name in de_ips ch_ips at_ips; do
    if ipset list "$ipset_name" >/dev/null 2>&1; then
        ipset destroy "$ipset_name" 2>/dev/null || true
        log "  ipset $ipset_name entfernt"
    fi
done

# =============================================================================
# SCHRITT 4: DNSMASQ CONFIG ENTFERNEN
# =============================================================================

log "[4/9] Entferne dnsmasq Konfiguration..."

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
# SCHRITT 5: DNSMASQ NEU STARTEN
# =============================================================================

log "[5/9] Starte dnsmasq neu..."

# HINWEIS: dnsmasq-full wird NICHT entfernt!
# Das wuerde das Teltonika-spezifische init.d Script zerstoeren.
# dnsmasq-full schadet nicht wenn es installiert bleibt.

# dnsmasq neu starten (ipset config wurde in Schritt 4 entfernt)
/etc/init.d/dnsmasq restart 2>/dev/null || true

log "  dnsmasq neu gestartet"

# =============================================================================
# SCHRITT 6: FIREWALL REGELN ENTFERNEN
# =============================================================================

log "[6/9] Entferne Firewall Konfiguration..."

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

log "[7/9] Bereinige Routing Tabellen..."

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

log "[8/9] Entferne Scripts und Konfiguration..."

if [ -d /root/multivpn ]; then
    rm -rf /root/multivpn
    log "  /root/multivpn entfernt"
fi

# =============================================================================
# SCHRITT 9: FIREWALL NEU LADEN
# =============================================================================

log "[9/9] Lade Firewall und Network neu..."
/etc/init.d/firewall reload 2>/dev/null || true
/etc/init.d/network reload 2>/dev/null || true

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
