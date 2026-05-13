<#
.SYNOPSIS
  VIVA Workbox — post-install smoke test.

.DESCRIPTION
  Read-only health check. Can be run any time to confirm Workbox is healthy.
  Does not modify the machine, the service, or any config.

  Reports on:
    - Service state
    - /health response
    - Last task time
    - Tailscale status

.PARAMETER BoxUser
  Windows username whose Box Drive holds rockville-workbox.env. The bearer
  token is read from that file. Leave blank to be prompted.

.PARAMETER Port
  Port to probe. Defaults to 4014.
#>

[CmdletBinding()]
param(
  [string]$BoxUser = "",
  [int]$Port = 4014
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ServiceName = "VIVAWorkbox"

function Write-Section([string]$title) {
  Write-Host ""
  Write-Host "── $title " -NoNewline
  Write-Host ("─" * [Math]::Max(1, 60 - $title.Length))
}

function Read-DotEnv([string]$path) {
  $h = @{}
  foreach ($line in Get-Content -LiteralPath $path) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#")) { continue }
    $eq = $t.IndexOf("=")
    if ($eq -lt 1) { continue }
    $k = $t.Substring(0, $eq).Trim()
    $v = $t.Substring($eq + 1).Trim()
    if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
    elseif ($v.StartsWith("'") -and $v.EndsWith("'")) { $v = $v.Substring(1, $v.Length - 2) }
    $h[$k] = $v
  }
  return $h
}

Write-Section "Service"
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
  Write-Host "  $ServiceName : $($svc.Status)"
  if ($svc.Status -ne "Running") { Write-Host "  !! Service is not Running." -ForegroundColor Yellow }
} else {
  Write-Host "  !! Service '$ServiceName' is not installed." -ForegroundColor Red
}

Write-Section "/health"
$healthUrl = "http://127.0.0.1:$Port/health"
try {
  $health = Invoke-RestMethod -UseBasicParsing -Uri $healthUrl -TimeoutSec 10
  Write-Host "  $healthUrl"
  $health | Format-List | Out-String | ForEach-Object { $_.TrimEnd() } | Write-Host
} catch {
  Write-Host "  !! GET $healthUrl failed: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Section "Tailscale"
try {
  $tsStatus = (& tailscale status 2>&1) -join "`n"
  Write-Host $tsStatus
  $ip = (& tailscale ip --4 2>$null | Select-Object -First 1).Trim()
  if ($ip) { Write-Host "  IPv4: $ip" }
} catch {
  Write-Host "  !! tailscale not available: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Section "Last task"
if (-not $BoxUser) {
  $BoxUser = Read-Host "Windows username for Box Drive (Enter to skip last-task check)"
}
if ($BoxUser) {
  $envFile = "C:\Users\$BoxUser\Box\Bob Campbell Working Folder\VIVA Corner Projection\secrets\rockville-workbox.env"
  if (Test-Path $envFile) {
    $env = Read-DotEnv $envFile
    if ($env.ContainsKey("CCWORKBOX_TOKEN") -and $env["CCWORKBOX_TOKEN"]) {
      try {
        $headers = @{ Authorization = "Bearer $($env['CCWORKBOX_TOKEN'])" }
        $tasks = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/tasks?limit=1" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
        $tasks | Format-List | Out-String | ForEach-Object { $_.TrimEnd() } | Write-Host
      } catch {
        Write-Host "  (skipped — /tasks endpoint not available or returned $($_.Exception.Message))"
      }
    } else {
      Write-Host "  CCWORKBOX_TOKEN not in .env — skipping."
    }
  } else {
    Write-Host "  $envFile not found — skipping."
  }
} else {
  Write-Host "  (skipped)"
}

Write-Section "Done"
Write-Host "  Verify complete. Nothing was modified."
