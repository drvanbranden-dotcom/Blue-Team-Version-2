# Time sync — one clock for the whole lab

Splunk timestamps every event by the clock of the host that produced it, and
scheduled alerts run over **rolling time windows** (e.g. the last 6 minutes). If
two machines disagree on the time, events land outside the window and alerts
**don't fire** (or fire late) — this is why a test `logger` event earlier only
showed up under "All time". The fix is simple: point every machine at **one**
clock source so they all agree.

## The plan: pick ONE master, sync everything else to it

**Recommended master: the Splunk indexer `192.168.1.103`.** Aligning everything
to the SIEM's own clock is exactly what you want. (pfSense's built-in NTP service
or the AD DC also work — just pick one and use its IP everywhere.)

| Machine | OS | Command |
|---|---|---|
| **Master** — Splunk indexer `192.168.1.103` | Windows | `.\set-time-windows.ps1 -AsMaster` |
| DMZ Apache `10.1.1.10` | Linux | `sudo ./set-time-client.sh 192.168.1.103` |
| persephone `192.168.1.6` | Linux | `sudo ./set-time-client.sh 192.168.1.103` |
| AD DC `192.168.1.100` (optional) | Windows | `.\set-time-windows.ps1 -Master 192.168.1.103` |

> The two Linux **forwarder** scripts already do this automatically
> (`SYNC_TIME="true"`, `TIME_MASTER_IP="192.168.1.103"`), so on those boxes you
> only need `set-time-client.sh` if you want to re-sync without re-running the
> whole forwarder setup.

### Prefer a Linux master instead?
Run `sudo ./set-time-master-linux.sh` on the chosen Linux box (it serves its own
clock via chrony even with no internet), then point clients at that box's IP.

## Firewall note
The DMZ host (`10.1.1.10`) must be able to reach the master on **UDP 123**. If the
master is on the LAN (`192.168.1.103`), allow `DMZ → LAN : UDP 123` at pfSense.

## Verify it worked
- Linux:   `timedatectl status`  → "System clock synchronized: yes"
- Windows: `w32tm /query /status` → a recent "Last Successful Sync Time"
- In Splunk: a fresh `logger "zeus-time-test"` on a Linux host should appear in
  `index=os` within a minute **without** widening the time range to All time.
