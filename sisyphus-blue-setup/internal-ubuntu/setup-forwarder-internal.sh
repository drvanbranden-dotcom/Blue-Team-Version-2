#!/usr/bin/env bash
#
# Project Sisyphus - Blue Team telemetry setup
# TARGET: Internal pivot host = persephone @ 192.168.1.6 (the SSH pivot target
#         the red playbook logs into). Run this ON that box. Confirmed 11/11/26.
# Installs the Splunk Universal Forwarder, points it at the indexer,
# forwards OS logs only (no Apache here), and loads auditd file-watch rules.
#
# Run on the internal Ubuntu host:   sudo ./setup-forwarder-internal.sh

set -uo pipefail

### ================= EDIT THESE PER ENVIRONMENT =================
SPLUNK_IP="192.168.1.103"      # Splunk indexer IP
FWD_PORT="9997"                # indexer receiving port
UF_URL=""                      # URL to splunkforwarder-*.tgz (blank = use a local .tgz in this folder)
DOWNLOAD_USER=""               # HTTP basic-auth user for UF_URL (blank = no auth; password prompted)

# --- static IP (manual addressing for the Blue machines) ---
SET_STATIC_IP="false"          # set to "true" to APPLY the static IP below (changes networking!)
STATIC_IP="192.168.1.6"        # this machine's assigned IP - persephone (internal SSH pivot target)
PREFIX="24"                    # CIDR prefix -> 192.168.1.0/24
GATEWAY="192.168.1.1"          # pfSense LAN interface
DNS_SERVER="172.17.124.219"    # lab DNS (TAFE internal)
IFACE=""                       # network interface; blank = auto-detect the default route's NIC

# --- clock sync (keeps log timestamps + alert windows aligned) ---
SYNC_TIME="true"               # sync this host's clock to the master below
TIME_MASTER_IP="192.168.1.103" # the single clock master (Splunk indexer) - must serve NTP (see time-sync/)
### =============================================================

SPLUNK_HOME="/opt/splunkforwarder"
SPLUNK="$SPLUNK_HOME/bin/splunk"
say(){ echo -e "\n[*] $*"; }

# --- 0a. apply the manual static IP (optional - changes networking, may drop SSH) ---
if [[ "$SET_STATIC_IP" == "true" ]]; then
  IFACE="${IFACE:-$(ip -o -4 route show to default | awk '{print $5; exit}')}"
  say "Setting static IP ${STATIC_IP}/${PREFIX} on ${IFACE} (gw ${GATEWAY}, dns ${DNS_SERVER})"
  sudo tee /etc/netplan/60-sisyphus.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses: [${STATIC_IP}/${PREFIX}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS_SERVER}]
EOF
  sudo chmod 600 /etc/netplan/60-sisyphus.yaml
  sudo netplan apply || echo "WARNING: netplan apply failed - check /etc/netplan/60-sisyphus.yaml"
fi

# --- 0b. sync the clock to the single master so log timestamps + alert windows align ---
if [[ "$SYNC_TIME" == "true" ]]; then
  say "Syncing clock to ${TIME_MASTER_IP} (NTP)"
  sudo tee /etc/systemd/timesyncd.conf >/dev/null <<EOF
[Time]
NTP=${TIME_MASTER_IP}
EOF
  sudo timedatectl set-ntp true
  sudo systemctl restart systemd-timesyncd 2>/dev/null || true
  sleep 2; timedatectl status | grep -E "Local time|synchronized" || true
fi

: "${SPLUNK_ADMIN_PASS:=}"
if [[ -z "$SPLUNK_ADMIN_PASS" ]]; then
  read -s -p "Splunk forwarder admin password to set/use: " SPLUNK_ADMIN_PASS; echo
fi

# --- 1. obtain + extract the Universal Forwarder (.tgz) ---
if [[ ! -x "$SPLUNK" ]]; then
  TGZ="$(ls splunkforwarder-*.tgz 2>/dev/null | head -n1 || true)"
  if [[ -z "$TGZ" && -n "$UF_URL" ]]; then
    say "Downloading forwarder from $UF_URL"
    if [[ -n "$DOWNLOAD_USER" ]]; then
      wget --no-check-certificate --user="$DOWNLOAD_USER" --ask-password -O splunkforwarder.tgz "$UF_URL"
    else
      wget --no-check-certificate -O splunkforwarder.tgz "$UF_URL"
    fi
    TGZ="splunkforwarder.tgz"
  fi
  [[ -z "$TGZ" ]] && { echo "ERROR: no splunkforwarder-*.tgz found and UF_URL is blank."; exit 1; }
  say "Extracting $TGZ to /opt"
  sudo tar xzf "$TGZ" -C /opt
else
  say "Forwarder already installed at $SPLUNK_HOME - skipping download."
fi

# --- 2. seed admin creds for a non-interactive first start ---
if [[ ! -f "$SPLUNK_HOME/etc/passwd" ]]; then
  sudo tee "$SPLUNK_HOME/etc/system/local/user-seed.conf" >/dev/null <<EOF
[user_info]
USERNAME = admin
PASSWORD = $SPLUNK_ADMIN_PASS
EOF
fi

# --- 3. first start + accept licence ---
say "Starting forwarder"
sudo "$SPLUNK" start --accept-license --answer-yes --no-prompt

# --- 4. point at the indexer ---
say "Adding forward-server ${SPLUNK_IP}:${FWD_PORT}"
sudo "$SPLUNK" add forward-server "${SPLUNK_IP}:${FWD_PORT}" -auth "admin:${SPLUNK_ADMIN_PASS}"

# --- 5. run as root on boot (needs root to read auth.log / audit.log) ---
say "Enabling boot-start as root"
sudo "$SPLUNK" stop
sudo "$SPLUNK" enable boot-start -user root || sudo "$SPLUNK" enable boot-start -user root -systemd-managed 1
sudo "$SPLUNK" start

# --- 6. inputs.conf (OS logs only - no Apache on the internal host) ---
say "Writing inputs.conf (os only)"
sudo tee "$SPLUNK_HOME/etc/system/local/inputs.conf" >/dev/null <<EOF
[monitor:///var/log/auth.log]
sourcetype = linux_secure
index = os

[monitor:///var/log/audit/audit.log]
sourcetype = linux_audit
index = os

[monitor:///var/log/syslog]
sourcetype = syslog
index = os
EOF

# --- 7. auditd file-watch rules (no /var/www/html - no web app here) ---
# Command execution (execve) is already captured by the baseline cmd_exec/root_cmd_exec
# rules; we add only file watches and flush+reload to avoid the "Rule exists" abort.
say "Installing auditd + zeus file-watch rules"
sudo apt-get install -y auditd >/dev/null 2>&1 || sudo apt-get install -y auditd
sudo tee /etc/audit/rules.d/zeus.rules >/dev/null <<'EOF'
-w /etc/passwd -p r -k zeus_sensitive
-w /etc/shadow -p r -k zeus_sensitive
-w /etc/sudoers -p wa -k zeus_sudoers
-w /etc/sudoers.d -p wa -k zeus_sudoers
-w /home -p r -k zeus_home
EOF
sudo auditctl -D || true
sudo augenrules --load || true

# --- 8. restart forwarder + report ---
say "Restarting forwarder"
sudo "$SPLUNK" restart
echo
echo "============== DONE (internal pivot host) =============="
sudo "$SPLUNK" list forward-server 2>/dev/null || true
echo "auditd rules loaded:"
sudo auditctl -l | grep zeus_ || echo "  (no zeus_ watches - check output above)"
echo "Verify on Splunk (${SPLUNK_IP}):  index=os host=$(hostname)"
echo "======================================================="
