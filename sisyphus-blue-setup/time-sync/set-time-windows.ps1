<#
    Project Sisyphus - Windows time sync.
    Two modes:
      -AsMaster   : make THIS Windows box (the Splunk indexer 192.168.1.103) the
                    authoritative time source the whole lab syncs to. Recommended,
                    since aligning everything to the SIEM's clock is exactly what
                    keeps forwarded logs + alert windows consistent.
      (default)   : sync THIS box (e.g. the AD DC) to the master.

    Run in an ELEVATED PowerShell:
        .\set-time-windows.ps1 -AsMaster              # on the indexer .103
        .\set-time-windows.ps1 -Master 192.168.1.103  # on any other Windows box
#>
param(
    [string]$Master = "192.168.1.103",
    [string]$Upstream = "",          # optional real NTP (e.g. "au.pool.ntp.org"); blank = serve local clock
    [switch]$AsMaster
)

$ErrorActionPreference = "Stop"

if ($AsMaster) {
    Write-Host "[*] Making this host the lab time master..." -ForegroundColor Cyan
    $peer = if ($Upstream) { $Upstream } else { "time.windows.com" }
    # If isolated (no internet), it still serves its own clock as a reliable source.
    w32tm /config /manualpeerlist:"$peer" /syncfromflags:manual /reliable:yes /update | Out-Null
    # Enable the NTP server provider + announce as a reliable time source.
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer" -Name Enabled -Value 1
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -Name AnnounceFlags -Value 5
    Restart-Service w32time
    if (-not (Get-NetFirewallRule -DisplayName "NTP Server 123" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "NTP Server 123" -Direction Inbound -Action Allow `
            -Protocol UDP -LocalPort 123 | Out-Null
    }
    Write-Host "[OK] This host now serves NTP on UDP 123. Point every other machine at its IP." -ForegroundColor Green
}
else {
    Write-Host "[*] Syncing this host to master $Master..." -ForegroundColor Cyan
    w32tm /config /manualpeerlist:"$Master" /syncfromflags:manual /update | Out-Null
    Restart-Service w32time
    w32tm /resync | Out-Null
    Write-Host "[OK] Synced to $Master." -ForegroundColor Green
}

Write-Host "`n[*] Current time status:"
w32tm /query /status
