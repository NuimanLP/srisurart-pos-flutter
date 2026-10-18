<#
External watchdog for mob04 (runs on a Windows PC, PowerShell 5.1). Gatus runs ON mob04 and
cannot report mob04 being fully down; this can. See docs/Backend_design/07_CICD_DEPLOY.md 10.5.

Every run: GET <Url> (default https://172.30.58.20/health/ready), 10 s timeout.
 - 2nd consecutive failure  -> ONE Discord message "down since <time>"
 - first success after that -> ONE Discord message "back"
 - if discord.com is unreachable too, the PC is offline: not counted as a mob04 failure.
Paths under -OpsRoot (layout: pc-ops-layout.ps1): secrets\webhook.txt, bin\pos-ca.crt, logs\watchdog.log,
state\watchdog.json. Default root: $env:SRISURART_OPS_ROOT, else %USERPROFILE%\srisurart-ops; the installer passes
the real root in the task arguments.
Webhook URL: only from secrets\webhook.txt (never argv, never logged). Missing = warn + exit 0.
TLS: private CA. A cert is accepted only if its chain is built with bin\pos-ca.crt and ends
at that exact CA (thumbprint match). Certificate checks are never disabled.
#>
param(
    [string]$Url = 'https://172.30.58.20/health/ready',
    [string]$OpsRoot = $(if ($env:SRISURART_OPS_ROOT) { $env:SRISURART_OPS_ROOT } else { Join-Path $env:USERPROFILE 'srisurart-ops' }),
    [int]$TimeoutSec = 10
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
if (-not (Test-Path $hookFile)) { Log "WARN webhook.txt missing - nothing to do (see install-pc-watchdog.ps1)"; exit 0 }
if (-not (Test-Path $caFile)) { Log "ERROR $caFile missing"; exit 1 }

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

$st = @{ fails = 0; announced = $false; since = $null }
if (Test-Path $stateFile) {
    try { $j = Get-Content $stateFile -Raw | ConvertFrom-Json; $st = @{ fails = [int]$j.fails; announced = [bool]$j.announced; since = $j.since } } catch { Log 'WARN watchdog.json unreadable, reset' }
}
function Save-State { $st | ConvertTo-Json -Compress | Set-Content -Path $stateFile -Encoding UTF8 }

$res = Test-Mob04
if ($res.ok) {
    Log "OK $($res.why)"
    if ($st.announced) {
        if (Send-Discord ([char]::ConvertFromUtf32(0x2705) + ' mob04 back')) { Log 'INFO recovery announced'; $st = @{ fails = 0; announced = $false; since = $null } }
    } else { $st = @{ fails = 0; announced = $false; since = $null } }
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
