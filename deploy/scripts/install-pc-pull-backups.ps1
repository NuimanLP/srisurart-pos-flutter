<#
Installs the mob04 backup pull for the CURRENT user (no admin needed): the ops root tree (pc-ops-layout.ps1;
secrets\ and backups\ owner-only ACL - customer data, PDPA), a copy of pc-pull-backups.ps1 in bin\, and the Scheduled
Task "Srisurart mob04 backup pull" daily at 11:00 and 20:00 local (ICT; the dumps are written 03:00 and 12:00 UTC =
10:00 and 19:00 ICT), with
"run as soon as possible after a missed start", running bin\pc-pull-backups.ps1 -OpsRoot "<root>".
Also sets the user env var SRISURART_OPS_ROOT to the root, so a manual run of the script uses the same root.
Runs only while this user is logged on. Uninstall: -Uninstall (keeps folders, backups and the env var). Alerts need <root>\secrets\webhook.txt (same file as the watchdog).
Moving from the old %USERPROFILE%\srisurart-ops + mob04-backups layout: run migrate-pc-ops.ps1 once.
#>
param(
    [switch]$Uninstall,
    [string]$OpsRoot = $(if ($env:SRISURART_OPS_ROOT) { $env:SRISURART_OPS_ROOT } else { 'D:\Beestation\Sri_POS\ops' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-ops-layout.ps1')
$task = 'Srisurart mob04 backup pull'
$OpsRoot = [IO.Path]::GetFullPath($OpsRoot).TrimEnd('\')
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed task '$task'. Kept: $OpsRoot (delete by hand if wanted)."
    return
}
Initialize-PcOpsRoot $OpsRoot
$bin = Join-Path $OpsRoot 'bin'
# the task runs a copy, so it keeps working if the repo/worktree is moved or deleted
Copy-Item (Join-Path $PSScriptRoot 'pc-pull-backups.ps1') (Join-Path $bin 'pc-pull-backups.ps1') -Force
Set-PcOpsPinned (Get-PcOpsPinDirs $OpsRoot)

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
# conhost --headless (Windows 11): powershell -WindowStyle Hidden still flashed a console window every run.
# conhost does NOT pass the script's exit code on (LastTaskResult is 0 even when the script fails) - read the log.
$act = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bin\pc-pull-backups.ps1`" -OpsRoot `"$OpsRoot`""
$trg = @((New-ScheduledTaskTrigger -Daily -At '11:00'), (New-ScheduledTaskTrigger -Daily -At '20:00'))
$set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $act -Trigger $trg -Settings $set -Force `
    -Description 'Pulls mob04 nightly backups into the BeeStation-synced ops root. See 07_CICD_DEPLOY.md 7a.1 (#363)' | Out-Null

Write-Host "Installed task '$task' (daily 11:00 + 20:00, user $me). Backups: $OpsRoot\backups\mob04\YYYY-MM  Log: $OpsRoot\logs\pull.log"
if (-not (Test-Path (Join-Path $OpsRoot 'secrets\webhook.txt'))) {
    Write-Host "NOTE: no Discord webhook at $OpsRoot\secrets\webhook.txt - the pull runs but cannot alert."
}
