<#
    Project Sisyphus - Blue Team SIEM setup
    TARGET: Windows Splunk Enterprise indexer (e.g. "Davids Splunky Blue Good Time", 192.168.1.103)

    PREREQUISITE: Splunk Enterprise is already INSTALLED (run the MSI first).
    This script CONFIGURES it: creates indexes, enables the forwarder receiver,
    adds the pfSense syslog input, and opens the Windows firewall ports.

    Run in an elevated (Administrator) PowerShell:
        powershell -ExecutionPolicy Bypass -File .\setup-splunk-indexer.ps1
#>

# ================= EDIT IF NEEDED =================
$SplunkHome = "C:\Program Files\Splunk"
$Indexes    = @("network", "web", "os", "windows")

# --- manual static IP for this Blue machine (the Splunk indexer) ---
$SetStaticIP    = $false            # set to $true to APPLY the static IP below
$StaticIP       = "192.168.1.103"   # the indexer's assigned IP
$PrefixLength   = 24                # 192.168.1.0/24
$Gateway        = "192.168.1.1"     # pfSense LAN interface
$DnsServer      = "172.17.124.219"  # lab DNS
$InterfaceAlias = "Ethernet"        # check with: Get-NetIPConfiguration
# =================================================

if ($SetStaticIP) {
    Write-Host "[*] Setting static IP $StaticIP/$PrefixLength on '$InterfaceAlias'..." -ForegroundColor Cyan
    if (-not (Get-NetIPAddress -IPAddress $StaticIP -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $StaticIP `
            -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
    }
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $DnsServer
    Write-Host "[OK] Static IP applied. (This box is the clock master — run set-time-windows.ps1 -AsMaster.)" -ForegroundColor Green
}

$Splunk = Join-Path $SplunkHome "bin\splunk.exe"
if (-not (Test-Path $Splunk)) {
    Write-Error "splunk.exe not found at $Splunk. Install Splunk Enterprise (MSI) first."
    exit 1
}

# Splunk admin creds (used for the CLI calls). Format: admin:password
$Cred = Read-Host "Enter Splunk admin credentials as user:password (e.g. admin:yourpass)"

function Invoke-Splunk { param([string[]]$Args)
    Write-Host "[*] splunk $($Args -join ' ')" -ForegroundColor Cyan
    & $Splunk @Args -auth $Cred
}

# --- 1. indexes ---
foreach ($idx in $Indexes) {
    Invoke-Splunk @("add", "index", $idx)
}

# --- 2. enable forwarder receiving on 9997 ---
Invoke-Splunk @("enable", "listen", "9997")

# --- 3. pfSense syslog input on UDP 514 -> index=network, sourcetype=pfsense ---
Invoke-Splunk @("add", "udp", "514", "-sourcetype", "pfsense", "-index", "network")

# --- 4. Windows firewall: allow 8000 (web), 9997 (forwarders), 514 (syslog) ---
$rules = @(
    @{ Name = "Splunk Web 8000";        Proto = "TCP"; Port = 8000 },
    @{ Name = "Splunk Forwarder 9997";  Proto = "TCP"; Port = 9997 },
    @{ Name = "Splunk Syslog 514";      Proto = "UDP"; Port = 514  }
)
foreach ($r in $rules) {
    if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
        Write-Host "[*] Firewall allow $($r.Proto)/$($r.Port)" -ForegroundColor Cyan
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
            -Protocol $r.Proto -LocalPort $r.Port | Out-Null
    } else {
        Write-Host "[=] Firewall rule '$($r.Name)' already exists" -ForegroundColor DarkGray
    }
}

# --- 5. restart Splunk to apply ---
Invoke-Splunk @("restart")

Write-Host "`n================= DONE (Splunk indexer) =================" -ForegroundColor Green
Write-Host "Indexes: $($Indexes -join ', ')"
Write-Host "Receiver: TCP 9997   |   pfSense syslog: UDP 514 -> index=network"
Write-Host "Check listeners:  netstat -ano | findstr `":9997 :514`""
Write-Host "Then point forwarders + pfSense at this host's IP."
Write-Host "========================================================="
