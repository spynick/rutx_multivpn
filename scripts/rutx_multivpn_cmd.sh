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
#

SSH_KEY="/config/.ssh/id_rsa"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

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
        STREAMING_DEVICES="$3"
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
        DEVICES="$2"
        ssh $SSH_OPTS root@$RUTX_HOST "/root/multivpn/manage-devices.sh set $DEVICES"
        ;;
    check)
        # Check Script hochladen und ausfuehren
        CHECK_SCRIPT="/config/packages/rutx_multivpn/scripts/rutx_multivpn_check.sh"
        if [ -f "$CHECK_SCRIPT" ]; then
            scp $SSH_OPTS "$CHECK_SCRIPT" root@$RUTX_HOST:/root/multivpn/check.sh
            ssh $SSH_OPTS root@$RUTX_HOST "chmod +x /root/multivpn/check.sh && sh /root/multivpn/check.sh"
        else
            echo "Check Script nicht gefunden: $CHECK_SCRIPT"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {on|off|status|check|provision|cleanup|devices} [args]"
        exit 1
        ;;
esac
