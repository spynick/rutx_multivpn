#!/bin/bash
#
# SSH Key Setup für RUTX VPN Integration
# ======================================
# Generiert SSH Key und kopiert ihn auf den RUTX Router
#
# Verwendung:
#   ./setup_ssh_key.sh <RUTX_IP>
#
# Beispiel:
#   ./setup_ssh_key.sh 192.168.110.1
#

set -e

RUTX_IP="$1"
SSH_DIR="/config/.ssh"
KEY_FILE="$SSH_DIR/id_rsa"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Parameter prüfen
if [ -z "$RUTX_IP" ]; then
    echo "Verwendung: $0 <RUTX_IP>"
    echo "Beispiel:   $0 192.168.110.1"
    exit 1
fi

# Verzeichnis erstellen
log "Erstelle SSH Verzeichnis $SSH_DIR..."
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Key generieren falls nicht vorhanden
if [ -f "$KEY_FILE" ]; then
    warn "SSH Key existiert bereits: $KEY_FILE"
    read -p "Neuen Key generieren? (j/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Jj]$ ]]; then
        log "Generiere neuen SSH Key..."
        rm -f "$KEY_FILE" "$KEY_FILE.pub"
        ssh-keygen -t rsa -b 4096 -N "" -f "$KEY_FILE"
    fi
else
    log "Generiere SSH Key..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$KEY_FILE"
fi

chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"

log "SSH Key generiert:"
echo "  Private: $KEY_FILE"
echo "  Public:  $KEY_FILE.pub"

# Key auf RUTX kopieren
log "Kopiere Public Key auf RUTX ($RUTX_IP)..."
echo ""
echo "Du wirst nach dem RUTX root Passwort gefragt."
echo ""

# ssh-copy-id für Dropbear (RUTX verwendet Dropbear, nicht OpenSSH)
# Dropbear speichert Keys in /etc/dropbear/authorized_keys
PUB_KEY=$(cat "$KEY_FILE.pub")

ssh -o StrictHostKeyChecking=no root@"$RUTX_IP" "
    mkdir -p /etc/dropbear
    touch /etc/dropbear/authorized_keys
    chmod 700 /etc/dropbear
    chmod 600 /etc/dropbear/authorized_keys
    if ! grep -q '$(echo $PUB_KEY | cut -d' ' -f2)' /etc/dropbear/authorized_keys 2>/dev/null; then
        echo '$PUB_KEY' >> /etc/dropbear/authorized_keys
        echo 'Key hinzugefuegt'
    else
        echo 'Key existiert bereits'
    fi
"

# Test
log "Teste SSH Verbindung..."
if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o BatchMode=yes root@"$RUTX_IP" "echo OK" >/dev/null 2>&1; then
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}SSH Key Setup erfolgreich!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "SSH Verbindung funktioniert ohne Passwort."
    echo ""
    echo "Naechster Schritt:"
    echo "  1. RUTX IP in Home Assistant eintragen (input_text.rutx_host)"
    echo "  2. YAML neu laden"
    echo "  3. VPN Profil ueber input_select.rutx_vpn_profile wechseln"
    echo ""
else
    error "SSH Verbindung fehlgeschlagen. Bitte manuell pruefen."
fi
