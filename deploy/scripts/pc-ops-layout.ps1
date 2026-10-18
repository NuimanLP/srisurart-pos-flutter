<#
Shared by install-pc-watchdog.ps1, install-pc-pull-backups.ps1 and migrate-pc-ops.ps1 (dot-sourced).
One ops root for the PC-side mob04 tools (owner decision 2026-10-18), on the BeeStation-synced drive so all of it -
secrets included, owner accepted - also lands on the shop NAS:
  bin\      the script copies the Scheduled Tasks run + pos-ca.crt
  config\   non-secret settings (none yet)
  secrets\  webhook.txt, *.env copies            (owner-only ACL)
  logs\     watchdog.log, pull.log, ssh.err
  state\    watchdog.json, pull.json
  backups\mob04\YYYY-MM\  pulled backup sets     (owner-only ACL - customer data, PDPA)
  README.txt
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
    foreach ($d in $Dirs) {
        $out = & attrib +P -U $d 2>&1
        $rc = $LASTEXITCODE
        if ($rc -eq 0 -and (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) {
            $out = & attrib +P -U "$d\*" /S /D 2>&1
            $rc = $LASTEXITCODE
        }
        if ($rc -ne 0) { Write-Warning "could not pin $d (attrib rc $rc): $($out | Select-Object -First 1)" }
    }
}

function Initialize-PcOpsRoot([string]$OpsRoot) {
    foreach ($d in 'bin', 'config', 'secrets', 'logs', 'state', 'backups\mob04') {
        New-Item -ItemType Directory -Path (Join-Path $OpsRoot $d) -Force | Out-Null
    }
    Protect-PcOpsOwnerOnly (Join-Path $OpsRoot 'secrets')
    Protect-PcOpsOwnerOnly (Join-Path $OpsRoot 'backups')
    Copy-Item (Join-Path $PSScriptRoot 'pc-ops-README.txt') (Join-Path $OpsRoot 'README.txt') -Force
}

function Get-PcOpsPinDirs([string]$OpsRoot) { @('bin', 'secrets', 'state') | ForEach-Object { Join-Path $OpsRoot $_ } }
