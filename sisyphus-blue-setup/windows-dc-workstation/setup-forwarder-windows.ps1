<#
    Project Sisyphus - Blue Team telemetry setup
    TARGET: Windows hosts that are currently BLIND to the SIEM:
            - the Active Directory Domain Controller (192.168.1.100, "hades.underworld")
            - any domain-joined workstation (the real Phase 6 pivot victim)

    Installs / configures the Splunk Universal Forwarder and ships the Windows
    Security + System event logs to the indexer as index=windows. This is what
    makes the phished-credential pivot (4624/4625), Kerberos abuse (4768/4769/4771)
    and failed-logon bursts visible - none of which the Linux forwarders can see.

    PREREQUISITE: the indexer must have an index named "windows" and be receiving
    on 9997 (setup-splunk-indexer.ps1 now creates it).

    Run in an ELEVATED (Administrator) PowerShell on EACH Windows host:
        powershell -ExecutionPolicy Bypass -File .\setup-forwarder-windows.ps1

    If the UF isn't installed yet, either install the MSI first, or set
    $MsiPath / $MsiUrl below and this script will install it silently.
#>

# ===================== EDIT THESE PER ENVIRONMENT =====================
$SplunkIP   = "192.168.1.103"          # Splunk indexer IP
$FwdPort    = "9997"                    # indexer receiving port
$WinIndex   = "windows"                 # destination index (must exist on the indexer)
$MsiPath    = ""                        # local path to splunkforwarder-*-x64-release.msi (blank = skip)
$MsiUrl     = ""                        # OR a URL to download the MSI from (e.g. https://www.tafe.mst/splunkforwarder-...msi)
$UFHome     = "C:\Program Files\SplunkUniversalForwarder"
# =====================================================================

$ErrorActionPreference = "Stop"
$Splunk = Join-Path $UFHome "bin\splunk.exe"

function Say($m){ Write-Host "[*] $m" -ForegroundColor Cyan }

# --- admin password for the UF (seeds first start + authenticates the CLI) ---
$sec  = Read-Host "Set/enter the Splunk UF admin password" -AsSecureString
$Pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
          [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))

# --- 1. install the UF if it isn't already present ---
if (-not (Test-Path $Splunk)) {
    $msi = $MsiPath
    if (-not $msi -and $MsiUrl) {
        $msi = Join-Path $env:TEMP "splunkforwarder.msi"
        Say "Downloading UF MSI from $MsiUrl"
        Invoke-WebRequest -Uri $MsiUrl -OutFile $msi -UseBasicParsing
    }
    if (-not $msi -or -not (Test-Path $msi)) {
        Write-Error "UF not installed and no MSI available. Set `$MsiPath or `$MsiUrl, or install the MSI first."
        exit 1
    }
    Say "Installing Universal Forwarder (silent)..."
    # AGREETOLICENSE + seed admin so first start is non-interactive
    Start-Process msiexec.exe -Wait -ArgumentList @(
        "/i", "`"$msi`"",
        "AGREETOLICENSE=Yes",
        "SPLUNKUSERNAME=admin",
        "SPLUNKPASSWORD=$Pass",
        "LAUNCHSPLUNK=1",
        "/quiet"
    )
} else {
    Say "Universal Forwarder already installed at $UFHome."
}

if (-not (Test-Path $Splunk)) { Write-Error "splunk.exe still not found at $Splunk."; exit 1 }

$Cred = "admin:$Pass"
function Invoke-UF { param([string[]]$Args)
    Write-Host "    splunk $($Args -join ' ')" -ForegroundColor DarkGray
    & $Splunk @Args -auth $Cred | Out-Null
}

# --- 2. first start (accept licence) ---
Say "Starting forwarder"
& $Splunk start --accept-license --answer-yes --no-prompt | Out-Null

# --- 3. point at the indexer ---
Say "Adding forward-server ${SplunkIP}:${FwdPort}"
Invoke-UF @("add", "forward-server", "${SplunkIP}:${FwdPort}")

# --- 4. inputs.conf : Windows event logs -> index=windows ---
# Security = logons/Kerberos/4625; System = service + reboot context.
# Application kept for completeness. Add Sysmon below if you deploy it.
Say "Writing inputs.conf (WinEventLog Security/System/Application -> index=$WinIndex)"
$inputs = @"
[WinEventLog://Security]
disabled = 0
index = $WinIndex
# High-value IDs: 4624 logon, 4625 failed logon, 4768 TGT, 4769 service ticket,
# 4771 pre-auth failed, 4672 admin logon, 4720 user created, 4728/4732 group add.

[WinEventLog://System]
disabled = 0
index = $WinIndex

[WinEventLog://Application]
disabled = 0
index = $WinIndex

# --- Uncomment if Sysmon is installed (recommended on the workstation) ---
#[WinEventLog://Microsoft-Windows-Sysmon/Operational]
#disabled = 0
#index = $WinIndex
#renderXml = false
"@
$localDir = Join-Path $UFHome "etc\system\local"
New-Item -ItemType Directory -Force -Path $localDir | Out-Null
Set-Content -Path (Join-Path $localDir "inputs.conf") -Value $inputs -Encoding ASCII

# --- 5. run on boot + restart to pick up inputs ---
Say "Enabling boot-start + restarting"
& $Splunk enable boot-start | Out-Null
& $Splunk restart | Out-Null

Write-Host "`n================= DONE (Windows host) =================" -ForegroundColor Green
& $Splunk list forward-server 2>$null
Write-Host "Host: $env:COMPUTERNAME  ->  index=$WinIndex  @  ${SplunkIP}:${FwdPort}"
Write-Host "Verify on the indexer:  index=$WinIndex host=$env:COMPUTERNAME | stats count by sourcetype, EventCode"
Write-Host "Run this on BOTH the DC (192.168.1.100) and the pivot workstation."
Write-Host ""
Write-Host "RECOMMENDED on the indexer: install the 'Splunk Add-on for Windows'"
Write-Host "(Splunk_TA_windows) so EventCode / Account_Name / Logon_Type / "
Write-Host "Source_Network_Address extract cleanly for the S6c / S7a / S7b alerts."
Write-Host "======================================================="
