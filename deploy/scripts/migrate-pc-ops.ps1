<#
One-time move of the PC-side mob04 tools' files into the single ops root (owner decision 2026-10-18; layout in
pc-ops-layout.ps1). Run it with both tasks uninstalled, then run both installers with the same -OpsRoot.
Idempotent: a second run finds nothing to move.

  <OldHome>\watchdog\webhook.txt          -> secrets\webhook.txt
  <OldHome>\watchdog\state.json           -> state\watchdog.json
  <OldHome>\backup-pull\state.json        -> state\pull.json
  <OldHome>\watchdog\watchdog.log(.1)     -> logs\   (appended before any newer log already there)
  <OldHome>\backup-pull\pull.log(.1), ssh.err -> logs\
  <OldBackups>\pos_*_<ts>.*               -> backups\mob04\YYYY-MM\ (month of <ts>), then every data file is checked
                                             against its .sha256
  <OldEnvDir>\mob04-demo.env, mob04-pos-env-*.env -> secrets\
The old script/CA copies are deleted (the installers copy fresh ones). The old folders are removed only when empty and
only when every step, including every hash check, passed. File contents are never printed.
Exit 0 = all moved and verified, 1 = something was left in place (see the WARN lines).
#>
param(
    [string]$OpsRoot = 'D:\Beestation\Sri_POS\ops',
    [string]$OldHome = (Join-Path $env:USERPROFILE 'srisurart-ops'),
    [string]$OldBackups = 'D:\Beestation\Sri_POS\mob04-backups',
    [string]$OldEnvDir = 'D:\Beestation\Sri_POS'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pc-ops-layout.ps1')
$OpsRoot = [IO.Path]::GetFullPath($OpsRoot).TrimEnd('\')
Initialize-PcOpsRoot $OpsRoot
$problems = 0

function Same-Hash([string]$a, [string]$b) { (Get-FileHash -LiteralPath $a).Hash -eq (Get-FileHash -LiteralPath $b).Hash }

function Move-One([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $src)) { return }
    $n = Split-Path $src -Leaf
    if (Test-Path -LiteralPath $dst) {
        if (Same-Hash $src $dst) { Remove-Item -LiteralPath $src -Force; Write-Host "  = $n (already there, old copy removed)" }
        else { Write-Warning "$n differs from the file already at $dst - left in place"; $script:problems++ }
        return
    }
    Move-Item -LiteralPath $src -Destination $dst
    Write-Host "  -> $dst"
}

function Merge-Log([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $src)) { return }
    if (Test-Path -LiteralPath $dst) {
        $bytes = [IO.File]::ReadAllBytes($src) + [IO.File]::ReadAllBytes($dst)
        [IO.File]::WriteAllBytes($dst, $bytes)
        Remove-Item -LiteralPath $src -Force
        Write-Host "  -> $dst (old lines prepended)"
    } else { Move-Item -LiteralPath $src -Destination $dst; Write-Host "  -> $dst" }
}

$wd = Join-Path $OldHome 'watchdog'
$bp = Join-Path $OldHome 'backup-pull'
$sec = Join-Path $OpsRoot 'secrets'; $st = Join-Path $OpsRoot 'state'; $lg = Join-Path $OpsRoot 'logs'

Write-Host "secrets / state / logs from $OldHome"
Move-One (Join-Path $wd 'webhook.txt') (Join-Path $sec 'webhook.txt')
Move-One (Join-Path $wd 'state.json') (Join-Path $st 'watchdog.json')
Move-One (Join-Path $bp 'state.json') (Join-Path $st 'pull.json')
foreach ($p in @(@($wd, 'watchdog.log.1'), @($wd, 'watchdog.log'), @($bp, 'pull.log.1'), @($bp, 'pull.log'), @($bp, 'ssh.err'))) {
    Merge-Log (Join-Path $p[0] $p[1]) (Join-Path $lg $p[1])
}
foreach ($f in @((Join-Path $wd 'pc-watchdog.ps1'), (Join-Path $wd 'pos-ca.crt'), (Join-Path $bp 'pc-pull-backups.ps1'))) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }   # reproducible copies; the installers write bin\
}

Write-Host "env copies from $OldEnvDir"
foreach ($f in @(Get-ChildItem -LiteralPath $OldEnvDir -File -Filter '*.env' | Where-Object { $_.Name -eq 'mob04-demo.env' -or $_.Name -like 'mob04-pos-env-*.env' })) {
    Move-One $f.FullName (Join-Path $sec $f.Name)
}

$moved = @()
if (Test-Path -LiteralPath $OldBackups) {
    Write-Host "backups from $OldBackups"
    foreach ($f in @(Get-ChildItem -LiteralPath $OldBackups -File -Force)) {
        if ($f.Name -notmatch '^pos_(backup|images|sale_photos)_(\d{4})(\d{2})\d{2}_\d{6}Z\.') {
            Write-Warning "$($f.Name) is not a backup-set file - left in place"; $problems++; continue
        }
        $mdir = Join-Path $OpsRoot ('backups\mob04\{0}-{1}' -f $Matches[2], $Matches[3])
        New-Item -ItemType Directory -Path $mdir -Force | Out-Null
        $dst = Join-Path $mdir $f.Name
        Move-One $f.FullName $dst
        if ($f.Name -notlike '*.sha256') { $moved += $dst }
    }
}

Write-Host "verifying $($moved.Count) moved backup files against their .sha256"
$ok = 0
foreach ($dst in $moved) {
    $side = "$dst.sha256"
    if (-not (Test-Path -LiteralPath $dst) -or -not (Test-Path -LiteralPath $side)) { Write-Warning "missing file or sidecar for $(Split-Path $dst -Leaf)"; $problems++; continue }
    $want = ((Get-Content -LiteralPath $side -TotalCount 1) -split '\s+')[0].ToLower()
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $dst).Hash.ToLower()
    if ($got -eq $want) { $ok++ } else { Write-Warning "sha256 MISMATCH $(Split-Path $dst -Leaf)"; $problems++ }
}
Write-Host "  verified $ok / $($moved.Count)"

# files moved in keep their old ACL - make them inherit the owner-only ACL again, then pin bin/secrets/state
Protect-PcOpsOwnerOnly $sec
Protect-PcOpsOwnerOnly (Join-Path $OpsRoot 'backups')
Set-PcOpsPinned (Get-PcOpsPinDirs $OpsRoot)

if ($problems -gt 0) { Write-Warning "$problems problem(s) - old folders kept"; exit 1 }
foreach ($d in @($wd, $bp, $OldHome, $OldBackups)) {
    if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $d -Force; Write-Host "removed empty $d"
    } elseif (Test-Path -LiteralPath $d) { Write-Warning "$d not empty - kept" }
}
exit 0
