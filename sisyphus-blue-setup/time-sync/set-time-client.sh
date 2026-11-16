#!/usr/bin/env bash
#
# Project Sisyphus - point a Linux host's clock at the single time master.
# Run on EACH Linux box that is NOT the master (DMZ Apache, persephone, etc).
# Keeps log timestamps + Splunk alert windows aligned so scheduled alerts fire.
#
# Usage:   sudo ./set-time-client.sh [MASTER_IP]
#          (MASTER_IP defaults to the Splunk indexer 192.168.1.103)

set -uo pipefail
MASTER="${1:-192.168.1.103}"

echo "[*] Pointing systemd-timesyncd at ${MASTER}"
sudo tee /etc/systemd/timesyncd.conf >/dev/null <<EOF
[Time]
NTP=${MASTER}
FallbackNTP=${MASTER}
EOF

sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd 2>/dev/null || true
sleep 3

echo "[*] Clock status:"
timedatectl status | grep -E "Local time|Time zone|System clock synchronized|NTP service" || true
echo "[OK] Synced to ${MASTER}. Re-run after a reboot if the clock drifts."
