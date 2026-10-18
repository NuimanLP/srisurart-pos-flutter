<#
Offsite copy of mob04's nightly backups, pulled by a Windows PC (PowerShell 5.1) into a folder the
shop's Synology BeeStation syncs (owner decision 2026-10-18, #363). See docs/Backend_design/07_CICD_DEPLOY.md 7a.

Every run: ssh as `deploy` to mob04, list /opt/pos/backups/pos_{backup,images,sale_photos}_<ts>.*.sha256,
and for every backup set (same <ts>) not yet complete locally copy the missing files with scp to
<name>.partial, check the SHA-256 against the sidecar (Get-FileHash), then rename. READ-ONLY on mob04:
nothing is deleted or written there - in particular NO `.uploaded` markers (a marker would let
backup-db.sh's prune delete a dump; the dump must stay on mob04 until it expires by age).
Local retention: sets older than -KeepDays (by the <ts> in the name) are deleted, but only when a newer
verified set exists locally. .partial files on the VM are ignored.

SSH: key + known_hosts are pinned (StrictHostKeyChecking=yes against the existing known_hosts file).
Alerts (Discord, webhook only from <WatchdogDir>\webhook.txt, never argv, never logged): ONE message when
the 2nd consecutive day fails, or the newest verified local set is older than -StaleHours; ONE message
on recovery. Missing webhook = warning in the log, the pull still runs.
Exit codes: 0 ok, 1 mob04 unreachable / ssh failed, 2 copy or hash verification failed,
3 no verified set newer than -StaleHours, 4 local config missing (key / known_hosts / destination).
#>
param(
    [string]$Dest = 'D:\Beestation\Sri_POS\mob04-backups',
    [string]$DataDir = (Join-Path $env:USERPROFILE 'srisurart-ops\backup-pull'),
    [string]$WatchdogDir = (Join-Path $env:USERPROFILE 'srisurart-ops\watchdog'),
    [string]$HostName = '172.30.58.20',
    [string]$User = 'deploy',
    [string]$KeyFile = (Join-Path $env:USERPROFILE '.ssh\mob04-SriStore'),
    [string]$KnownHosts = (Join-Path $env:USERPROFILE '.ssh\known_hosts'),
    [string]$RemoteDir = '/opt/pos/backups',
    [int]$KeepDays = 30,
    [int]$StaleHours = 26
)
$ErrorActionPreference = 'Stop'

$log = Join-Path $DataDir 'pull.log'
$stateFile = Join-Path $DataDir 'state.json'
$hookFile = Join-Path $WatchdogDir 'webhook.txt'
$ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
$scp = Join-Path $env:SystemRoot 'System32\OpenSSH\scp.exe'
$errFile = Join-Path $DataDir 'ssh.err'

function Log([string]$m) {
    try {
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.1" -Force }
        Add-Content -Path $log -Value ('{0} {1}' -f (Get-Date -Format 's'), $m)
    } catch { }
}

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
foreach ($p in @($ssh, $scp, $KeyFile, $KnownHosts, $Dest)) {
    if (-not (Test-Path $p)) { Log "ERROR missing $p (run install-pc-pull-backups.ps1 / check the key paths)"; exit 4 }
}

$sshOpts = @('-i', $KeyFile, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
    '-o', "UserKnownHostsFile=$KnownHosts", '-o', 'ConnectTimeout=15')
$target = "$User@$HostName"

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

function Parse-Ts([string]$ts) {
    [datetime]::ParseExact($ts, "yyyyMMdd_HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}

$nameRx = '^pos_(backup|images|sale_photos)_(\d{8}_\d{6}Z)\.(sql|tar)\.gz$'
$result = 0       # worst exit code of this run
$reason = ''

# --- 1. list the sidecars on mob04 (one ssh call) -------------------------------------------------
$cmd = "cd $RemoteDir && grep -H '' pos_backup_*.sha256 pos_images_*.sha256 pos_sale_photos_*.sha256"
$ErrorActionPreference = 'Continue'   # PS 5.1 turns native stderr into a terminating error under 'Stop'
$out = & $ssh @sshOpts $target $cmd 2> $errFile
$sshRc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$remote = @{}   # file name -> expected sha256
if ($sshRc -ne 0 -and $sshRc -ne 1) {   # grep exits 1 only when no sidecar matched at all
    $result = 1; $reason = "ssh to mob04 failed (rc $sshRc)"
    Log "FAIL $reason : $((Get-Content $errFile -ErrorAction SilentlyContinue | Select-Object -First 1))"
} else {
    foreach ($line in @($out)) {
        if ($line -match '^(?<side>[^:]+)\.sha256:(?<h>[0-9a-fA-F]{64})\s+\*?(?<n>\S+)\s*$') {
            $side = $Matches.side; $n = $Matches.n; $h = $Matches.h.ToLower()
            if ($n -eq $side -and $n -match $nameRx) { $remote[$n] = $h }
        }
    }
    Log "INFO mob04 lists $($remote.Count) verified-able files"
}

# --- 2. copy what is missing --------------------------------------------------------------------
if ($result -eq 0) {
    Push-Location $Dest
    try {
        Get-ChildItem -Filter '*.partial' -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force
        foreach ($name in ($remote.Keys | Sort-Object)) {
            if ((Test-Path $name) -and (Test-Path "$name.sha256")) { continue }
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
        }
    } finally { Pop-Location }
}

# --- 3. retention + freshness (local only) ------------------------------------------------------
$sets = @{}   # ts -> $true when its dump (sql.gz + sidecar) is verified locally
foreach ($f in Get-ChildItem -Path $Dest -File) {
    if ($f.Name -match '^pos_(backup|images|sale_photos)_(\d{8}_\d{6}Z)\.' ) {
        if (-not $sets.ContainsKey($Matches[2])) { $sets[$Matches[2]] = $false }
    }
    if ($f.Name -match '^pos_backup_(\d{8}_\d{6}Z)\.sql\.gz$' -and (Test-Path "$($f.FullName).sha256")) { $sets[$Matches[1]] = $true }
}
$verified = @($sets.Keys | Where-Object { $sets[$_] } | Sort-Object)
$newest = if ($verified.Count) { $verified[-1] } else { $null }
$cutoff = (Get-Date).ToUniversalTime().AddDays(-$KeepDays)
foreach ($ts in $sets.Keys) {
    if ((Parse-Ts $ts) -lt $cutoff -and $newest -and $ts -lt $newest) {
        Get-ChildItem -Path $Dest -File -Filter "pos_*_$ts.*" | Remove-Item -Force
        Log "INFO retention removed local set $ts"
    }
}
$ageH = if ($newest) { [math]::Round(((Get-Date).ToUniversalTime() - (Parse-Ts $newest)).TotalHours, 1) } else { $null }
$stale = (-not $newest) -or ($ageH -gt $StaleHours)
if ($stale -and $result -eq 0) { $result = 3; $reason = "no verified backup set newer than $StaleHours h (newest: $newest)" }
Log "INFO sets verified locally: $($verified.Count), newest: $newest, age h: $ageH, exit $result"

# --- 4. alerting (state: consecutive failed DAYS, announced) -----------------------------------
$st = @{ failDays = 0; lastFailDay = $null; announced = $false }
if (Test-Path $stateFile) {
    try { $j = Get-Content $stateFile -Raw | ConvertFrom-Json; $st = @{ failDays = [int]$j.failDays; lastFailDay = $j.lastFailDay; announced = [bool]$j.announced } } catch { Log 'WARN state.json unreadable, reset' }
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
    if (($stale -or $st.failDays -ge 2) -and -not $st.announced) {
        $msg = [char]::ConvertFromUtf32(0x1F534) + " mob04 backup pull: $reason (from $env:COMPUTERNAME)"
        if (Send-Discord $msg) { $st.announced = $true; Log 'INFO problem announced' }
    }
}
$st | ConvertTo-Json -Compress | Set-Content -Path $stateFile -Encoding UTF8
exit $result
