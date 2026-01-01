#!/bin/sh
#
# RUTX Multi-VPN Diagnose Script
# ================================
# Prueft ob die VPN Tunnel aktiv sind und Traffic durchfliesst
#
# Verwendung auf RUTX:
#   /root/multivpn/check.sh
#
# Oder via SSH:
#   ssh root@RUTX_IP "/root/multivpn/check.sh"
#

echo "=============================================="
echo "  RUTX Multi-VPN Diagnose"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="
echo ""

# Farben (falls Terminal unterstuetzt)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() {
    echo "[OK]    $1"
}

warn() {
    echo "[WARN]  $1"
}

fail() {
    echo "[FAIL]  $1"
}

info() {
    echo "[INFO]  $1"
}

# =============================================================================
# 1. WIREGUARD INTERFACES
# =============================================================================

echo "--- WireGuard Interfaces ---"
echo ""

for iface in SS_DE SS_CH SS_AT; do
    if wg show "$iface" >/dev/null 2>&1; then
        endpoint=$(wg show "$iface" endpoints 2>/dev/null | awk '{print $2}')
        tx=$(wg show "$iface" transfer 2>/dev/null | awk '{print $2}')
        rx=$(wg show "$iface" transfer 2>/dev/null | awk '{print $3}')
        latest=$(wg show "$iface" latest-handshakes 2>/dev/null | awk '{print $2}')

        # Handshake Alter berechnen
        if [ -n "$latest" ] && [ "$latest" != "0" ]; then
            now=$(date +%s)
            age=$((now - latest))
            if [ $age -lt 180 ]; then
                handshake_status="aktiv (vor ${age}s)"
            else
                handshake_status="inaktiv (vor ${age}s)"
            fi
        else
            handshake_status="nie"
        fi

        ok "$iface: UP"
        info "  Endpoint: $endpoint"
        info "  TX: $tx bytes, RX: $rx bytes"
        info "  Handshake: $handshake_status"
    else
        fail "$iface: DOWN oder nicht konfiguriert"
    fi
    echo ""
done

# =============================================================================
# 2. IPSETS
# =============================================================================

echo "--- ipsets (DNS-aufgeloeste IPs) ---"
echo ""

for ipset_name in de_ips ch_ips at_ips; do
    if ipset list "$ipset_name" >/dev/null 2>&1; then
        count=$(ipset list "$ipset_name" 2>/dev/null | grep -c "^[0-9]" || echo 0)
        ok "$ipset_name: $count IPs"

        # Zeige erste 5 IPs
        if [ "$count" -gt 0 ]; then
            echo "       Beispiele: $(ipset list "$ipset_name" 2>/dev/null | grep "^[0-9]" | head -3 | tr '\n' ' ')"
        fi
    else
        warn "$ipset_name: nicht vorhanden"
    fi
done
echo ""

# =============================================================================
# 3. ROUTING RULES
# =============================================================================

echo "--- Routing Rules (ip rule) ---"
echo ""

for mark_info in "0x10:110:DE" "0x11:111:CH" "0x12:112:AT"; do
    mark=$(echo "$mark_info" | cut -d: -f1)
    table=$(echo "$mark_info" | cut -d: -f2)
    country=$(echo "$mark_info" | cut -d: -f3)

    if ip rule show | grep -q "fwmark $mark"; then
        ok "Rule fuer $country: fwmark $mark -> table $table"
    else
        fail "Rule fuer $country: FEHLT (fwmark $mark)"
    fi
done
echo ""

# =============================================================================
# 4. ROUTING TABLES
# =============================================================================

echo "--- Routing Tables ---"
echo ""

for table_info in "110:SS_DE:DE" "111:SS_CH:CH" "112:SS_AT:AT"; do
    table=$(echo "$table_info" | cut -d: -f1)
    iface=$(echo "$table_info" | cut -d: -f2)
    country=$(echo "$table_info" | cut -d: -f3)

    route=$(ip route show table "$table" 2>/dev/null | head -1)
    if [ -n "$route" ]; then
        ok "Table $table ($country): $route"
    else
        warn "Table $table ($country): leer oder nicht vorhanden"
    fi
done
echo ""

# =============================================================================
# 5. IPTABLES MANGLE RULES
# =============================================================================

echo "--- iptables MANGLE Rules ---"
echo ""

mangle_rules=$(iptables -t mangle -L PREROUTING -n -v 2>/dev/null | grep -c "MARK set" || echo 0)
if [ "$mangle_rules" -gt 0 ]; then
    ok "$mangle_rules MARK Rules aktiv"
    echo ""
    iptables -t mangle -L PREROUTING -n -v 2>/dev/null | grep "MARK set" | head -6
else
    fail "Keine MARK Rules gefunden"
fi
echo ""

# =============================================================================
# 6. STREAMING DEVICES
# =============================================================================

echo "--- Streaming Devices ---"
echo ""

if [ -f /root/multivpn/config ]; then
    . /root/multivpn/config
    info "Konfigurierte Devices: $STREAMING_DEVICES"
else
    warn "Config nicht gefunden: /root/multivpn/config"
fi
echo ""

# =============================================================================
# 7. TRAFFIC TEST (optional)
# =============================================================================

echo "--- Traffic Test ---"
echo ""

# Teste ob wir durch den Tunnel rauskommen
for tunnel_info in "SS_DE:de-fra.prod.surfshark.com" "SS_CH:ch-zur.prod.surfshark.com" "SS_AT:at-vie.prod.surfshark.com"; do
    iface=$(echo "$tunnel_info" | cut -d: -f1)
    expected_host=$(echo "$tunnel_info" | cut -d: -f2)

    if wg show "$iface" >/dev/null 2>&1; then
        # Ping durch den Tunnel (10.14.0.1 ist typischerweise das Gateway)
        if ping -c 1 -W 2 -I "$iface" 10.14.0.1 >/dev/null 2>&1; then
            ok "$iface: Tunnel erreichbar"
        else
            warn "$iface: Tunnel nicht pingbar (kann normal sein)"
        fi
    fi
done
echo ""

# =============================================================================
# 8. DNSMASQ STATUS
# =============================================================================

echo "--- dnsmasq ---"
echo ""

if [ -f /etc/dnsmasq.d/multivpn-ipset.conf ]; then
    ok "ipset Config vorhanden"
    domains_de=$(grep -c "de_ips" /etc/dnsmasq.d/multivpn-ipset.conf 2>/dev/null || echo 0)
    domains_ch=$(grep -c "ch_ips" /etc/dnsmasq.d/multivpn-ipset.conf 2>/dev/null || echo 0)
    domains_at=$(grep -c "at_ips" /etc/dnsmasq.d/multivpn-ipset.conf 2>/dev/null || echo 0)
    info "  DE Domains: $domains_de Zeilen"
    info "  CH Domains: $domains_ch Zeilen"
    info "  AT Domains: $domains_at Zeilen"
else
    fail "ipset Config fehlt: /etc/dnsmasq.d/multivpn-ipset.conf"
fi

if pgrep dnsmasq >/dev/null 2>&1; then
    ok "dnsmasq laeuft"
else
    fail "dnsmasq laeuft NICHT"
fi
echo ""

# =============================================================================
# 9. LIVE TRAFFIC CHECK
# =============================================================================

echo "--- Live Traffic (letzte Bytes) ---"
echo ""

for iface in SS_DE SS_CH SS_AT; do
    if wg show "$iface" >/dev/null 2>&1; then
        transfer=$(wg show "$iface" transfer 2>/dev/null)
        if [ -n "$transfer" ]; then
            tx=$(echo "$transfer" | awk '{print $2}')
            rx=$(echo "$transfer" | awk '{print $3}')

            # Human readable
            tx_hr=$(numfmt --to=iec $tx 2>/dev/null || echo "$tx B")
            rx_hr=$(numfmt --to=iec $rx 2>/dev/null || echo "$rx B")

            if [ "$tx" -gt 0 ] || [ "$rx" -gt 0 ]; then
                ok "$iface: TX=$tx_hr RX=$rx_hr"
            else
                warn "$iface: Kein Traffic (TX=0, RX=0)"
            fi
        fi
    fi
done
echo ""

# =============================================================================
# ZUSAMMENFASSUNG
# =============================================================================

echo "=============================================="
echo "  Zusammenfassung"
echo "=============================================="

# Zaehle Probleme
problems=0

# Check Tunnels
for iface in SS_DE SS_CH SS_AT; do
    wg show "$iface" >/dev/null 2>&1 || problems=$((problems + 1))
done

# Check Rules
ip rule show | grep -q "fwmark 0x10" || problems=$((problems + 1))

# Check dnsmasq
[ -f /etc/dnsmasq.d/multivpn-ipset.conf ] || problems=$((problems + 1))

if [ $problems -eq 0 ]; then
    echo ""
    ok "Alles OK! Multi-VPN sollte funktionieren."
    echo ""
else
    echo ""
    warn "$problems Problem(e) gefunden. Siehe Details oben."
    echo ""
fi

echo "Tipp: Streaming Domain aufrufen und dann ipset pruefen:"
echo "  ipset list de_ips | tail -5"
echo ""
