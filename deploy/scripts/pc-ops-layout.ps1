<#
Shared by install-pc-watchdog.ps1, install-pc-pull-backups.ps1 and migrate-pc-ops.ps1 (dot-sourced).
One ops root for the PC-side mob04 tools (owner decision 2026-10-18), on the BeeStation-synced drive so all of it -
secrets included, owner accepted - also lands on the shop NAS:
  bin\      the script copies the Scheduled Tasks run + pos-ca.crt   (owner-only ACL)
  config\   non-secret settings (none yet)       (owner-only ACL)
  secrets\  webhook.txt, *.env copies            (owner-only ACL)
  logs\     watchdog.log, pull.log, ssh.err
  state\    watchdog.json, pull.json             (owner-only ACL)
  backups\mob04\YYYY-MM\  pulled backup sets     (owner-only ACL - customer data, PDPA)
  README.txt
Default root everywhere: $env:SRISURART_OPS_ROOT, else D:\Beestation\Sri_POS\ops. Initialize-PcOpsRoot stores the root in
the user environment variable SRISURART_OPS_ROOT.
Not under %LOCALAPPDATA%: an MSIX-packaged launcher (e.g. the Claude desktop app) has its AppData writes virtualized
into its own package folder, which Task Scheduler cannot see (found 2026-10-18).
#>

function Protect-PcOpsOwnerOnly([string]$Dir) {
    # owner-only: drop inheritance, grant the current user full control (Set-Acl fails on this drive; icacls works)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls $Dir /inheritance:r /grant:r "${me}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Dir" }
    # files moved in from elsewhere keep their old ACL; make every child inherit from $Dir again
    if (Get-ChildItem -LiteralPath $Dir -Force | Select-Object -First 1) {
        icacls "$Dir\*" /reset /T /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed under $Dir" }
    }
}

function Set-PcOpsPinned([string[]]$Dirs) {
    # BeeStation (Windows cloud files) may dehydrate files it thinks are unused into online-only placeholders.
    # A task whose script, CA, webhook or state file is a placeholder must fetch it from the NAS first - and fails
    # when the NAS or the network is not there. attrib +P -U = "always keep on this device". Failure = warn, go on.
    # Under the callers' ErrorActionPreference=Stop, PS 5.1 turns attrib's redirected stderr into a terminating error;
    # 'Continue' + try/catch keep this step warn-and-continue.
    $ErrorActionPreference = 'Continue'
    foreach ($d in $Dirs) {
        try {
            $out = & attrib +P -U $d 2>&1
            $rc = $LASTEXITCODE
            if ($rc -eq 0 -and (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) {
                $out = & attrib +P -U "$d\*" /S /D 2>&1
                $rc = $LASTEXITCODE
            }
            if ($rc -ne 0) { Write-Warning "could not pin $d (attrib rc $rc): $($out | Select-Object -First 1)" }
        } catch { Write-Warning "could not pin ${d}: $($_.Exception.Message)" }
    }
}

function Initialize-PcOpsRoot([string]$OpsRoot) {
    foreach ($d in 'bin', 'config', 'secrets', 'logs', 'state', 'backups\mob04') {
        New-Item -ItemType Directory -Path (Join-Path $OpsRoot $d) -Force | Out-Null
    }
    # bin\ holds what the Scheduled Task executes, so it is locked like secrets\. Residual risk: the BeeStation sync
    # client runs as the owner, so anyone who can write the NAS share can still change bin\ scripts - keep NAS write
    # access limited to the owner.
    foreach ($d in 'bin', 'config', 'secrets', 'state', 'backups') { Protect-PcOpsOwnerOnly (Join-Path $OpsRoot $d) }
    Copy-Item (Join-Path $PSScriptRoot 'pc-ops-README.txt') (Join-Path $OpsRoot 'README.txt') -Force
    # a manual run of pc-watchdog.ps1 / pc-pull-backups.ps1 (no -OpsRoot) then hits the same root as the tasks
    [Environment]::SetEnvironmentVariable('SRISURART_OPS_ROOT', $OpsRoot, 'User')
    $env:SRISURART_OPS_ROOT = $OpsRoot
}

function Get-PcOpsPinDirs([string]$OpsRoot) { @('bin', 'secrets', 'state') | ForEach-Object { Join-Path $OpsRoot $_ } }
