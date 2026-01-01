#!/bin/sh
#
# RUTX Multi-VPN Cleanup Script
# =============================
# Entfernt alle Streaming VPN Konfigurationen
#
# WICHTIG: Management VPNs werden NIEMALS angefasst!
# Geschuetzte Namen: WG, MGMT, HOME, VPN (und Varianten)
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

log "[2/7] Entferne Streaming WireGuard Interfaces..."

# Alle WireGuard Interfaces durchgehen
for iface in $(uci show network 2>/dev/null | grep "=wireguard" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u); do
    if is_protected "$iface"; then
        warn "  UEBERSPRINGE geschuetztes Interface: $iface"
        continue
    fi

    if is_our_tunnel "$iface"; then
        log "  Entferne: $iface"
        # Interface stoppen
        ifdown "$iface" 2>/dev/null || true
        # UCI Config loeschen
        uci delete "network.$iface" 2>/dev/null || true
        # Peer Config loeschen
        for peer in $(uci show network 2>/dev/null | grep "wireguard_${iface}" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u); do
            uci delete "network.$peer" 2>/dev/null || true
        done
    else
        log "  Ueberspringe fremdes Interface: $iface"
    fi
done

uci commit network 2>/dev/null || true
log "  WireGuard Interfaces bereinigt"

# =============================================================================
# SCHRITT 3: IPSETS ENTFERNEN
# =============================================================================

log "[3/7] Entferne ipsets..."

for ipset_name in de_ips ch_ips at_ips; do
    if ipset list "$ipset_name" >/dev/null 2>&1; then
        ipset destroy "$ipset_name" 2>/dev/null || true
        log "  ipset $ipset_name entfernt"
    fi
done

# =============================================================================
# SCHRITT 4: DNSMASQ CONFIG ENTFERNEN
# =============================================================================

log "[4/7] Entferne dnsmasq Konfiguration..."

if [ -f /etc/dnsmasq.d/multivpn-ipset.conf ]; then
    rm -f /etc/dnsmasq.d/multivpn-ipset.conf
    /etc/init.d/dnsmasq restart
    log "  dnsmasq Config entfernt"
else
    log "  Keine dnsmasq Config vorhanden"
fi

# =============================================================================
# SCHRITT 5: FIREWALL REGELN ENTFERNEN
# =============================================================================

log "[5/7] Entferne Firewall Konfiguration..."

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
# SCHRITT 6: ROUTING TABELLEN BEREINIGEN
# =============================================================================

log "[6/7] Bereinige Routing Tabellen..."

# Eintraege aus rt_tables entfernen
if [ -f /etc/iproute2/rt_tables ]; then
    sed -i '/vpn_de/d' /etc/iproute2/rt_tables
    sed -i '/vpn_ch/d' /etc/iproute2/rt_tables
    sed -i '/vpn_at/d' /etc/iproute2/rt_tables
    log "  Routing Tabellen bereinigt"
fi

# =============================================================================
# SCHRITT 7: SCRIPTS UND CONFIGS ENTFERNEN
# =============================================================================

log "[7/7] Entferne Scripts und Konfiguration..."

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
