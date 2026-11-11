# Project Sisyphus — Blue Team Lab Setup

Automated setup for the **Book of Zeus** Blue Team telemetry pipeline (IRTx / VU23220 /
VU23221). Stands up Splunk and the log forwarding for every machine so a fresh VM
environment is wired for detection in minutes instead of an afternoon.

> Authorised TAFE lab / isolated test environment use only.

## Topology

```
  Red Kali (203.0.113.x)
        │  attack
        ▼
  pfSense ── syslog/514 ─────────────┐
        │                            ▼
  DMZ Apache host  ── UF/9997 ──►  Splunk indexer  (index: network / web / os)
  (10.1.1.10)                      (192.168.1.103)
        │ SSH pivot                   ▲
        ▼                             │
  persephone (SSH target) ── UF/9997 ─┘
  (192.168.1.6)

  [optional] Windows DC (192.168.1.100) ── Windows UF ──► index=windows
```

The live attack pivots over **SSH to persephone (192.168.1.6)** using the phished
AD credential — that's where the internal forwarder runs. The Windows DC is a
credential backend, not a network-attacked target, so Windows telemetry
(`index=windows`, the S6c/S7a/S7b alerts) is **optional depth**, not required.

## Repo layout — set up each machine from its own folder

| Folder | Machine | What it does |
|---|---|---|
| `splunk-indexer-windows/` | Splunk Enterprise (Windows) | `setup-splunk-indexer.ps1` — indexes, 9997 receiver, 514 syslog input, firewall |
| `dmz-apache-ubuntu/` | DMZ / vulnerable Apache host | `setup-forwarder-dmz.sh` — UF + Apache & OS logs + auditd watches |
| `internal-ubuntu/` | Internal Linux pivot target | `setup-forwarder-internal.sh` — UF + OS logs + auditd watches |
| `windows-dc-workstation/` _(OPTIONAL)_ | AD DC (192.168.1.100) + workstation | `setup-forwarder-windows.ps1` — Windows UF → `index=windows`. Only for the optional S6c/S7a/S7b depth; the live pivot is SSH, so this isn't needed for the exercise |
| `pfsense/` | pfSense firewall | `README-pfsense-syslog.md` — manual remote-syslog steps (UI-only) |
| `splunk-apps/` | indexer / forwarders | `README-splunk-tas.md` — pfSense & Linux TAs for field extraction |
| `time-sync/` | all machines | one-clock-source scripts so log timestamps + alert windows line up |

## Manual IP addressing (Blue machines)

Each setup script has a static-IP block in its CONFIG header, pre-filled with the
machine's assigned address. Set `SET_STATIC_IP="true"` (Linux) / `$SetStaticIP=$true`
(Windows) to apply it — **this changes networking and may drop an SSH session**, so
it's off by default.

| Machine | IP | Prefix | Gateway |
|---|---|---|---|
| Splunk indexer | `192.168.1.103` | /24 | `192.168.1.1` |
| DMZ Apache (dmzUbuntu) | `10.1.1.10` | /28 | `10.1.1.1` |
| persephone (SSH pivot) | `192.168.1.6` | /24 | `192.168.1.1` |
| AD DC _(optional)_ | `192.168.1.100` | /24 | `192.168.1.1` |

Lab DNS: `172.17.124.219` (reaches `www.tafe.mst`).

## Order of operations

1. **Indexer first** — install Splunk (MSI), then run `setup-splunk-indexer.ps1` (as Admin).
2. **Clock master** — on the indexer, run `time-sync/set-time-windows.ps1 -AsMaster` so
   every other machine can sync to it (see `time-sync/`). Without one shared clock,
   events land outside the alert windows and alerts don't fire.
3. **TAs** — install the pfSense + Linux TAs on the indexer (`splunk-apps/`).
4. **pfSense** — point remote syslog at the indexer (`pfsense/`).
5. **Forwarders** — run the matching `setup-forwarder-*.sh` on each Ubuntu host
   (DMZ Apache `10.1.1.10` and persephone `192.168.1.6`). These already sync their
   clock to the master automatically. The Windows UF is OPTIONAL.
6. **Verify** — on the indexer, each of these should return data:
   ```
   index=network sourcetype=pfsense
   index=web sourcetype=access_combined
   index=os sourcetype=linux_secure
   index=os sourcetype=linux_audit
   ```

## Before you run — edit the CONFIG block at the top of each script

Set at minimum:
- `SPLUNK_IP` — the indexer's IP on the new network
- `UF_URL` + `DOWNLOAD_USER` — where the Universal Forwarder `.tgz` is served (the TAFE
  `www.tafe.mst` server needs DNS set to the lab DNS IP; the forwarder is a **`.tgz`**, not a `.deb`)
- `APACHE_LOG_DIR` (DMZ script) — defaults to `/opt/apache-2.4.49/logs` (the red-team
  `install_apache.sh` build prefix); the script also **auto-detects** the real
  `access_log` so a wrong prefix can't silently mute `index=web`
- `SET_STATIC_IP` — leave `"false"` to keep current networking, or `"true"` to apply the
  machine's assigned static IP (pre-filled in the CONFIG block)
- `SYNC_TIME` / `TIME_MASTER_IP` — on by default; syncs the host's clock to `192.168.1.103`
  (run the master first: `time-sync/set-time-windows.ps1 -AsMaster`)

## Notes baked in from real setup

- Universal Forwarder on Linux is the **`.tgz`** → extract to `/opt`, **not** `dpkg`.
- Forwarder runs **as root** (`-user root`) so it can read `/var/log/auth.log` and
  `/var/log/audit/audit.log` — otherwise the OS alerts get no data.
- The lab image already ships auditd **execve** rules (`cmd_exec` / `root_cmd_exec` /
  `wget_exec`). auditd de-dupes syscall rules by syscall (not key), so the scripts add
  only **file watches** and `auditctl -D` + `augenrules --load` to avoid the
  "Rule exists" abort. Alert SPL uses `cmd_exec` / `root_cmd_exec` / `wget_exec` for
  command execution and `zeus_*` for file reads.
- Don't commit real credentials — the scripts prompt for the Splunk admin password
  (or read it from the `SPLUNK_ADMIN_PASS` env var) instead of hard-coding it.
```bash
chmod +x dmz-apache-ubuntu/setup-forwarder-dmz.sh internal-ubuntu/setup-forwarder-internal.sh
```
