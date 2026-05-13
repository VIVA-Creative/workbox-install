<#
.SYNOPSIS
  VIVA Workbox — Windows installer.

.DESCRIPTION
  Provisions a Windows 11 Pro (or Enterprise/Education) machine as a host
  for the VIVA Workbox service. Installs Node.js LTS, Git, NSSM, and
  Tailscale via winget; installs Claude Code via npm; joins the Tailscale
  tailnet; generates an SSH deploy key and clones VIVA-Creative/workbox;
  registers a Windows service called "VIVA Workbox" via NSSM; runs smoke
  tests.

  Run as Administrator from an elevated PowerShell window.

  Safely re-runnable — each phase checks current state and skips work that
  is already complete.

.NOTES
  Repo:  https://github.com/VIVA-Creative/workbox-install
  Pairs: https://github.com/VIVA-Creative/workbox
#>

[CmdletBinding()]
param(
  # Hostname this machine will register as on the Tailscale tailnet.
  [string]$TailscaleHostname = "viva-rockville-workbox",

  # Windows username whose Box Drive holds the secrets folder. Leave blank
  # to be prompted interactively.
  [string]$BoxUser = "",

  # Skip the interactive Y/n confirmation banner at the end of pre-flight.
  # Useful for unattended re-runs once the operator has already approved.
  [switch]$AssumeYes,

  # Filename of the .env file inside the Box secrets folder.
  # Defaults to rockville-workbox.env for production. Override with bob.env for staging tests.
  [string]$EnvFile = "rockville-workbox.env"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----- Constants -------------------------------------------------------------

$Script:WorkboxRoot       = "C:\ProgramData\workbox"
$Script:WorkboxApp        = Join-Path $Script:WorkboxRoot "app"
$Script:DeployKey         = Join-Path $Script:WorkboxRoot "deploy-key"
$Script:DeployKeyPub      = "$($Script:DeployKey).pub"
$Script:SshConfig         = Join-Path $Script:WorkboxRoot "ssh-config"
$Script:ServiceName       = "VIVAWorkbox"
$Script:ServiceDisplay    = "VIVA Workbox"
$Script:ServiceDesc       = "VIVA Creative Workbox — dispatches Claude Code tasks via HTTP API. https://github.com/VIVA-Creative/workbox"
$Script:WorkboxRepoUrl    = "git@github-workbox:VIVA-Creative/workbox.git"
$Script:WorkboxRepoHttps  = "https://github.com/VIVA-Creative/workbox"
$Script:MinNodeMajor      = 20
$Script:MinNodeMinor      = 12

# ----- Helpers ---------------------------------------------------------------

function Write-Step([string]$msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)    { Write-Host "  ok  $msg" -ForegroundColor Green }
function Write-Skip([string]$msg)  { Write-Host "  --  $msg (already done)" -ForegroundColor DarkGray }
function Write-Warn2([string]$msg) { Write-Host "  !!  $msg" -ForegroundColor Yellow }
function Write-Err2([string]$msg)  { Write-Host "  XX  $msg" -ForegroundColor Red }

function Fail([string]$msg) {
  Write-Err2 $msg
  Write-Host ""
  Write-Host "Install aborted. See docs/troubleshooting.md or share the above output with Bob." -ForegroundColor Red
  exit 1
}

# Re-read PATH (Machine + User) from the registry into the current session.
# Newly-installed CLIs need this — winget puts them on PATH for new shells
# but the current process keeps a stale copy.
function Refresh-PathFromRegistry {
  $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $user    = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = (@($machine, $user) | Where-Object { $_ } ) -join ";"
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Get an installed app's presence via winget without surfacing exit codes.
function Test-WingetInstalled([string]$id) {
  try {
    $out = winget list --id $id --exact --accept-source-agreements 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($out -match [Regex]::Escape($id))
  } catch { return $false }
}

function Install-WingetPackage([string]$id, [string]$friendly) {
  if (Test-WingetInstalled $id) {
    Write-Skip "$friendly ($id)"
    return
  }
  Write-Step "Installing $friendly via winget ($id)"
  & winget install --id $id --silent --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -ne 0) { Fail "winget install $id failed (exit $LASTEXITCODE)." }
  Refresh-PathFromRegistry
  Write-Ok "$friendly installed"
}

function Get-NodeVersion {
  try {
    $v = (& node --version) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v) { return $null }
    # e.g. "v20.12.1"
    if ($v -match '^v(\d+)\.(\d+)\.(\d+)') {
      return [pscustomobject]@{
        Raw   = $v
        Major = [int]$Matches[1]
        Minor = [int]$Matches[2]
        Patch = [int]$Matches[3]
      }
    }
    return $null
  } catch { return $null }
}

# Parse a dotenv file into a hashtable. Ignores comments and blank lines.
# Strips surrounding single/double quotes if present.
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

# ----- Phase 1: Pre-flight ---------------------------------------------------

function Invoke-PreFlight {
  Write-Step "Phase 1 — Pre-flight checks"

  if (-not (Test-Admin)) {
    Write-Err2 "This script must run as Administrator."
    Write-Host ""
    Write-Host "To re-launch elevated:"
    Write-Host "  1. Close this window."
    Write-Host "  2. Click Start, type 'PowerShell'."
    Write-Host "  3. Right-click 'Windows PowerShell' and choose 'Run as administrator'."
    Write-Host "  4. cd to this folder and run:  .\install.ps1"
    exit 1
  }
  Write-Ok "Running as Administrator"

  $info = Get-ComputerInfo -Property OsName, OsProductType, WindowsProductName, OsVersion -ErrorAction Stop
  $edition = $info.WindowsProductName
  Write-Host "  OS: $edition"
  if ($edition -match "Home") {
    Fail "Windows $edition detected. Workbox requires Pro, Enterprise, or Education edition."
  }
  if ($edition -match "Windows 10") {
    Write-Warn2 "Detected Windows 10 ($edition). Workbox is tested on Windows 11 Pro."
    if (-not $AssumeYes) {
      $ans = Read-Host "Continue anyway? [y/N]"
      if ($ans -notmatch '^[Yy]') { Fail "Aborted by user — Windows 10 not approved." }
    }
  } else {
    Write-Ok "Windows edition OK ($edition)"
  }

  $psv = $PSVersionTable.PSVersion
  if ($psv.Major -lt 5 -or ($psv.Major -eq 5 -and $psv.Minor -lt 1)) {
    Fail "PowerShell $psv detected; this installer requires 5.1 or newer."
  }
  Write-Ok "PowerShell $psv"

  Write-Step "Checking internet connectivity"
  foreach ($url in @("https://github.com", "https://api.anthropic.com")) {
    try {
      $null = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $url -TimeoutSec 15
      Write-Ok "Reachable: $url"
    } catch {
      Fail "Cannot reach $url. Check this machine's internet / proxy settings and re-run."
    }
  }

  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "winget not found. Install 'App Installer' from the Microsoft Store, then re-run this script."
  }
  Write-Ok "winget available"

  if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok "git already installed ($((git --version) 2>&1))"
  } else {
    Write-Host "  git not yet installed — will install via winget in Phase 2."
  }

  Write-Host ""
  Write-Host "─────────────────────────────────────────────────────────────"
  Write-Host " About to install: Node.js LTS, Git, NSSM, Tailscale, Claude"
  Write-Host " Will create a Windows service: $Script:ServiceDisplay"
  Write-Host " Will join Tailscale tailnet as: $TailscaleHostname"
  Write-Host " Workbox app dir:               $Script:WorkboxApp"
  Write-Host " Workbox state dir (default):   C:\ProgramData\workbox\state"
  Write-Host "─────────────────────────────────────────────────────────────"
  Write-Host ""
  if (-not $AssumeYes) {
    $ans = Read-Host "Proceed? [Y/n]"
    if ($ans -match '^[Nn]') { Fail "Aborted by user at pre-flight confirmation." }
  }
}

# ----- Phase 2: Dependencies -------------------------------------------------

function Install-Dependencies {
  Write-Step "Phase 2 — Installing dependencies via winget"

  Install-WingetPackage "OpenJS.NodeJS.LTS" "Node.js LTS"
  Install-WingetPackage "Git.Git"           "Git"
  Install-WingetPackage "NSSM.NSSM"         "NSSM (Non-Sucking Service Manager)"
  Install-WingetPackage "tailscale.tailscale" "Tailscale"

  Refresh-PathFromRegistry

  $node = Get-NodeVersion
  if (-not $node) {
    Fail "node not found on PATH after install. Try opening a fresh PowerShell window and re-running."
  }
  if ($node.Major -lt $Script:MinNodeMajor -or
      ($node.Major -eq $Script:MinNodeMajor -and $node.Minor -lt $Script:MinNodeMinor)) {
    Fail "Node $($node.Raw) is older than required v$Script:MinNodeMajor.$Script:MinNodeMinor. Try: winget upgrade --id OpenJS.NodeJS.LTS"
  }
  Write-Ok "Node $($node.Raw) on PATH"

  foreach ($bin in @("git", "nssm", "tailscale")) {
    if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
      Fail "$bin not on PATH after install. Open a fresh elevated PowerShell window and re-run."
    }
  }
  Write-Ok "git, nssm, tailscale all on PATH"

  Write-Step "Installing Claude Code globally via npm"
  if (Get-Command claude -ErrorAction SilentlyContinue) {
    $cv = (& claude --version) 2>&1
    Write-Skip "claude already installed ($cv)"
  } else {
    & npm install -g "@anthropic-ai/claude-code"
    if ($LASTEXITCODE -ne 0) { Fail "npm install -g @anthropic-ai/claude-code failed (exit $LASTEXITCODE)." }
    Refresh-PathFromRegistry
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
      Fail "claude not on PATH after npm install. Open a fresh elevated PowerShell window and re-run."
    }
    Write-Ok "claude installed ($((& claude --version) 2>&1))"
  }

  $Script:ClaudeBin = (Get-Command claude).Source
  $Script:NodeBin   = (Get-Command node).Source
  $Script:NssmBin   = (Get-Command nssm).Source
  Write-Host "  node bin:   $Script:NodeBin"
  Write-Host "  claude bin: $Script:ClaudeBin"
  Write-Host "  nssm bin:   $Script:NssmBin"
}

# ----- Phase 3: .env from Box ------------------------------------------------

function Read-Secrets {
  Write-Step "Phase 3 — Locating and validating .env from Box Drive"

  if (-not $BoxUser) {
    $BoxUser = Read-Host "Windows username whose Box Drive holds the secrets folder"
    if (-not $BoxUser) { Fail "Box user is required." }
  }

  $boxRoot   = "C:\Users\$BoxUser\Box"
  $secretDir = Join-Path $boxRoot "Bob Campbell Working Folder\VIVA Corner Projection\secrets"
  $envFile   = Join-Path $secretDir $EnvFile
  Write-Host "  Expecting .env at: $envFile"

  if (-not (Test-Path $boxRoot)) {
    Fail "Box Drive root not found at $boxRoot. Make sure Box Drive is installed and signed in to the right account."
  }
  if (-not (Test-Path $secretDir)) {
    Fail "Secrets folder not found at $secretDir. Make sure Box Drive has synced 'VIVA Corner Projection'."
  }

  # Poll for the .env in case Box is still syncing.
  $deadline = (Get-Date).AddMinutes(5)
  $found = $false
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $envFile) { $found = $true; break }
    $elapsed = [int]((Get-Date) - $deadline.AddMinutes(-5)).TotalSeconds
    Write-Host "  Waiting for $EnvFile to sync from Box... (elapsed $($elapsed)s)"
    Start-Sleep -Seconds 5
  }
  if (-not $found) {
    Fail "$EnvFile did not appear within 5 minutes. Confirm Box Drive sync is active and the file exists in the secrets folder."
  }
  Write-Ok ".env found"

  $env = Read-DotEnv $envFile

  $required = @("CCWORKBOX_TOKEN", "ANTHROPIC_API_KEY", "TAILSCALE_AUTHKEY", "BOX_CONTENT_PATH")
  foreach ($k in $required) {
    if (-not $env.ContainsKey($k) -or -not $env[$k]) {
      Fail ".env is missing required key: $k"
    }
  }

  if ($env["CCWORKBOX_TOKEN"] -notmatch '^[0-9a-fA-F]{64}$') {
    Fail "CCWORKBOX_TOKEN must be exactly 64 hexadecimal characters."
  }
  if (-not $env["ANTHROPIC_API_KEY"].StartsWith("sk-ant-") -or $env["ANTHROPIC_API_KEY"].Length -lt 50) {
    Fail "ANTHROPIC_API_KEY looks malformed (must start with 'sk-ant-' and be >50 chars)."
  }
  if ($env["TAILSCALE_AUTHKEY"] -eq "__FILL_IN_BEFORE_INSTALL__") {
    Fail "TAILSCALE_AUTHKEY is still the placeholder. Generate a real key in the Tailscale admin console, update the .env in Box, wait for sync, and re-run."
  }
  if (-not $env["TAILSCALE_AUTHKEY"].StartsWith("tskey-auth-") -or $env["TAILSCALE_AUTHKEY"].Length -lt 30) {
    Fail "TAILSCALE_AUTHKEY looks malformed (must start with 'tskey-auth-')."
  }
  if ($env["BOX_CONTENT_PATH"] -notmatch '[\\\:]') {
    Fail "BOX_CONTENT_PATH doesn't look like a Windows path."
  }

  # Defaults
  if (-not $env.ContainsKey("WORKBOX_DIR")       -or -not $env["WORKBOX_DIR"])       { $env["WORKBOX_DIR"]       = "C:\ProgramData\workbox\state" }
  if (-not $env.ContainsKey("WORKBOX_PORT")      -or -not $env["WORKBOX_PORT"])      { $env["WORKBOX_PORT"]      = "4014" }
  if (-not $env.ContainsKey("WORKBOX_BIND_HOST") -or -not $env["WORKBOX_BIND_HOST"]) { $env["WORKBOX_BIND_HOST"] = "127.0.0.1" }
  if (-not $env.ContainsKey("TASK_TIMEOUT_MS")   -or -not $env["TASK_TIMEOUT_MS"])   { $env["TASK_TIMEOUT_MS"]   = "1800000" }

  Write-Ok "All required keys present and valid"
  Write-Host "  WORKBOX_DIR:       $($env['WORKBOX_DIR'])"
  Write-Host "  WORKBOX_PORT:      $($env['WORKBOX_PORT'])"
  Write-Host "  WORKBOX_BIND_HOST: $($env['WORKBOX_BIND_HOST'])"
  Write-Host "  TASK_TIMEOUT_MS:   $($env['TASK_TIMEOUT_MS'])"
  Write-Host "  BOX_CONTENT_PATH:  $($env['BOX_CONTENT_PATH'])"
  Write-Host "  (secret values not echoed)"

  return $env
}

# ----- Phase 4: Tailscale ----------------------------------------------------

function Join-Tailscale([string]$authKey) {
  Write-Step "Phase 4 — Tailscale join"
  $status = (& tailscale status 2>&1)
  if ($LASTEXITCODE -eq 0 -and $status -notmatch "Logged out") {
    Write-Skip "Tailscale already authenticated"
  } else {
    Write-Host "  Running: tailscale up --hostname=$TailscaleHostname"
    & tailscale up --auth-key=$authKey --hostname=$TailscaleHostname --accept-routes
    if ($LASTEXITCODE -ne 0) {
      Fail "tailscale up failed (exit $LASTEXITCODE). The auth key may have expired or been revoked."
    }
    Write-Ok "Joined tailnet as $TailscaleHostname"
  }

  # Single-use auth key, but wipe from memory anyway.
  $authKey = $null
  [GC]::Collect()

  $ip = (& tailscale ip --4 2>$null | Select-Object -First 1).Trim()
  if (-not $ip) {
    Fail "tailscale ip --4 returned no address. Run 'tailscale status' and investigate."
  }
  Write-Ok "Tailscale IPv4: $ip"
  $Script:TailscaleIP = $ip
}

# ----- Phase 5: Deploy key + clone -------------------------------------------

function Initialize-DeployKey {
  Write-Step "Phase 5 — GitHub deploy key + clone workbox repo"

  New-Item -ItemType Directory -Force -Path $Script:WorkboxRoot | Out-Null

  $newlyGenerated = $false
  if (Test-Path $Script:DeployKey) {
    Write-Skip "Deploy key already exists at $Script:DeployKey"
  } else {
    Write-Host "  Generating ed25519 deploy key at $Script:DeployKey"
    $comment = "rockville-workbox-install-$(Get-Date -Format 'yyyy-MM-dd')"
    & ssh-keygen -t ed25519 -f $Script:DeployKey -N '""' -C $comment
    if ($LASTEXITCODE -ne 0) { Fail "ssh-keygen failed (exit $LASTEXITCODE)." }
    $newlyGenerated = $true
    Write-Ok "Deploy key generated"
  }

  $pub = (Get-Content $Script:DeployKeyPub) -join "`n"
  Write-Host ""
  Write-Host "──────────────────────────────────────────────────────────────"
  Write-Host " ADD THIS PUBLIC KEY TO GITHUB AS A DEPLOY KEY:"
  Write-Host "──────────────────────────────────────────────────────────────"
  Write-Host $pub -ForegroundColor Yellow
  Write-Host "──────────────────────────────────────────────────────────────"
  Write-Host ""
  Write-Host "  1. Go to: $Script:WorkboxRepoHttps/settings/keys"
  Write-Host "  2. Click 'Add deploy key'."
  Write-Host "  3. Title:  Rockville install machine"
  Write-Host "  4. Key:    paste the public key above."
  Write-Host "  5. LEAVE 'Allow write access' UNCHECKED."
  Write-Host "  6. Click 'Add key'."
  Write-Host ""
  if ($newlyGenerated) {
    Read-Host "Press Enter once the deploy key is added on GitHub (or Ctrl-C to abort)"
  } else {
    Write-Host "  (Key already existed — verify it's still registered above, then press Enter.)"
    Read-Host "Press Enter to continue"
  }

  # SSH config — route all 'github-workbox' traffic through this key.
  $sshContents = @"
Host github-workbox
  HostName github.com
  User git
  IdentityFile $Script:DeployKey
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
"@
  Set-Content -LiteralPath $Script:SshConfig -Value $sshContents -Encoding ASCII
  Write-Ok "Wrote $Script:SshConfig"

  Write-Step "Testing GitHub deploy key auth"
  $sshTest = (& ssh -F $Script:SshConfig -o BatchMode=yes -T github-workbox 2>&1) -join "`n"
  # GitHub returns exit 1 on the auth test even when successful.
  if ($sshTest -match "successfully authenticated") {
    Write-Ok "GitHub deploy key accepted"
  } else {
    Write-Err2 "GitHub did not accept the deploy key."
    Write-Host "  ssh output: $sshTest"
    Fail "Verify the public key shown above was added at $Script:WorkboxRepoHttps/settings/keys, then re-run."
  }

  Write-Step "Cloning $Script:WorkboxRepoUrl"
  if (Test-Path (Join-Path $Script:WorkboxApp ".git")) {
    Write-Host "  Existing checkout found — pulling latest."
    Push-Location $Script:WorkboxApp
    try {
      & git -c core.sshCommand="ssh -F `"$Script:SshConfig`"" pull --ff-only
      if ($LASTEXITCODE -ne 0) { Fail "git pull failed (exit $LASTEXITCODE)." }
      Write-Ok "git pull complete"
    } finally { Pop-Location }
  } else {
    & git -c core.sshCommand="ssh -F `"$Script:SshConfig`"" clone $Script:WorkboxRepoUrl $Script:WorkboxApp
    if ($LASTEXITCODE -ne 0) { Fail "git clone failed (exit $LASTEXITCODE)." }
    Write-Ok "Cloned to $Script:WorkboxApp"
  }

  # If the workbox repo has dependencies, install them.
  if (Test-Path (Join-Path $Script:WorkboxApp "package.json")) {
    Write-Step "Running npm install in $Script:WorkboxApp"
    Push-Location $Script:WorkboxApp
    try {
      & npm install --omit=dev
      if ($LASTEXITCODE -ne 0) { Fail "npm install in workbox app failed." }
      Write-Ok "npm install complete"
    } finally { Pop-Location }
  }
}

# ----- Phase 6: State dirs + NSSM service ------------------------------------

function Install-Service([hashtable]$env) {
  Write-Step "Phase 6 — State directories + Windows service"

  $workboxDir = $env["WORKBOX_DIR"]
  foreach ($sub in @("tasks", "results", "status", "logs")) {
    $p = Join-Path $workboxDir $sub
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
  Write-Ok "State directories under $workboxDir"

  # Tear down any existing service so we install a fresh, fully consistent definition.
  $existing = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "  Existing service '$Script:ServiceName' found — stopping and removing for clean re-install."
    & nssm stop $Script:ServiceName 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & nssm remove $Script:ServiceName confirm 2>$null | Out-Null
    Start-Sleep -Seconds 1
  }

  $serverJs = Join-Path $Script:WorkboxApp "server.js"
  if (-not (Test-Path $serverJs)) {
    Fail "Expected $serverJs after clone. Has VIVA-Creative/workbox moved its entry point?"
  }

  & nssm install $Script:ServiceName $Script:NodeBin $serverJs
  if ($LASTEXITCODE -ne 0) { Fail "nssm install failed." }

  & nssm set $Script:ServiceName DisplayName $Script:ServiceDisplay         | Out-Null
  & nssm set $Script:ServiceName Description $Script:ServiceDesc            | Out-Null
  & nssm set $Script:ServiceName AppDirectory $Script:WorkboxApp            | Out-Null
  & nssm set $Script:ServiceName AppStdout (Join-Path $workboxDir "logs\nssm-stdout.log") | Out-Null
  & nssm set $Script:ServiceName AppStderr (Join-Path $workboxDir "logs\nssm-stderr.log") | Out-Null
  & nssm set $Script:ServiceName AppRotateFiles 1                           | Out-Null
  & nssm set $Script:ServiceName AppRotateOnline 1                          | Out-Null
  & nssm set $Script:ServiceName AppRotateBytes 10485760                    | Out-Null
  & nssm set $Script:ServiceName Start SERVICE_AUTO_START                   | Out-Null
  & nssm set $Script:ServiceName AppExit Default Restart                    | Out-Null
  & nssm set $Script:ServiceName AppRestartDelay 5000                       | Out-Null

  # AppEnvironmentExtra GOTCHA: NSSM expects a single multi-line value, one
  # KEY=VALUE per line. Calling `nssm set ... AppEnvironmentExtra K=V` once
  # per variable will overwrite the previous one — you only get the last.
  # Build the whole block, then set it once.
  $envBlock = @(
    "CCWORKBOX_TOKEN=$($env['CCWORKBOX_TOKEN'])",
    "ANTHROPIC_API_KEY=$($env['ANTHROPIC_API_KEY'])",
    "WORKBOX_DIR=$($env['WORKBOX_DIR'])",
    "WORKBOX_PORT=$($env['WORKBOX_PORT'])",
    "WORKBOX_BIND_HOST=$($env['WORKBOX_BIND_HOST'])",
    "TASK_TIMEOUT_MS=$($env['TASK_TIMEOUT_MS'])",
    "BOX_CONTENT_PATH=$($env['BOX_CONTENT_PATH'])",
    "CC_BIN=$Script:ClaudeBin"
  ) -join "`r`n"

  & nssm set $Script:ServiceName AppEnvironmentExtra $envBlock | Out-Null

  Write-Ok "Service registered as '$Script:ServiceDisplay' ($Script:ServiceName)"

  Write-Step "Starting service"
  & nssm start $Script:ServiceName | Out-Null
  Start-Sleep -Seconds 3
  $svc = Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
  if (-not $svc -or $svc.Status -ne "Running") {
    $stderrLog = Join-Path $workboxDir "logs\nssm-stderr.log"
    Write-Err2 "Service did not reach Running state. Last 50 lines of stderr:"
    if (Test-Path $stderrLog) { Get-Content $stderrLog -Tail 50 | ForEach-Object { Write-Host "    $_" } }
    Fail "Service start failed."
  }
  Write-Ok "Service is Running"
}

# ----- Phase 7: Smoke tests --------------------------------------------------

function Invoke-SmokeTests([hashtable]$env) {
  Write-Step "Phase 7 — Smoke tests"

  $base = "http://$($env['WORKBOX_BIND_HOST']):$($env['WORKBOX_PORT'])"
  Start-Sleep -Seconds 2

  try {
    $health = Invoke-RestMethod -UseBasicParsing -Uri "$base/health" -TimeoutSec 15
  } catch {
    Fail "GET $base/health failed: $($_.Exception.Message)"
  }
  if (-not $health.ok) { Fail "/health returned ok=false: $($health | ConvertTo-Json -Compress)" }
  Write-Ok "/health ok — claude_bin=$($health.claude_bin) claude_version=$($health.claude_version)"

  $headers = @{ Authorization = "Bearer $($env['CCWORKBOX_TOKEN'])" }
  $body    = @{ instructions = "Print the current date and time and the hostname of this machine, then exit." } | ConvertTo-Json
  try {
    $resp = Invoke-RestMethod -Method Post -Uri "$base/task" -Headers $headers -Body $body -ContentType "application/json" -TimeoutSec 30
  } catch {
    Fail "POST $base/task failed: $($_.Exception.Message)"
  }
  $taskId = $resp.task_id
  if (-not $taskId) { Fail "POST /task did not return a task_id." }
  Write-Ok "Dispatched test task id=$taskId"

  $deadline = (Get-Date).AddSeconds(60)
  $state    = "pending"
  while ((Get-Date) -lt $deadline) {
    try {
      $status = Invoke-RestMethod -Uri "$base/task/$taskId/status" -Headers $headers -TimeoutSec 15
      $state = $status.state
    } catch {
      Write-Warn2 "status poll failed once: $($_.Exception.Message)"
    }
    if ($state -in @("complete", "error", "timeout", "cancelled")) { break }
    Start-Sleep -Seconds 2
  }
  if ($state -ne "complete") {
    $stderrLog = Join-Path $env['WORKBOX_DIR'] "logs\nssm-stderr.log"
    Write-Err2 "Test task ended in state '$state' (expected 'complete')."
    if (Test-Path $stderrLog) {
      Write-Host "  Last 30 lines of nssm-stderr.log:"
      Get-Content $stderrLog -Tail 30 | ForEach-Object { Write-Host "    $_" }
    }
    Fail "Smoke test failed."
  }
  Write-Ok "Test task reached 'complete'"

  try {
    $result = Invoke-RestMethod -Uri "$base/task/$taskId/result" -Headers $headers -TimeoutSec 15
    $resultText = ($result | ConvertTo-Json -Depth 6)
    $hostname = $env:COMPUTERNAME
    if ($resultText -match [Regex]::Escape($hostname)) {
      Write-Ok "Result mentions hostname '$hostname'"
    } else {
      Write-Warn2 "Result did not contain expected hostname '$hostname'. Worth inspecting but not blocking."
    }
  } catch {
    Write-Warn2 "Could not fetch /task/$taskId/result: $($_.Exception.Message)"
  }
}

# ----- Phase 8: Success summary ----------------------------------------------

function Write-Summary([hashtable]$env) {
  $bind = "http://$($env['WORKBOX_BIND_HOST']):$($env['WORKBOX_PORT'])"
  $tail = "http://$Script:TailscaleIP`:$($env['WORKBOX_PORT'])"
  Write-Host ""
  Write-Host "═══════════════════════════════════════════════════════"
  Write-Host "  VIVA Workbox — Install Successful"
  Write-Host "═══════════════════════════════════════════════════════"
  Write-Host ""
  Write-Host "Service:           $Script:ServiceDisplay (Windows service `"$Script:ServiceName`")"
  Write-Host "Status:            Running"
  Write-Host "Listening at:      $bind  (loopback)"
  Write-Host "Also reachable:    $tail  (via Tailscale)"
  Write-Host ""
  Write-Host "Health check:      $bind/health"
  Write-Host "Workbox app:       $Script:WorkboxApp"
  Write-Host "Workbox state:     $($env['WORKBOX_DIR'])"
  Write-Host "NSSM logs:         $(Join-Path $env['WORKBOX_DIR'] 'logs')"
  Write-Host ""
  Write-Host "Tailscale node:    $TailscaleHostname"
  Write-Host "Tailscale IP:      $Script:TailscaleIP"
  Write-Host ""
  Write-Host "For Bob (in Florida):"
  Write-Host "  Add Rockville's Workbox to your connected MCPs at the Tailscale IP above."
  Write-Host "  Bearer token is in the same .env you provided to this install."
  Write-Host ""
  Write-Host "If the service goes down:"
  Write-Host "  Get-Service $Script:ServiceName"
  Write-Host "  Restart-Service $Script:ServiceName"
  Write-Host "  Check logs at $(Join-Path $env['WORKBOX_DIR'] 'logs')"
  Write-Host ""
  Write-Host "To re-run this installer (idempotent):"
  Write-Host "  Re-run install.ps1 — it will skip steps already complete."
  Write-Host ""
  Write-Host "═══════════════════════════════════════════════════════"
}

# ----- Main ------------------------------------------------------------------

Invoke-PreFlight
Install-Dependencies
$envMap = Read-Secrets
Join-Tailscale -authKey $envMap["TAILSCALE_AUTHKEY"]
$envMap.Remove("TAILSCALE_AUTHKEY") | Out-Null  # not needed past this point; do not pass to service
Initialize-DeployKey
Install-Service -env $envMap
Invoke-SmokeTests -env $envMap
Write-Summary -env $envMap
