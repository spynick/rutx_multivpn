#!/bin/bash
#
# Multi-VPN Client Check Script
# ==============================
# Prueft ob der Traffic vom Streaming Device korrekt geroutet wird
#
# Ausfuehren auf dem Streaming Device (Apple TV, Fire TV, Linux Box):
#   ./client_check.sh
#
# Was wird geprueft:
#   1. Externe IP Adresse
#   2. Geo-Location (Land)
#   3. Erreichbarkeit der Streaming Dienste
#   4. DNS Aufloesung
#

echo "=============================================="
echo "  Multi-VPN Client Check"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="
echo ""

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC}    $1"; }
fail() { echo -e "${RED}[FAIL]${NC}  $1"; }
info() { echo -e "${BLUE}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }

# =============================================================================
# 1. EXTERNE IP UND GEO-LOCATION
# =============================================================================

echo "--- Externe IP und Geo-Location ---"
echo ""

# Mehrere Services probieren
EXTERNAL_IP=""
for service in "ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "api.ipify.org"; do
    EXTERNAL_IP=$(curl -s --connect-timeout 5 "$service" 2>/dev/null)
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
done

if [ -n "$EXTERNAL_IP" ]; then
    ok "Externe IP: $EXTERNAL_IP"

    # Geo-Location abfragen
    GEO_INFO=$(curl -s --connect-timeout 5 "ipinfo.io/$EXTERNAL_IP" 2>/dev/null)
    if [ -n "$GEO_INFO" ]; then
        COUNTRY=$(echo "$GEO_INFO" | grep -o '"country": *"[^"]*"' | cut -d'"' -f4)
        CITY=$(echo "$GEO_INFO" | grep -o '"city": *"[^"]*"' | cut -d'"' -f4)
        ORG=$(echo "$GEO_INFO" | grep -o '"org": *"[^"]*"' | cut -d'"' -f4)

        info "  Land: $COUNTRY"
        info "  Stadt: $CITY"
        info "  Provider: $ORG"

        # VPN Check
        if echo "$ORG" | grep -qi "surfshark\|mullvad\|expressvpn\|nord"; then
            ok "  -> Traffic geht durch VPN!"
        else
            warn "  -> Kein VPN Provider erkannt (evtl. trotzdem VPN)"
        fi
    fi
else
    fail "Konnte externe IP nicht ermitteln"
fi
echo ""

# =============================================================================
# 2. DNS AUFLOESUNG UND ROUTING PRO LAND
# =============================================================================

echo "--- DNS und Routing Tests ---"
echo ""

# Deutsche Domains
echo "Deutschland (sollte durch DE Tunnel):"
for domain in "ardmediathek.de" "zdf.de"; do
    IP=$(dig +short "$domain" 2>/dev/null | head -1)
    if [ -n "$IP" ]; then
        # Traceroute ersten Hop
        FIRST_HOP=$(traceroute -n -m 3 "$IP" 2>/dev/null | grep -E "^ *[0-9]" | head -1 | awk '{print $2}')
        ok "$domain -> $IP"
        info "  Erster Hop: $FIRST_HOP"
    else
        fail "$domain -> DNS Fehler"
    fi
done
echo ""

# Schweizer Domains
echo "Schweiz (sollte durch CH Tunnel):"
for domain in "srf.ch" "playsuisse.ch"; do
    IP=$(dig +short "$domain" 2>/dev/null | head -1)
    if [ -n "$IP" ]; then
        ok "$domain -> $IP"
    else
        fail "$domain -> DNS Fehler"
    fi
done
echo ""

# Oesterreichische Domains
echo "Oesterreich (sollte durch AT Tunnel):"
for domain in "orf.at" "servustv.com"; do
    IP=$(dig +short "$domain" 2>/dev/null | head -1)
    if [ -n "$IP" ]; then
        ok "$domain -> $IP"
    else
        fail "$domain -> DNS Fehler"
    fi
done
echo ""

# =============================================================================
# 3. STREAMING DIENSTE ERREICHBARKEIT
# =============================================================================

echo "--- Streaming Dienste Erreichbarkeit ---"
echo ""

check_url() {
    local name="$1"
    local url="$2"
    local expected_country="$3"

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url" 2>/dev/null)

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        ok "$name: HTTP $HTTP_CODE (erreichbar)"
    elif [ "$HTTP_CODE" = "403" ]; then
        fail "$name: HTTP 403 (Geo-Block!)"
    elif [ "$HTTP_CODE" = "000" ]; then
        fail "$name: Timeout/Nicht erreichbar"
    else
        warn "$name: HTTP $HTTP_CODE"
    fi
}

echo "Deutsche Dienste:"
check_url "ARD Mediathek" "https://www.ardmediathek.de" "DE"
check_url "ZDF Mediathek" "https://www.zdf.de" "DE"
echo ""

echo "Schweizer Dienste:"
check_url "SRF Play" "https://www.srf.ch/play" "CH"
check_url "Play Suisse" "https://www.playsuisse.ch" "CH"
echo ""

echo "Oesterreichische Dienste:"
check_url "ORF TVthek" "https://tvthek.orf.at" "AT"
check_url "ServusTV" "https://www.servustv.com" "AT"
echo ""

# =============================================================================
# 4. VERGLEICH: NORMALE DOMAIN VS STREAMING DOMAIN
# =============================================================================

echo "--- Routing Vergleich ---"
echo ""
info "Normale Domain (sollte NICHT durch VPN):"

GOOGLE_IP=$(curl -s --connect-timeout 5 "https://www.google.com/generate_204" -w "%{remote_ip}" -o /dev/null 2>/dev/null)
info "  google.com verbindet zu: $GOOGLE_IP"

echo ""
info "Streaming Domain (sollte durch VPN):"

ARD_IP=$(curl -s --connect-timeout 5 "https://www.ardmediathek.de" -w "%{remote_ip}" -o /dev/null 2>/dev/null)
info "  ardmediathek.de verbindet zu: $ARD_IP"

echo ""

# =============================================================================
# 5. ZUSAMMENFASSUNG
# =============================================================================

echo "=============================================="
echo "  Zusammenfassung"
echo "=============================================="
echo ""

if echo "$ORG" | grep -qi "surfshark\|mullvad\|expressvpn\|nord"; then
    ok "VPN ist aktiv"
    echo ""
    echo "Dein Traffic geht aktuell durch: $COUNTRY ($CITY)"
    echo "Provider: $ORG"
else
    warn "VPN Status unklar"
    echo ""
    echo "Externe IP: $EXTERNAL_IP"
    echo "Land: $COUNTRY"
fi

echo ""
echo "Tipp: Rufe eine Streaming Seite auf und pruefe ob Geo-Block kommt."
echo ""
