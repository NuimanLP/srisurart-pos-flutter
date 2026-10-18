<#
Installs the mob04 PC watchdog for the CURRENT user (no admin needed):
data folder (owner-only ACL), CA copy, Scheduled Task "Srisurart mob04 watchdog" every 5 minutes.
Does NOT write the Discord webhook - it prints how. Uninstall: -Uninstall (keeps the folder).
#>
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$task = 'Srisurart mob04 watchdog'
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed task '$task'. Folder kept: delete $env:LOCALAPPDATA\srisurart-watchdog by hand if wanted."
    return
}
$dir = Join-Path $env:LOCALAPPDATA 'srisurart-watchdog'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
New-Item -ItemType Directory -Path $dir -Force | Out-Null

# owner-only: drop inheritance, grant the current user full control
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls $dir /inheritance:r /grant:r "${me}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'icacls failed' }

Copy-Item (Join-Path $repo 'frontend\assets\certs\pos-ca.crt') (Join-Path $dir 'pos-ca.crt') -Force
# the task runs a copy, so it keeps working if the repo/worktree is moved or deleted
Copy-Item (Join-Path $PSScriptRoot 'pc-watchdog.ps1') (Join-Path $dir 'pc-watchdog.ps1') -Force

$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\pc-watchdog.ps1`""
$trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $act -Trigger $trg -Settings $set -Force `
    -Description 'Pings mob04 /health/ready; Discord alert after 2 failures. See 07_CICD_DEPLOY.md 10.5' | Out-Null

Write-Host "Installed task '$task' (every 5 min, user $me). Folder: $dir"
Write-Host "NEXT: put the Discord webhook URL (one line, nothing else) in:`n  $dir\webhook.txt"
Write-Host "Until that file exists the watchdog only logs a warning. Log: $dir\watchdog.log"
