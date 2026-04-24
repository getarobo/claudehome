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

Environment variables:
  CLAUDEHOME_HOST          Tailscale hostname of the Mac mini   (default: gene-mini)
  CLAUDEHOME_USER          SSH user on the Mac mini             (default: $env:USERNAME)
  CLAUDEHOME_PROJECTS_DIR  Projects root on the Mac mini        (default: ~/projects/claudecode)

Detach from an attached session with tmux's standard binding: Ctrl-b d.
The tmux session keeps running on the Mac mini after you disconnect.

Note: CLAUDEHOME_PROJECTS_DIR is a path on the Mac mini. If you use a
leading ~, set it as a literal so your client shell does not expand
the tilde locally: $env:CLAUDEHOME_PROJECTS_DIR = '~/other/root'
'@ | Write-Output
    exit 0
}

# ---- config ----
$HostName    = if ($env:CLAUDEHOME_HOST)          { $env:CLAUDEHOME_HOST }          else { 'gene-mini' }
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
$pickerLines = [System.Collections.Generic.List[string]]::new()
$pickerNames = [System.Collections.Generic.List[string]]::new()
$now = [DateTimeOffset]::Now.ToUnixTimeSeconds()

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
        $pickerLines.Add("$project  [active $label]")
    } else {
        $pickerLines.Add("$project  [idle]")
    }
    $pickerNames.Add($project)
}

if ($pickerNames.Count -eq 0) {
    Die "claudehome: no projects found in $ProjectsDir on $HostName.`n  Create one with: ssh $RemoteUser@$HostName 'mkdir -p $ProjectsDir/my-project'"
}

# ---- picker (fzf preferred, Read-Host numbered menu fallback) ----
$selected = $null
$fzf = Get-Command fzf.exe -ErrorAction SilentlyContinue
if ($fzf) {
    $selected = ($pickerLines -join "`n") | & fzf.exe --prompt='claudehome> ' --height=~50%
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

# Extract project name (everything before the double-space annotation).
$project = ($selected -split '  ', 2)[0]

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
$attachTpl = @'
bash --norc --noprofile -c '
  tmux new-session -A -D -s claudehome-__PROJECT__ -c __PROJECTS_DIR__/__PROJECT__ "claude; exec $SHELL"
'
'@
$attachCmd = $attachTpl.Replace('__PROJECT__', $project).Replace('__PROJECTS_DIR__', $ProjectsDir)

& ssh.exe -t "$RemoteUser@$HostName" $attachCmd
exit $LASTEXITCODE
