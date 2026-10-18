<#
Installs the mob04 PC watchdog for the CURRENT user (no admin needed): the ops root tree (pc-ops-layout.ps1;
secrets\ owner-only ACL), the script + CA copies in bin\, Scheduled Task "Srisurart mob04 watchdog" every 5 minutes
running bin\pc-watchdog.ps1 -OpsRoot "<root>".
Does NOT write the Discord webhook - it prints how. Uninstall: -Uninstall (keeps the folder).
Moving from the old %USERPROFILE%\srisurart-ops\watchdog layout: run migrate-pc-ops.ps1 once.
#>
param(
    [switch]$Uninstall,
    [string]$OpsRoot = 'D:\Beestation\Sri_POS\ops'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-ops-layout.ps1')
$task = 'Srisurart mob04 watchdog'
$OpsRoot = [IO.Path]::GetFullPath($OpsRoot).TrimEnd('\')
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed task '$task'. Folder kept: $OpsRoot (delete by hand if wanted)."
    return
}
# Not under %LOCALAPPDATA%: an MSIX-packaged launcher (e.g. the Claude desktop app) has its AppData writes
# virtualized into its own package folder, which Task Scheduler cannot see (found 2026-10-18).
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Initialize-PcOpsRoot $OpsRoot
$bin = Join-Path $OpsRoot 'bin'
Copy-Item (Join-Path $repo 'frontend\assets\certs\pos-ca.crt') (Join-Path $bin 'pos-ca.crt') -Force
# the task runs a copy, so it keeps working if the repo/worktree is moved or deleted
Copy-Item (Join-Path $PSScriptRoot 'pc-watchdog.ps1') (Join-Path $bin 'pc-watchdog.ps1') -Force
Set-PcOpsPinned (Get-PcOpsPinDirs $OpsRoot)

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
# conhost --headless (Windows 11): powershell -WindowStyle Hidden still flashed a console window every run.
# conhost does NOT pass the script's exit code on (LastTaskResult is 0 even when the script fails) - read the log.
$act = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bin\pc-watchdog.ps1`" -OpsRoot `"$OpsRoot`""
$trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $act -Trigger $trg -Settings $set -Force `
    -Description 'Pings mob04 /health/ready; Discord alert after 2 failures. See 07_CICD_DEPLOY.md 10.5' | Out-Null

Write-Host "Installed task '$task' (every 5 min, user $me). Ops root: $OpsRoot"
$hook = Join-Path $OpsRoot 'secrets\webhook.txt'
if (-not (Test-Path $hook)) {
    Write-Host "NEXT: put the Discord webhook URL (one line, nothing else) in:`n  $hook"
    Write-Host "Until that file exists the watchdog only logs a warning."
}
Write-Host "Log: $OpsRoot\logs\watchdog.log"
