#Requires -Version 7.0
# claudehome.ps1 — PowerShell 7+ port of bin/claudehome.
# Strict parity with bash; see .omc/specs/deep-interview-claudehome-pc-v1.md.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'          # consistent arg-passing on pwsh 7.0–7.6
$PSNativeCommandUseErrorActionPreference = $false     # allows native commands to write stderr without triggering a terminating error under Stop

# ---- help ----
if ($args.Count -ge 1 -and $args[0] -in @('-h', '--help')) {
    @'
Usage: claudehome

  Lists project directories under CLAUDEHOME_PROJECTS_DIR on the Mac mini,
  shows tmux session state for each, and attaches via SSH over Tailscale.
  Sessions are named claudehome-<project> and outlive any claude process.

  The last picker row is [new project] — pick it to create a fresh
  directory on the Mac mini and start a session there. Names are validated
  against the same allowlist applied to env vars; duplicates are refused.

Environment variables (or set in ~/.claudehomerc):
  CLAUDEHOME_HOST          Tailscale hostname of the Mac mini   (required)
  CLAUDEHOME_USER          SSH user on the Mac mini             (default: $env:USERNAME)
  CLAUDEHOME_PROJECTS_DIR  Projects root on the Mac mini        (default: ~/projects/claudecode)

Config file: ~/.claudehomerc — written by install_client.ps1. Format: KEY=VALUE, one per line.
Environment variables take precedence over values in the config file.

Detach from an attached session with tmux's standard binding:
  Ctrl-b then d  (two keystrokes: hold Ctrl+b, release, then press d)
The tmux session keeps running on the Mac mini after you disconnect.

Note: CLAUDEHOME_PROJECTS_DIR is a path on the Mac mini. If you use a
leading ~, set it as a literal so your client shell does not expand
the tilde locally: $env:CLAUDEHOME_PROJECTS_DIR = '~/other/root'
'@ | Write-Output
    exit 0
}

# ---- load config file (env vars take precedence) ----
$rcPath = Join-Path $HOME '.claudehomerc'
if (Test-Path -LiteralPath $rcPath) {
    foreach ($line in (Get-Content -LiteralPath $rcPath)) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^(CLAUDEHOME_[A-Z_]+)=(.*)$') {
            $k = $Matches[1]; $v = $Matches[2]
            if (-not (Test-Path "Env:$k")) {
                Set-Item "Env:$k" $v
            }
        }
    }
}

# ---- config ----
$HostName    = if ($env:CLAUDEHOME_HOST)          { $env:CLAUDEHOME_HOST }          else { $null }
$RemoteUser  = if ($env:CLAUDEHOME_USER)          { $env:CLAUDEHOME_USER }          else { $env:USERNAME }
$ProjectsDir = if ($env:CLAUDEHOME_PROJECTS_DIR)  { $env:CLAUDEHOME_PROJECTS_DIR }  else { '~/projects/claudecode' }

# ---- validate config ----
# Allowlist-before-interpolation: all values are regex-validated before any string
# interpolation or splice. The character sets match bin/claudehome exactly.
$rxHost = '^[a-zA-Z0-9._-]+$'
$rxUser = '^[a-zA-Z0-9._-]+$'
$rxPath = '^[a-zA-Z0-9._~/-]+$'
$rxProj = '^[a-zA-Z0-9._-]+$'

function Die([string]$msg) { [Console]::Error.WriteLine($msg); exit 1 }

if (-not $HostName) {
    Die "claudehome: CLAUDEHOME_HOST is not set.`n  Run .\install_client.ps1 to configure, or: `$env:CLAUDEHOME_HOST = '<tailscale-hostname>'"
}
if ($HostName    -notmatch $rxHost) { Die "claudehome: CLAUDEHOME_HOST='$HostName' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '-'" }
if ($RemoteUser  -notmatch $rxUser) { Die "claudehome: CLAUDEHOME_USER='$RemoteUser' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '-'" }
if ($ProjectsDir -notmatch $rxPath) { Die "claudehome: CLAUDEHOME_PROJECTS_DIR='$ProjectsDir' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '/', '~', '-'" }

# ---- fetch picker data (single SSH round-trip) ----
# Single-quoted here-string + .Replace() avoids both PS $-interpolation and the
# -f operator's FormatException on tmux's #{session_name} format tokens.
$remoteDataTpl = @'
bash --norc --noprofile -c '
  ls -1 __PROJECTS_DIR__ 2>/dev/null || true
  echo ---TMUX---
  tmux list-sessions -F "#{session_name} #{session_activity}" 2>/dev/null || true
'
'@
$remoteDataCmd = $remoteDataTpl.Replace('__PROJECTS_DIR__', $ProjectsDir)

$raw = & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $remoteDataCmd 2>$null
if ($LASTEXITCODE -ne 0) {
    Die @"
claudehome: cannot reach $RemoteUser@$HostName over SSH.
  - Check Tailscale is up on both devices:   tailscale status
  - Check Mac mini Remote Login is enabled:  System Settings > General > Sharing
  - Check your SSH key is authorized on the Mac mini.
"@
}

# ---- parse output ----
if ($raw -is [array]) { $raw = $raw -join "`n" }
$raw = [string]$raw

$idx = $raw.IndexOf('---TMUX---')
if ($idx -lt 0) {
    $projectsBlock = $raw
    $tmuxBlock     = ''
} else {
    $projectsBlock = $raw.Substring(0, $idx)
    $tmuxBlock     = $raw.Substring($idx + '---TMUX---'.Length)
}

# Build { session_name -> activity_ts } map from tmux block.
$sessions = @{}
foreach ($line in ($tmuxBlock -split "`r?`n")) {
    $line = $line.Trim()
    if ([string]::IsNullOrEmpty($line)) { continue }
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2) {
        $ts = 0L
        if ([int64]::TryParse($parts[1], [ref]$ts)) { $sessions[$parts[0]] = $ts }
    }
}

# ---- build picker rows ----
# Ordering: active projects first, sorted by tmux session activity descending
# (most-recently-used at top); idle projects below them, alphabetical; the
# `[new project]` sentinel is always the last row.
$NewProjectRow = '[new project]'
$pickerNames = [System.Collections.Generic.List[string]]::new()
$now = [DateTimeOffset]::Now.ToUnixTimeSeconds()

# Collect rows with a numeric sort key (tmux activity for active, 0 for idle).
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($project in ($projectsBlock -split "`r?`n")) {
    $project = $project.Trim()
    if ([string]::IsNullOrEmpty($project)) { continue }
    $sname = "claudehome-$project"
    if ($sessions.ContainsKey($sname)) {
        $age = $now - $sessions[$sname]
        if ($age -lt 0) { $age = 0 }
        $label = if     ($age -lt 60)    { "${age}s ago" }
                 elseif ($age -lt 3600)  { "$([Math]::Floor($age / 60))m ago" }
                 elseif ($age -lt 86400) { "$([Math]::Floor($age / 3600))h ago" }
                 else                    { "$([Math]::Floor($age / 86400))d ago" }
        $rows.Add([PSCustomObject]@{ Key = [int64]$sessions[$sname]; Line = "$project  [active $label]" })
    } else {
        $rows.Add([PSCustomObject]@{ Key = [int64]0; Line = "$project  [idle]" })
    }
    $pickerNames.Add($project)
}

$pickerLines = [System.Collections.Generic.List[string]]::new()
foreach ($row in ($rows | Sort-Object @{Expression='Key'; Descending=$true}, @{Expression='Line'; Descending=$false})) {
    $pickerLines.Add($row.Line)
}
$pickerLines.Add($NewProjectRow)

# ---- picker (fzf preferred, Read-Host numbered menu fallback) ----
$selected = $null
$fzf = Get-Command fzf.exe -ErrorAction SilentlyContinue
if ($fzf) {
    $selected = ($pickerLines -join "`n") | & fzf.exe --prompt='claudehome> ' --height=~50% --reverse
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($selected)) { exit 0 }
} else {
    for ($i = 0; $i -lt $pickerLines.Count; $i++) {
        Write-Host ("{0,3}) {1}" -f ($i + 1), $pickerLines[$i])
    }
    while ($true) {
        $answer = Read-Host 'Select a project'
        if ([string]::IsNullOrEmpty($answer)) { exit 0 }
        if ($answer -match '^\d+$') {
            $n = [int]$answer
            if ($n -ge 1 -and $n -le $pickerLines.Count) {
                $selected = $pickerLines[$n - 1]
                break
            }
        }
    }
}

# Resolve the picked row into a project name. The `[new project]` sentinel
# triggers an inline prompt loop; otherwise extract the name from the row
# (everything before the double-space annotation column).
if ($selected -eq $NewProjectRow) {
    $project = ''
    while ([string]::IsNullOrEmpty($project)) {
        $newName = Read-Host 'New project name'
        if ([string]::IsNullOrEmpty($newName)) { exit 0 }
        if ($newName -notmatch $rxProj) {
            [Console]::Error.WriteLine("  '$newName' has unsupported characters. Allowed: letters, digits, '.', '_', '-'. Try again.")
            continue
        }
        if ($pickerNames -contains $newName) {
            [Console]::Error.WriteLine("  '$newName' already exists. Pick a different name.")
            continue
        }
        $project = $newName
    }
} else {
    $project = ($selected -split '  ', 2)[0]
}

# Revalidate the project name — a malicious or accidental directory name on the
# Mac mini should not break out of the remote bash -c quoting.
if ($project -notmatch $rxProj) {
    Die "claudehome: project directory '$project' has characters that cannot be safely passed to SSH.`n  Rename it on $HostName to use only letters, digits, '.', '_', '-'."
}

# ---- attach (or create) tmux session ----
# Single-quoted here-string keeps $SHELL literal for remote bash expansion.
# .Replace() used (not -f) for consistency with the fetch payload — prevents
# FormatException if anyone later adds tmux #{...} format tokens to this template.
# -A -D: attach if session exists (create otherwise), and detach any other clients.
# `mkdir -p` is idempotent: a no-op for existing projects, and creates the
# directory (and the projects root if missing) for newly-named ones.
$attachTpl = @'
bash --norc --noprofile -c '
  mkdir -p __PROJECTS_DIR__/__PROJECT__
  tmux new-session -A -D -s claudehome-__PROJECT__ -c __PROJECTS_DIR__/__PROJECT__ "claude; exec $SHELL"
'
'@
$attachCmd = $attachTpl.Replace('__PROJECT__', $project).Replace('__PROJECTS_DIR__', $ProjectsDir)

& ssh.exe -t "$RemoteUser@$HostName" $attachCmd
exit $LASTEXITCODE
