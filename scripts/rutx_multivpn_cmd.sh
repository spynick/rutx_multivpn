#!/bin/bash
#
# RUTX Multi-VPN Command Wrapper
# ===============================
# Fuehrt SSH Befehle auf dem RUTX aus
#
# Verwendung:
#   rutx_multivpn_cmd.sh on
#   rutx_multivpn_cmd.sh off
#   rutx_multivpn_cmd.sh status
#   rutx_multivpn_cmd.sh provision <rutx_host> <devices>
#   rutx_multivpn_cmd.sh cleanup
#   rutx_multivpn_cmd.sh check
#

SSH_KEY="/config/.ssh/id_rsa"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

# HA API Token (Long-Lived Access Token "RUTX-VPN")
HA_API_TOKEN_FILE="/config/.ha_api_token"
if [ -f "$HA_API_TOKEN_FILE" ]; then
    HA_API_TOKEN=$(cat "$HA_API_TOKEN_FILE")
elif [ -n "$SUPERVISOR_TOKEN" ]; then
    HA_API_TOKEN="$SUPERVISOR_TOKEN"
else
    HA_API_TOKEN=""
fi
HA_API_URL="http://supervisor/core/api"

# HA Notification senden
# Verwendung: send_notification "Titel" "Nachricht"
send_notification() {
    local title="$1"
    local message="$2"
    local notification_id="${3:-multivpn_status}"

    # Ohne Token keine Notification
    [ -z "$HA_API_TOKEN" ] && return 0

    # Escape newlines und quotes fuer JSON
    message=$(echo "$message" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')

    curl -s -X POST \
        -H "Authorization: Bearer ${HA_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"$title\", \"message\": \"$message\", \"notification_id\": \"$notification_id\"}" \
        "${HA_API_URL}/services/persistent_notification/create" \
        >/dev/null 2>&1
}

# RUTX Host aus Datei lesen (wird vom Provisioning geschrieben)
if [ -f /config/.rutx_multivpn_host ]; then
    RUTX_HOST=$(cat /config/.rutx_multivpn_host | tr -d '\n')
else
    RUTX_HOST="${RUTX_HOST:-192.168.110.1}"
fi

case "$1" in
    on)
        ssh $SSH_OPTS root@$RUTX_HOST "/root/multivpn/vpn-control.sh on"
        ;;
    off)
        ssh $SSH_OPTS root@$RUTX_HOST "/root/multivpn/vpn-control.sh off"
        ;;
    status)
        ssh $SSH_OPTS root@$RUTX_HOST "/root/multivpn/vpn-control.sh status"
        ;;
    provision)
        RUTX_HOST="$2"
        shift 2  # Entferne $1 (provision) und $2 (host)
        # Akzeptiert Komma, Semikolon oder Leerzeichen als Trenner
        STREAMING_DEVICES=$(echo "$*" | tr ',;' ' ' | xargs)
        export RUTX_HOST STREAMING_DEVICES SSH_KEY
        /config/packages/rutx_multivpn/scripts/rutx_multivpn_provision.sh
        ;;
    cleanup)
        # Cleanup Script hochladen und ausfuehren
        CLEANUP_SCRIPT="/config/packages/rutx_multivpn/scripts/rutx-multivpn-cleanup.sh"
        if [ -f "$CLEANUP_SCRIPT" ]; then
            scp $SSH_OPTS "$CLEANUP_SCRIPT" root@$RUTX_HOST:/tmp/cleanup.sh
            ssh $SSH_OPTS root@$RUTX_HOST "chmod +x /tmp/cleanup.sh && sh /tmp/cleanup.sh && rm /tmp/cleanup.sh"
        else
            echo "Cleanup Script nicht gefunden: $CLEANUP_SCRIPT"
            exit 1
        fi
        ;;
    devices)
        shift 1  # Entferne $1 (devices)
        # Akzeptiert Komma, Semikolon oder Leerzeichen als Trenner
        DEVICES=$(echo "$*" | tr ',;' ' ' | xargs)
        ssh $SSH_OPTS root@$RUTX_HOST "/root/multivpn/manage-devices.sh set $DEVICES"
        ;;
    check)
        # Diagnose mit kompakter Ausgabe fuer Notification
        OUTPUT=""
        PROBLEMS=0

        # SSH Test
        if ! ssh $SSH_OPTS root@$RUTX_HOST "echo OK" >/dev/null 2>&1; then
            send_notification "Multi-VPN Diagnose" "SSH Verbindung zu $RUTX_HOST fehlgeschlagen" "multivpn_check"
            exit 1
        fi

        # WireGuard Status holen
        WG_STATUS=$(ssh $SSH_OPTS root@$RUTX_HOST "
            for iface in SS_DE SS_CH SS_AT; do
                if wg show \$iface >/dev/null 2>&1; then
                    tx=\$(wg show \$iface transfer 2>/dev/null | awk '{print \$2}')
                    rx=\$(wg show \$iface transfer 2>/dev/null | awk '{print \$3}')
                    echo \"\$iface:UP:\$tx:\$rx\"
                else
                    echo \"\$iface:DOWN:0:0\"
                fi
            done
        " 2>/dev/null)

        OUTPUT="**WireGuard Tunnel:**\n"
        while IFS=: read -r iface status tx rx; do
            [ -z "$iface" ] && continue
            if [ "$status" = "UP" ]; then
                OUTPUT="$OUTPUT- $iface: An (TX: $tx, RX: $rx)\n"
            else
                OUTPUT="$OUTPUT- $iface: Aus\n"
                PROBLEMS=$((PROBLEMS + 1))
            fi
        done <<< "$WG_STATUS"

        # ipset Status
        IPSET_STATUS=$(ssh $SSH_OPTS root@$RUTX_HOST "
            for ipset in de_ips ch_ips at_ips; do
                count=\$(ipset list \$ipset 2>/dev/null | grep -c '^[0-9]' || echo 0)
                echo \"\$ipset:\$count\"
            done
        " 2>/dev/null)

        OUTPUT="$OUTPUT\n**ipset IPs:**\n"
        while IFS=: read -r ipset count; do
            [ -z "$ipset" ] && continue
            OUTPUT="$OUTPUT- $ipset: $count IPs\n"
        done <<< "$IPSET_STATUS"

        # Streaming Devices
        DEVICES=$(ssh $SSH_OPTS root@$RUTX_HOST "cat /root/multivpn/config 2>/dev/null | grep STREAMING_DEVICES | cut -d= -f2 | tr -d '\"'" 2>/dev/null)
        OUTPUT="$OUTPUT\n**Streaming Devices:** $DEVICES"

        # Routing Rules
        RULES_OK=$(ssh $SSH_OPTS root@$RUTX_HOST "ip rule show | grep -c 'fwmark 0x1'" 2>/dev/null)
        if [ "$RULES_OK" -lt 3 ]; then
            OUTPUT="$OUTPUT\n\n**Routing Rules:** Unvollstaendig ($RULES_OK/3)"
            PROBLEMS=$((PROBLEMS + 1))
        fi

        # Titel basierend auf Problemen
        if [ $PROBLEMS -eq 0 ]; then
            TITLE="Multi-VPN Diagnose: Alles OK"
        else
            TITLE="Multi-VPN Diagnose: $PROBLEMS Problem(e)"
        fi

        send_notification "$TITLE" "$OUTPUT" "multivpn_check"
        ;;
    *)
        echo "Usage: $0 {on|off|status|check|provision|cleanup|devices} [args]"
        exit 1
        ;;
esac
