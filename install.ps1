#Requires -Version 7.0
# install.ps1 — install claudehome PC client and run first-time setup wizard.
#
# Re-running this script is safe: prompts are skipped for values already saved
# in ~/.claudehomerc or set in the environment.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$binDir   = Join-Path $repoRoot 'bin'
$ps1Path  = Join-Path $binDir 'claudehome.ps1'
$cmdPath  = Join-Path $binDir 'claudehome.cmd'
$rcPath   = Join-Path $HOME '.claudehomerc'

function Write-Step([string]$msg) { Write-Host "`n── $msg" }
function Write-Ok([string]$msg)   { Write-Host "install: $msg" }
function Write-Err([string]$msg)  { [Console]::Error.WriteLine("install: $msg") }

# ── Step 1: sanity check ──────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $ps1Path)) {
    Write-Err "$ps1Path not found. Run from the repo root."
    exit 1
}

# ── Step 2: drop .cmd shim (idempotent) ──────────────────────────────────────
$shimLine = '@pwsh -NoProfile -File "%~dp0claudehome.ps1" %*'
if (Test-Path -LiteralPath $cmdPath) {
    $existing = (Get-Content -LiteralPath $cmdPath -Raw).Trim()
    if ($existing -notlike '*pwsh*claudehome.ps1*') {
        Write-Err "$cmdPath exists but isn't our shim. Refusing to overwrite."
        exit 1
    }
} else {
    Set-Content -LiteralPath $cmdPath -Value "@REM claudehome shim`r`n$shimLine`r`n" -Encoding ASCII -NoNewline
}

# ── Step 3: add bin dir to user PATH (idempotent, case-insensitive) ──────────
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$entries  = if ($userPath) { $userPath -split ';' | Where-Object { $_ -ne '' } } else { @() }
if (-not ($entries | Where-Object { $_ -ieq $binDir })) {
    $trimmed = if ($userPath) { $userPath.TrimEnd(';') } else { '' }
    $newPath = if ([string]::IsNullOrEmpty($trimmed)) { $binDir } else { "$trimmed;$binDir" }
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Write-Ok "Added $binDir to your user PATH."
} else {
    Write-Ok "$binDir already in user PATH."
}

# ── helpers ───────────────────────────────────────────────────────────────────
function Get-TailscalePeers {
    try {
        $out = & tailscale.exe status 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        $out | Select-Object -Skip 1 | ForEach-Object {
            $cols = ($_ -split '\s+').Where({ $_ -ne '' })
            if ($cols.Count -ge 2) { $cols[1] }
        } | Where-Object { $_ } | Select-Object -First 10
    } catch { @() }
}

function Get-RcValue([string]$key) {
    if (-not (Test-Path -LiteralPath $rcPath)) { return '' }
    $line = Get-Content -LiteralPath $rcPath |
            Where-Object { $_ -match "^$key=" } |
            Select-Object -Last 1
    if ($line) { ($line -split '=', 2)[1] } else { '' }
}

function Set-RcValue([string]$key, [string]$val) {
    if (Test-Path -LiteralPath $rcPath) {
        $lines = Get-Content -LiteralPath $rcPath | Where-Object { $_ -notmatch "^$key=" }
        ($lines + "$key=$val") | Set-Content -LiteralPath $rcPath -Encoding UTF8
    } else {
        Add-Content -LiteralPath $rcPath -Value "$key=$val" -Encoding UTF8
    }
}

function Test-SshOk([string]$user, [string]$sshHost) {
    try {
        $result = & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$user@$sshHost" echo ok 2>$null
        $LASTEXITCODE -eq 0 -and $result -eq 'ok'
    } catch { $false }
}

# ── Step 4: Tailscale check ───────────────────────────────────────────────────
Write-Step "Checking Tailscale"
$tailscaleCmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
if (-not $tailscaleCmd) {
    Write-Ok "Tailscale not found."
    Write-Host "  1. Download and install: https://tailscale.com/download"
    Write-Host "  2. Log in to the same Tailscale account you use on the Mac mini."
    Write-Host "  3. Re-run: .\install.ps1"
    Start-Process "https://tailscale.com/download"
    exit 0
}
& tailscale.exe status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Ok "Tailscale is installed but not logged in or not running."
    Write-Host "  Open the Tailscale system-tray app and log in, then re-run: .\install.ps1"
    exit 0
}
Write-Ok "Tailscale is running. ✓"

# ── Step 5: init config file ──────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $rcPath)) {
    Set-Content -LiteralPath $rcPath -Value `
        "# claudehome config -- written by install.ps1`n# Environment variables take precedence over this file.`n" `
        -Encoding UTF8
    Write-Ok "Created $rcPath"
}

Write-Step "Mac mini configuration"

# ── Step 6: CLAUDEHOME_HOST ───────────────────────────────────────────────────
$existingHost = if ($env:CLAUDEHOME_HOST) { $env:CLAUDEHOME_HOST } else { Get-RcValue 'CLAUDEHOME_HOST' }
if ($existingHost) {
    Write-Ok "CLAUDEHOME_HOST already set to '$existingHost' — skipping."
    $chosenHost = $existingHost
} else {
    $peers = Get-TailscalePeers
    if ($peers) {
        Write-Host "Tailscale peers (pick one):"
        $peers | ForEach-Object { Write-Host "  $_" }
    }
    $chosenHost = Read-Host "Enter Mac mini Tailscale hostname"
    if ([string]::IsNullOrWhiteSpace($chosenHost)) {
        Write-Err "Hostname required."
        exit 1
    }
    $chosenHost = $chosenHost.Trim()
    Set-RcValue 'CLAUDEHOME_HOST' $chosenHost
    Write-Ok "Saved CLAUDEHOME_HOST=$chosenHost"
}

# ── Step 7: CLAUDEHOME_USER ───────────────────────────────────────────────────
$existingUser = if ($env:CLAUDEHOME_USER) { $env:CLAUDEHOME_USER } else { Get-RcValue 'CLAUDEHOME_USER' }
if ($existingUser) {
    Write-Ok "CLAUDEHOME_USER already set to '$existingUser' — skipping."
    $chosenUser = $existingUser
} else {
    $defaultUser = $env:USERNAME
    $input = Read-Host "Enter Mac mini SSH username (default: $defaultUser)"
    $chosenUser = if ([string]::IsNullOrWhiteSpace($input)) { $defaultUser } else { $input.Trim() }
    Set-RcValue 'CLAUDEHOME_USER' $chosenUser
    Write-Ok "Saved CLAUDEHOME_USER=$chosenUser"
}

# ── Clear stale user-level env vars (config file is now the source of truth) ──
foreach ($varName in @('CLAUDEHOME_HOST', 'CLAUDEHOME_USER', 'CLAUDEHOME_PROJECTS_DIR')) {
    $existing = [Environment]::GetEnvironmentVariable($varName, 'User')
    if ($existing) {
        [Environment]::SetEnvironmentVariable($varName, $null, 'User')
        Write-Ok "Cleared stale user env var $varName (now read from $rcPath)."
    }
}

# ── Step 8: SSH key ───────────────────────────────────────────────────────────
Write-Step "SSH key setup"
$keyPath = Join-Path $HOME '.ssh' 'id_ed25519'
$pubPath = "$keyPath.pub"
if (-not (Test-Path -LiteralPath $keyPath)) {
    Write-Ok "No SSH key at $keyPath. Generating..."
    $sshDir = Join-Path $HOME '.ssh'
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
    & ssh-keygen.exe -t ed25519 -f $keyPath -N '""' -C $env:COMPUTERNAME
    Write-Ok "Key generated."
}

$sshAttempts = 0
while (-not (Test-SshOk $chosenUser $chosenHost)) {
    $sshAttempts++
    if ($sshAttempts -gt 3) {
        Write-Err "SSH still failing after 3 attempts. Check Remote Login is on:"
        Write-Host "  System Settings → General → Sharing → Remote Login: on"
        exit 1
    }
    Write-Ok "SSH key not yet authorized on $chosenHost. Copying..."
    $pub = (Get-Content -LiteralPath $pubPath -Raw).Trim()
    $sshCopyId = Get-Command ssh-copy-id.exe -ErrorAction SilentlyContinue
    $copyOk = $false
    if ($sshCopyId) {
        & ssh-copy-id.exe "$chosenUser@$chosenHost"
        $copyOk = ($LASTEXITCODE -eq 0)
    } else {
        & ssh.exe "$chosenUser@$chosenHost" `
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        $copyOk = ($LASTEXITCODE -eq 0)
    }
    if (-not $copyOk) {
        Write-Host ""
        Write-Host "  Could not connect. The username '$chosenUser' may be wrong."
        $newUser = Read-Host "  Re-enter Mac mini SSH username (or press Enter to keep '$chosenUser')"
        if (-not [string]::IsNullOrWhiteSpace($newUser)) {
            $chosenUser = $newUser.Trim()
            Set-RcValue 'CLAUDEHOME_USER' $chosenUser
            Write-Ok "Updated CLAUDEHOME_USER=$chosenUser"
        }
    }
}
Write-Ok "SSH access to $chosenUser@$chosenHost confirmed. ✓"

# ── Step 9: fzf (optional) ────────────────────────────────────────────────────
Write-Step "Optional: fzf (arrow-key picker)"
if (Get-Command fzf.exe -ErrorAction SilentlyContinue) {
    Write-Ok "fzf already installed. ✓"
} elseif (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    Write-Ok "Installing fzf via winget..."
    & winget.exe install junegunn.fzf --accept-source-agreements --accept-package-agreements 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "fzf installed. ✓"
    } else {
        Write-Host "  fzf install failed (non-fatal — numbered menu will be used)."
    }
} else {
    Write-Host "  fzf not found and winget not available. Numbered menu will be used."
    Write-Host "  To enable arrow-key picker: winget install junegunn.fzf"
}

# ── Smoke test + summary ──────────────────────────────────────────────────────
Write-Host ""
$helpOut = & pwsh -NoProfile -File $ps1Path --help 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "Smoke test failed. Output:`n$helpOut"
    exit 1
}

Write-Host "────────────────────────────────────────────────────────────────────────────"
Write-Host "claudehome installed successfully."
Write-Host ""
Write-Host "  Host:    $chosenHost"
Write-Host "  User:    $chosenUser"
Write-Host "  Config:  $rcPath"
Write-Host ""
Write-Host "Open a NEW shell and run:  claudehome"
