<#
Offsite copy of mob04's nightly backups, pulled by a Windows PC (PowerShell 5.1) into a folder the
shop's Synology BeeStation syncs (owner decision 2026-10-18, #363). See docs/Backend_design/07_CICD_DEPLOY.md 7a.1.
Paths under -OpsRoot (layout: pc-ops-layout.ps1): backups\mob04\YYYY-MM\ (month of the <ts> in the file name),
logs\pull.log + logs\ssh.err, state\pull.json, secrets\webhook.txt. Default root: $env:SRISURART_OPS_ROOT (the
installers set it for the user), else D:\Beestation\Sri_POS\ops; the installer also passes the root in the task arguments.

Every run: ssh as `deploy` to mob04, list /opt/pos/backups/pos_{backup,images,sale_photos}_<ts>.*.sha256,
and for every backup set (same <ts>) not yet complete locally copy the missing files with scp to
<name>.partial, check the SHA-256 against the sidecar (Get-FileHash), then rename. READ-ONLY on mob04:
nothing is deleted or written there - in particular NO `.uploaded` markers (a marker would let
backup-db.sh's prune delete a dump; the dump must stay on mob04 until it expires by age).
Local retention: sets older than -KeepDays (by the <ts> in the name) are deleted, but only when a newer
verified set exists locally - and such old sets are never pulled (else retention and pull would loop daily).
.partial files on the VM are ignored.

SSH: key + known_hosts are pinned (StrictHostKeyChecking=yes against the existing known_hosts file).
Alerts (Discord, webhook only from secrets\webhook.txt, never argv, never logged): ONE message when
the 2nd consecutive day fails, or the newest verified local set is older than -StaleHours, or at once when
local config is missing (exit 4 - the task runs under conhost --headless, so an exit code alone is silent); ONE
message on recovery. Missing webhook = warning in the log, the pull still runs.
Exit codes: 0 ok, 1 mob04 unreachable / ssh failed, 2 copy or hash verification failed,
3 no verified set newer than -StaleHours, 4 local config missing (key / known_hosts / destination).
#>
param(
    [string]$OpsRoot = $(if ($env:SRISURART_OPS_ROOT) { $env:SRISURART_OPS_ROOT } else { 'D:\Beestation\Sri_POS\ops' }),
    [string]$HostName = '172.30.58.20',
    [string]$User = 'deploy',
    [string]$KeyFile = (Join-Path $env:USERPROFILE '.ssh\mob04-SriStore'),
    [string]$KnownHosts = (Join-Path $env:USERPROFILE '.ssh\known_hosts'),
    [string]$RemoteDir = '/opt/pos/backups',
    [int]$KeepDays = 30,
    [int]$StaleHours = 26
)
$ErrorActionPreference = 'Stop'

$Dest = Join-Path $OpsRoot 'backups\mob04'
$log = Join-Path $OpsRoot 'logs\pull.log'
$stateFile = Join-Path $OpsRoot 'state\pull.json'
$hookFile = Join-Path $OpsRoot 'secrets\webhook.txt'
$ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
$scp = Join-Path $env:SystemRoot 'System32\OpenSSH\scp.exe'
$errFile = Join-Path $OpsRoot 'logs\ssh.err'

function Log([string]$m) {
    try {
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.1" -Force }
        Add-Content -Path $log -Value ('{0} {1}' -f (Get-Date -Format 's'), $m)
    } catch { }
}

function Send-Discord([string]$text) {
    if (-not (Test-Path $hookFile)) { Log 'WARN webhook.txt missing - no Discord alert possible'; return $false }
    try {
        $hook = (Get-Content $hookFile -Raw).Trim()
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{ content = $text } | ConvertTo-Json -Compress))
        $r = [Net.HttpWebRequest]::Create($hook)
        $r.Method = 'POST'; $r.ContentType = 'application/json'; $r.Timeout = 15000; $r.Proxy = $null
        $s = $r.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        $r.GetResponse().Close(); return $true
    } catch { Log "ERROR discord post failed: $($_.Exception.GetType().Name)"; return $false }  # never log the URL
}

# alerting + exit (state: consecutive failed DAYS, announced). $alertNow = announce on this run, no 2nd day needed.
function Finish([int]$result, [string]$reason, [bool]$alertNow, [string]$newest) {
    $st = @{ failDays = 0; lastFailDay = $null; announced = $false }
    if (Test-Path $stateFile) {
        try { $j = Get-Content $stateFile -Raw | ConvertFrom-Json; $st = @{ failDays = [int]$j.failDays; lastFailDay = $j.lastFailDay; announced = [bool]$j.announced } } catch { Log 'WARN pull.json unreadable, reset' }
    }
    $today = Get-Date -Format 'yyyy-MM-dd'
    if ($result -eq 0) {
        if ($st.announced) {
            if (Send-Discord ([char]::ConvertFromUtf32(0x2705) + " mob04 backup pull recovered (newest set $newest)")) { Log 'INFO recovery announced' }
        }
        $st = @{ failDays = 0; lastFailDay = $null; announced = $false }
    } else {
        if ($result -ne 3 -and $st.lastFailDay -ne $today) { $st.failDays++; $st.lastFailDay = $today }
        Log "FAIL $reason (failed days in a row: $($st.failDays))"
        if (($alertNow -or $st.failDays -ge 2) -and -not $st.announced) {
            $msg = [char]::ConvertFromUtf32(0x1F534) + " mob04 backup pull: $reason (from $env:COMPUTERNAME)"
            if (Send-Discord $msg) { $st.announced = $true; Log 'INFO problem announced' }
        }
    }
    $st | ConvertTo-Json -Compress | Set-Content -Path $stateFile -Encoding UTF8
    exit $result
}

foreach ($d in 'logs', 'state') { New-Item -ItemType Directory -Path (Join-Path $OpsRoot $d) -Force | Out-Null }
foreach ($p in @($ssh, $scp, $KeyFile, $KnownHosts, $Dest)) {
    if (-not (Test-Path $p)) {
        Log "ERROR missing $p (run install-pc-pull-backups.ps1 / check the key paths)"
        Finish 4 "local config missing: $p" $true $null
    }
}

$sshOpts = @('-i', $KeyFile, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
    '-o', "UserKnownHostsFile=$KnownHosts", '-o', 'ConnectTimeout=15')
$target = "$User@$HostName"

function Month-Dir([string]$ts) { Join-Path $Dest ('{0}-{1}' -f $ts.Substring(0, 4), $ts.Substring(4, 2)) }

function Parse-Ts([string]$ts) {
    [datetime]::ParseExact($ts, "yyyyMMdd_HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}

$nameRx = '^pos_(backup|images|sale_photos)_(\d{8}_\d{6}Z)\.(sql|tar)\.gz$'
$result = 0       # worst exit code of this run
$reason = ''

# --- 1. list the sidecars on mob04 (one ssh call) -------------------------------------------------
# find, not shell globs: a glob that matches nothing (e.g. no sale-photo set yet) made grep exit 2 and the whole pull
# read as an ssh failure. find with no match prints nothing and exits 0; `true` keeps an empty/unreadable sidecar
# (grep 1/2, message in ssh.err) from failing the run. rc != 0 now means cd failed or ssh itself failed (255).
$cmd = "cd '$RemoteDir' && { find . -maxdepth 1 -type f \( -name 'pos_backup_*.sha256' -o -name 'pos_images_*.sha256' -o -name 'pos_sale_photos_*.sha256' \) -exec grep -H '' {} + ; true; }"
$ErrorActionPreference = 'Continue'   # PS 5.1 turns native stderr into a terminating error under 'Stop'
$out = & $ssh @sshOpts $target $cmd 2> $errFile
$sshRc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$remote = @{}   # file name -> expected sha256
if ($sshRc -ne 0) {
    $result = 1; $reason = "ssh to mob04 failed (rc $sshRc)"
    Log "FAIL $reason : $((Get-Content $errFile -ErrorAction SilentlyContinue | Select-Object -First 1))"
} else {
    if ((Test-Path $errFile) -and (Get-Item $errFile).Length -gt 0) { Log "WARN remote listing stderr: $((Get-Content $errFile | Select-Object -First 1))" }
    foreach ($line in @($out)) {
        if ($line -match '^(\./)?(?<side>[^:]+)\.sha256:(?<h>[0-9a-fA-F]{64})\s+\*?(?<n>\S+)\s*$') {
            $side = $Matches.side; $n = $Matches.n; $h = $Matches.h.ToLower()
            if ($n -eq $side -and $n -match $nameRx) { $remote[$n] = $h }
        }
    }
    Log "INFO mob04 lists $($remote.Count) verified-able files"
}

# --- 2. copy what is missing --------------------------------------------------------------------
$cutoff = (Get-Date).ToUniversalTime().AddDays(-$KeepDays)
if ($result -eq 0) {
    Get-ChildItem -Path $Dest -Recurse -Filter '*.partial' -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force
    $tooOld = 0
    foreach ($name in ($remote.Keys | Sort-Object)) {
        $null = $name -match $nameRx
        $ts = $Matches[2]
        if ((Parse-Ts $ts) -lt $cutoff) { $tooOld++; continue }   # local retention would delete it again
        $mdir = Month-Dir $ts
        if ((Test-Path (Join-Path $mdir $name)) -and (Test-Path (Join-Path $mdir "$name.sha256"))) { continue }
        New-Item -ItemType Directory -Path $mdir -Force | Out-Null
        Push-Location $mdir   # scp gets a relative local name (no drive-letter colon for it to misread)
        try {
            $part = "$name.partial"
            $ErrorActionPreference = 'Continue'
            & $scp @sshOpts "${target}:$RemoteDir/$name" $part 2> $errFile
            $scpRc = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            if ($scpRc -ne 0) { Log "FAIL scp $name (rc $scpRc)"; Remove-Item $part -Force -ErrorAction SilentlyContinue; $result = 2; $reason = "copy of $name failed"; continue }
            $got = (Get-FileHash -Algorithm SHA256 -Path $part).Hash.ToLower()
            if ($got -ne $remote[$name]) { Log "FAIL sha256 mismatch for $name"; Remove-Item $part -Force; $result = 2; $reason = "sha256 mismatch for $name"; continue }
            Move-Item $part $name -Force
            Set-Content -Path "$name.sha256" -Value ("{0}  {1}" -f $remote[$name], $name) -Encoding ASCII
            Log "OK $name $((Get-Item $name).Length) bytes sha256 verified"
        } finally { Pop-Location }
    }
    if ($tooOld) { Log "INFO skipped $tooOld mob04 files older than $KeepDays days (outside local retention)" }
}

# --- 3. retention + freshness (local only) ------------------------------------------------------
$sets = @{}   # ts -> $true when its dump (sql.gz + sidecar) is verified locally
foreach ($f in Get-ChildItem -Path $Dest -Recurse -File) {
    if ($f.Name -match '^pos_(backup|images|sale_photos)_(\d{8}_\d{6}Z)\.' ) {
        if (-not $sets.ContainsKey($Matches[2])) { $sets[$Matches[2]] = $false }
    }
    if ($f.Name -match '^pos_backup_(\d{8}_\d{6}Z)\.sql\.gz$' -and (Test-Path "$($f.FullName).sha256")) { $sets[$Matches[1]] = $true }
}
$verified = @($sets.Keys | Where-Object { $sets[$_] } | Sort-Object)
$newest = if ($verified.Count) { $verified[-1] } else { $null }
foreach ($ts in $sets.Keys) {
    if ((Parse-Ts $ts) -lt $cutoff -and $newest -and $ts -lt $newest) {
        Get-ChildItem -Path $Dest -Recurse -File -Filter "pos_*_$ts.*" | Remove-Item -Force
        Log "INFO retention removed local set $ts"
    }
}
Get-ChildItem -Path $Dest -Directory | Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1) } | Remove-Item -Force
$ageH = if ($newest) { [math]::Round(((Get-Date).ToUniversalTime() - (Parse-Ts $newest)).TotalHours, 1) } else { $null }
$stale = (-not $newest) -or ($ageH -gt $StaleHours)
if ($stale -and $result -eq 0) { $result = 3; $reason = "no verified backup set newer than $StaleHours h (newest: $newest)" }
Log "INFO sets verified locally: $($verified.Count), newest: $newest, age h: $ageH, exit $result"

# --- 4. alerting -------------------------------------------------------------------------------
Finish $result $reason $stale $newest
