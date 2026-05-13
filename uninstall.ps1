<#
.SYNOPSIS
  VIVA Workbox — uninstaller.

.DESCRIPTION
  Cleanly tears down the Workbox service and (optionally) its state
  directory and Tailscale registration. Does NOT uninstall winget
  packages (Node, Git, NSSM, Tailscale) — those may be used by other
  software on this machine.

  Useful for "blow it away and start over" scenarios during testing.

  Run as Administrator.
#>

[CmdletBinding()]
param(
  # Skip interactive prompts and accept all "remove" defaults.
  [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ServiceName  = "VIVAWorkbox"
$WorkboxRoot  = "C:\ProgramData\workbox"

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) { Write-Host "Re-launch this script as Administrator." -ForegroundColor Red; exit 1 }

function Confirm-Yes([string]$prompt, [bool]$default = $true) {
  if ($Yes) { return $true }
  $suffix = if ($default) { "[Y/n]" } else { "[y/N]" }
  $ans = Read-Host "$prompt $suffix"
  if (-not $ans) { return $default }
  return ($ans -match '^[Yy]')
}

Write-Host "── Service ──────────────────────────────────────────────"
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
  Write-Host "  Stopping $ServiceName ..."
  & nssm stop $ServiceName 2>$null | Out-Null
  Start-Sleep -Seconds 2
  Write-Host "  Removing $ServiceName ..."
  & nssm remove $ServiceName confirm 2>$null | Out-Null
  Write-Host "  Done."
} else {
  Write-Host "  Service '$ServiceName' is not installed — nothing to do."
}

Write-Host ""
Write-Host "── State directory ─────────────────────────────────────"
if (Test-Path $WorkboxRoot) {
  Write-Host "  $WorkboxRoot contains the deploy key, app checkout, logs, and task state."
  if (Confirm-Yes "  Delete $WorkboxRoot ?" $false) {
    Remove-Item -LiteralPath $WorkboxRoot -Recurse -Force
    Write-Host "  Removed."
  } else {
    Write-Host "  Left in place."
  }
} else {
  Write-Host "  $WorkboxRoot does not exist — nothing to do."
}

Write-Host ""
Write-Host "── Tailscale ──────────────────────────────────────────"
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
  if (Confirm-Yes "  Bring Tailscale down and log out on this machine?" $false) {
    & tailscale down  2>&1 | Out-Host
    & tailscale logout 2>&1 | Out-Host
    Write-Host "  Tailscale is down and logged out."
    Write-Host "  Note: also remove this node from the Tailscale admin console."
  } else {
    Write-Host "  Leaving Tailscale registered."
  }
} else {
  Write-Host "  tailscale not on PATH — skipping."
}

Write-Host ""
Write-Host "Uninstall complete. Winget packages (Node, Git, NSSM, Tailscale) were left installed."
