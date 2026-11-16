#!/usr/bin/env bash
#
# Project Sisyphus - make THIS Linux host the single time master for the lab.
# Use this ONLY if you want a Linux box to be the clock source instead of the
# Windows Splunk indexer (set-time-master-windows.ps1) or pfSense's NTP service.
# Serves its own clock even with no upstream internet, so every machine agrees.
#
# Usage:   sudo ./set-time-master-linux.sh

set -uo pipefail

echo "[*] Installing chrony..."
sudo apt-get update -qq && sudo apt-get install -y chrony

echo "[*] Configuring chrony to serve the lab subnets..."
sudo tee /etc/chrony/conf.d/sisyphus.conf >/dev/null <<'EOF'
# Serve this host's own clock to the lab even with no upstream internet source.
local stratum 8
# Allow the Blue subnets to sync from us.
allow 192.168.1.0/24
allow 10.1.1.0/28
EOF

sudo systemctl restart chrony 2>/dev/null || sudo systemctl restart chronyd 2>/dev/null || true
sudo ufw allow 123/udp 2>/dev/null || true

echo "[*] Served clients (may be empty until clients sync):"
chronyc clients 2>/dev/null || true
MYIP="$(ip -o -4 route show to default | awk '{print $5; exit}' | xargs -I{} ip -o -4 addr show {} | awk '{print $4}' | cut -d/ -f1 | head -n1)"
echo "[OK] This host now serves NTP. Point clients at it:  sudo ./set-time-client.sh ${MYIP:-<this-ip>}"
