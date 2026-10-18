<#
Installs the mob04 backup pull for the CURRENT user (no admin needed): log/state folder and destination
folder (both owner-only ACL - customer data, PDPA), a copy of pc-pull-backups.ps1, and the Scheduled Task
"Srisurart mob04 backup pull" daily at 11:00 local (ICT; the dump is written 03:00 UTC = 10:00 ICT),
with "run as soon as possible after a missed start". Uninstall: -Uninstall (keeps folders and backups).
Needs the same webhook file as the watchdog for alerts: %USERPROFILE%\srisurart-ops\watchdog\webhook.txt.
#>
param(
    [switch]$Uninstall,
    [string]$Dest = 'D:\Beestation\Sri_POS\mob04-backups'
)
$ErrorActionPreference = 'Stop'
$task = 'Srisurart mob04 backup pull'
$dir = Join-Path $env:USERPROFILE 'srisurart-ops\backup-pull'
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed task '$task'. Kept: $dir and $Dest (delete by hand if wanted)."
    return
}
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
foreach ($d in @($dir, $Dest)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    # owner-only: drop inheritance, grant the current user full control
    icacls $d /inheritance:r /grant:r "${me}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $d" }
}
# the task runs a copy, so it keeps working if the repo/worktree is moved or deleted
Copy-Item (Join-Path $PSScriptRoot 'pc-pull-backups.ps1') (Join-Path $dir 'pc-pull-backups.ps1') -Force

$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\pc-pull-backups.ps1`" -Dest `"$Dest`""
$trg = New-ScheduledTaskTrigger -Daily -At '11:00'
$set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $act -Trigger $trg -Settings $set -Force `
    -Description 'Pulls mob04 nightly backups into the BeeStation-synced folder. See 07_CICD_DEPLOY.md 7a (#363)' | Out-Null

Write-Host "Installed task '$task' (daily 11:00, user $me). Destination: $Dest  Log: $dir\pull.log"
if (-not (Test-Path (Join-Path $env:USERPROFILE 'srisurart-ops\watchdog\webhook.txt'))) {
    Write-Host "NOTE: no Discord webhook at $env:USERPROFILE\srisurart-ops\watchdog\webhook.txt - the pull runs but cannot alert."
}
