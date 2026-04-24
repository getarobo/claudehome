#Requires -Version 7.0
# install.ps1 — install claudehome PC client for the current user.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$binDir   = Join-Path $repoRoot 'bin'
$ps1Path  = Join-Path $binDir 'claudehome.ps1'
$cmdPath  = Join-Path $binDir 'claudehome.cmd'

# 1. Sanity: script must exist in bin/.
if (-not (Test-Path -LiteralPath $ps1Path)) {
    [Console]::Error.WriteLine("install.ps1: $ps1Path not found. Run from the repo root.")
    exit 1
}

# 2. Drop / verify the .cmd shim (idempotent).
$shimLine = '@pwsh -NoProfile -File "%~dp0claudehome.ps1" %*'
if (Test-Path -LiteralPath $cmdPath) {
    $existing = (Get-Content -LiteralPath $cmdPath -Raw).Trim()
    if ($existing -notlike '*pwsh*claudehome.ps1*') {
        [Console]::Error.WriteLine("install.ps1: $cmdPath exists but isn't our shim. Refusing to overwrite.")
        exit 1
    }
    # Already our shim — leave it.
} else {
    Set-Content -LiteralPath $cmdPath -Value "@REM claudehome shim`r`n$shimLine`r`n" -Encoding ASCII -NoNewline
}

# 3. Add <repo>\bin to the current user's PATH (idempotent, case-insensitive).
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$entries  = if ($userPath) { $userPath -split ';' | Where-Object { $_ -ne '' } } else { @() }
if (-not ($entries | Where-Object { $_ -ieq $binDir })) {
    $trimmed = if ($userPath) { $userPath.TrimEnd(';') } else { '' }
    $newPath = if ([string]::IsNullOrEmpty($trimmed)) { $binDir } else { "$trimmed;$binDir" }
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Write-Host "Added $binDir to your user PATH."
    Write-Host "Open a NEW pwsh (or cmd.exe) session for the change to take effect."
} else {
    Write-Host "$binDir already in user PATH; nothing to do."
}

# 4. Smoke test: run --help directly via the .ps1 (doesn't require PATH update to be live).
$help = & pwsh -NoProfile -File $ps1Path --help 2>&1
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("install.ps1: smoke test failed. Output:`n$help")
    exit 1
}

Write-Host ''
Write-Host 'claudehome installed successfully.'
Write-Host 'In a NEW shell session, run:  claudehome'
