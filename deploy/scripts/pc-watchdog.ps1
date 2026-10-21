<#
External watchdog for mob04 (runs on a Windows PC, PowerShell 5.1). Gatus runs ON mob04 and
cannot report mob04 being fully down; this can. See docs/Backend_design/07_CICD_DEPLOY.md 10.5.

Every run: GET <Url> (default https://172.30.58.20/health/ready), 10 s timeout.
 - 2nd consecutive failure  -> ONE Discord message "down since <time>"
 - first success after that -> ONE Discord message "back"
 - if discord.com is unreachable too, the PC is offline: not counted as a mob04 failure.
Also, off-VM backup freshness (covers the pull task not running at all): newest pos_backup_<ts>.sql.gz under
backups\mob04\*\ by the <ts> in its name older than -BackupStaleHours -> ONE message; ONE on recovery. Not checked in
the first 30 min after boot (the pull task catches up a missed start then).
Missing bin\pos-ca.crt -> ERROR in the log + ONE Discord message (the task runs under conhost --headless, so an exit
code alone is silent).
Paths under -OpsRoot (layout: pc-ops-layout.ps1): secrets\webhook.txt, bin\pos-ca.crt, logs\watchdog.log,
state\watchdog.json, backups\mob04\. Default root: $env:SRISURART_OPS_ROOT (the installers set it for the user), else
D:\Beestation\Sri_POS\ops; the installer also passes the root in the task arguments.
Webhook URL: only from secrets\webhook.txt (never argv, never logged). Missing = ERROR in the log + exit 0.
TLS: private CA. A cert is accepted only if its chain is built with bin\pos-ca.crt and ends
at that exact CA (thumbprint match). Certificate checks are never disabled.
#>
param(
    [string]$Url = 'https://172.30.58.20/health/ready',
    [string]$OpsRoot = $(if ($env:SRISURART_OPS_ROOT) { $env:SRISURART_OPS_ROOT } else { 'D:\Beestation\Sri_POS\ops' }),
    [int]$TimeoutSec = 10,
    [int]$BackupStaleHours = 26
)
$ErrorActionPreference = 'Stop'

$log = Join-Path $OpsRoot 'logs\watchdog.log'
$stateFile = Join-Path $OpsRoot 'state\watchdog.json'
$hookFile = Join-Path $OpsRoot 'secrets\webhook.txt'
$caFile = Join-Path $OpsRoot 'bin\pos-ca.crt'

function Log([string]$m) {
    try {
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.1" -Force }
        Add-Content -Path $log -Value ('{0} {1}' -f (Get-Date -Format 's'), $m)
    } catch { }
}

foreach ($d in 'logs', 'state') { New-Item -ItemType Directory -Path (Join-Path $OpsRoot $d) -Force | Out-Null }
if (-not (Test-Path $hookFile)) { Log "ERROR webhook.txt missing - cannot alert, nothing to do (see install-pc-watchdog.ps1)"; exit 0 }

function Send-Discord([string]$text) {
    try {
        $hook = (Get-Content $hookFile -Raw).Trim()
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{ content = $text } | ConvertTo-Json -Compress))
        $r = [Net.HttpWebRequest]::Create($hook)
        $r.Method = 'POST'; $r.ContentType = 'application/json'; $r.Timeout = 15000; $r.Proxy = $null
        $s = $r.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        $r.GetResponse().Close(); return $true
    } catch { Log "ERROR discord post failed: $($_.Exception.GetType().Name)"; return $false }  # never log the URL
}

$st = @{ fails = 0; announced = $false; since = $null; cfgAnnounced = $false; bakAnnounced = $false }
if (Test-Path $stateFile) {
    try {
        $j = Get-Content $stateFile -Raw | ConvertFrom-Json
        $st = @{ fails = [int]$j.fails; announced = [bool]$j.announced; since = $j.since; cfgAnnounced = [bool]$j.cfgAnnounced; bakAnnounced = [bool]$j.bakAnnounced }
    } catch { Log 'WARN watchdog.json unreadable, reset' }
}
function Save-State { $st | ConvertTo-Json -Compress | Set-Content -Path $stateFile -Encoding UTF8 }

# one message when a problem starts, one when it clears ($st[$key] = announced)
function Announce-Once([string]$key, [bool]$bad, [string]$badMsg, [string]$okMsg) {
    if ($bad -and -not $st[$key]) {
        if (Send-Discord $badMsg) { $st[$key] = $true; Log "INFO $key problem announced" }
    } elseif (-not $bad -and $st[$key]) {
        if (Send-Discord $okMsg) { $st[$key] = $false; Log "INFO $key recovery announced" }
    }
}

# --- off-VM backup freshness (independent of mob04 being reachable) ---
$upMin = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes
if ($upMin -ge 30) {
    $newestTs = Get-ChildItem -Path (Join-Path $OpsRoot 'backups\mob04\*\pos_backup_*.sql.gz') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^pos_backup_(\d{8}_\d{6}Z)\.sql\.gz$' } | ForEach-Object { $Matches[1] } | Sort-Object | Select-Object -Last 1
    $bakAgeH = if ($newestTs) {
        [math]::Floor(((Get-Date).ToUniversalTime() - [datetime]::ParseExact($newestTs, "yyyyMMdd_HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)).TotalHours)
    } else { $null }
    $bakStale = ($null -eq $bakAgeH) -or ($bakAgeH -gt $BackupStaleHours)
    if ($bakStale) { Log "FAIL off-VM backup stale: newest $newestTs, age h $bakAgeH" }
    $what = if ($null -eq $bakAgeH) { 'no off-VM backup found' } else { "newest off-VM backup is $bakAgeH h old" }
    Announce-Once 'bakAnnounced' $bakStale ([char]::ConvertFromUtf32(0x26A0) + [char]0xFE0F + " $what (from $env:COMPUTERNAME)") `
        ([char]::ConvertFromUtf32(0x2705) + " off-VM backup fresh again (newest $newestTs)")
}

if (-not (Test-Path $caFile)) {
    Log "ERROR $caFile missing"
    Announce-Once 'cfgAnnounced' $true ([char]::ConvertFromUtf32(0x1F534) + " mob04 watchdog cannot run: $caFile missing (from $env:COMPUTERNAME)") ''
    Save-State; exit 1
}
Announce-Once 'cfgAnnounced' $false '' ([char]::ConvertFromUtf32(0x2705) + ' mob04 watchdog config OK again')

Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class PinnedCa {
    public static string Host; public static X509Certificate2 Ca;
    public static RemoteCertificateValidationCallback Callback { get { return Check; } }
    public static bool Check(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        var req = sender as HttpWebRequest;
        if (req == null || req.RequestUri.Host != Host) return errors == SslPolicyErrors.None; // e.g. Discord: normal validation
        if ((errors & (SslPolicyErrors.RemoteCertificateNameMismatch | SslPolicyErrors.RemoteCertificateNotAvailable)) != 0) return false;
        var c = new X509Chain();
        c.ChainPolicy.ExtraStore.Add(Ca);
        c.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        c.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
        if (!c.Build(new X509Certificate2(cert))) return false;
        var root = c.ChainElements[c.ChainElements.Count - 1].Certificate;
        return c.ChainElements.Count > 1 && root.Thumbprint == Ca.Thumbprint;
    }
}
'@
[PinnedCa]::Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $caFile
[PinnedCa]::Host = ([Uri]$Url).Host
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = [PinnedCa]::Callback

function Test-Mob04 {
    try {
        $r = [Net.HttpWebRequest]::Create($Url)
        $r.Timeout = $TimeoutSec * 1000; $r.ReadWriteTimeout = $TimeoutSec * 1000; $r.Proxy = $null
        $resp = $r.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close()
        return @{ ok = ($code -eq 200); why = "HTTP $code" }
    } catch [Net.WebException] {
        $c = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        return @{ ok = $false; why = "$($_.Exception.Status) $c" }
    } catch { return @{ ok = $false; why = $_.Exception.GetType().Name } }
}

function Test-Internet {
    try {
        $t = New-Object Net.Sockets.TcpClient
        $a = $t.BeginConnect('discord.com', 443, $null, $null)
        $ok = $a.AsyncWaitHandle.WaitOne($TimeoutSec * 1000) -and $t.Connected
        $t.Close(); return $ok
    } catch { return $false }
}

$res = Test-Mob04
if ($res.ok) {
    Log "OK $($res.why)"
    if ($st.announced) {
        if (Send-Discord ([char]::ConvertFromUtf32(0x2705) + ' mob04 back')) { Log 'INFO recovery announced'; $st.fails = 0; $st.announced = $false; $st.since = $null }
    } else { $st.fails = 0; $st.announced = $false; $st.since = $null }
} elseif (-not (Test-Internet)) {
    Log "SKIP $($res.why) - discord.com unreachable too (this PC is offline); not counted"
} else {
    $st.fails++
    if (-not $st.since) { $st.since = (Get-Date -Format 's') }
    Log "FAIL $($res.why) (consecutive: $($st.fails))"
    if ($st.fails -ge 2 -and -not $st.announced) {
        $msg = [char]::ConvertFromUtf32(0x1F534) + " mob04 /health/ready unreachable since $($st.since) (from $env:COMPUTERNAME)"
        if (Send-Discord $msg) { $st.announced = $true; Log 'INFO down announced' }
    }
}
Save-State
