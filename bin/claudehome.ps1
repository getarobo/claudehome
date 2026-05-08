#Requires -Version 7.0
# claudehome.ps1 — PowerShell 7+ port of bin/claudehome.
# Strict parity with bash; see .omc/specs/deep-interview-claudehome-pc-v1.md
# and .omc/specs/deep-interview-claudehome-folder-tree-v1.md.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'          # consistent arg-passing on pwsh 7.0–7.6
$PSNativeCommandUseErrorActionPreference = $false     # allows native commands to write stderr without triggering a terminating error under Stop

# Force UTF-8 on the console and on bytes exchanged with native processes (ssh.exe).
# Without this, Korean (and any non-ASCII) project names and tmux/claude output
# get mangled by the legacy OEM/ANSI codepage before WezTerm ever sees them.
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)

# ---- help ----
if ($args.Count -ge 1 -and $args[0] -in @('-h', '--help')) {
    @'
Usage: claudehome

  Lists project directories under CLAUDEHOME_PROJECTS_DIR on the Mac mini,
  shows tmux session state for each, and attaches via SSH over Tailscale.
  Sessions are named claudehome-<project> and outlive any claude process.

  Folders organize projects in a drill-down picker — pick [new folder here]
  to create one. Project names are globally unique across the whole tree;
  tmux sessions are named claudehome-<basename> regardless of folder depth.
  The last picker row is [new project here] — pick it to create a fresh
  project at the current drill level. Names are validated against the same
  allowlist applied to env vars; duplicates are refused.

Environment variables (or set in ~/.claudehomerc):
  CLAUDEHOME_HOST          Tailscale hostname of the Mac mini   (required)
  CLAUDEHOME_USER          SSH user on the Mac mini             (default: $env:USERNAME)
  CLAUDEHOME_PROJECTS_DIR  Projects root on the Mac mini        (default: ~/projects/claudehome-projects)

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
$ProjectsDir = if ($env:CLAUDEHOME_PROJECTS_DIR)  { $env:CLAUDEHOME_PROJECTS_DIR }  else { '~/projects/claudehome-projects' }

# ---- validate config ----
# Allowlist-before-interpolation: all values are regex-validated before any string
# interpolation or splice. The character sets match bin/claudehome exactly.
$rxHost      = '^[a-zA-Z0-9._-]+$'
$rxUser      = '^[a-zA-Z0-9._-]+$'
$rxPath      = '^[a-zA-Z0-9._~/-]+$'
$rxProj      = '^[a-zA-Z0-9._-]+$'
$rxTreePath  = '^([a-zA-Z0-9._-]+/)*[a-zA-Z0-9._-]+$'

function Die([string]$msg) { [Console]::Error.WriteLine($msg); exit 1 }

if (-not $HostName) {
    Die "claudehome: CLAUDEHOME_HOST is not set.`n  Run .\install_client.ps1 to configure, or: `$env:CLAUDEHOME_HOST = '<tailscale-hostname>'"
}
if ($HostName    -notmatch $rxHost) { Die "claudehome: CLAUDEHOME_HOST='$HostName' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '-'" }
if ($RemoteUser  -notmatch $rxUser) { Die "claudehome: CLAUDEHOME_USER='$RemoteUser' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '-'" }
if ($ProjectsDir -notmatch $rxPath) { Die "claudehome: CLAUDEHOME_PROJECTS_DIR='$ProjectsDir' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '/', '~', '-'" }

# ---- remote tree-walk emitter (single-SSH fetch) ----
# Wire format: ---TREE---<rows>---TMUX---<sessions>
# Rows: <relpath>\t<type>\t<child_count>; type ∈ {R, F, P}.
# This bash payload is byte-identical with bin/claudehome's remote SSH block.
# It runs on the mini's bash inside `bash --norc --noprofile -c '...'`, so every
# `$` that should reach the remote bash is escaped as `\$` and every double
# quote is escaped as `\"`. The truncation cap uses a portable bash counter
# (BWK awk on macOS does not support -v RS='\0' reliably).
$remoteDataTpl = @'
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash --norc --noprofile -c '
  cd __PROJECTS_DIR__ 2>/dev/null || exit 0
  echo ---TREE---
  total=$(find . -maxdepth 8 -type d ! -path "*/.*" 2>/dev/null | wc -l | tr -d " ")
  deeper=$(find . -mindepth 9 -type d ! -path "*/.*" 2>/dev/null | head -n 1)
  i=0
  find . -maxdepth 8 -type d ! -path "*/.*" -print0 2>/dev/null \
    | while IFS= read -r -d "" p; do
        i=$(( i + 1 ))
        [ "$i" -gt 2000 ] && break
        rel="${p#./}"
        [ "$p" = "." ] && rel="."
        n_all=0; n_dirs=0
        for c in "$p"/* "$p"/.[!.]* "$p"/..?* ; do
          [ -e "$c" ] || continue
          n_all=$(( n_all + 1 ))
          [ -d "$c" ] && n_dirs=$(( n_dirs + 1 ))
        done
        if [ "$rel" = "." ]; then
          t=R
        elif [ "$n_all" -gt 0 ] && [ "$n_all" = "$n_dirs" ]; then
          t=F
        else
          t=P
        fi
        printf "%s\t%s\t%s\n" "$rel" "$t" "$n_all"
      done
  [ "$total" -gt 2000 ] && echo ---TRUNCATED---
  [ -n "$deeper" ] && echo ---DEPTH-TRUNCATED---
  echo ---TMUX---
  tmux list-sessions -F "#{session_name} #{session_activity}" 2>/dev/null || true
'
'@

function Invoke-RemoteFetch {
    $cmd = $remoteDataTpl.Replace('__PROJECTS_DIR__', $ProjectsDir)
    $out = & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $cmd 2>$null
    if ($LASTEXITCODE -ne 0) {
        Die @"
claudehome: cannot reach $RemoteUser@$HostName over SSH.
  - Check Tailscale is up on both devices:   tailscale status
  - Check Mac mini Remote Login is enabled:  System Settings > General > Sharing
  - Check your SSH key is authorized on the Mac mini.
"@
    }
    if ($out -is [array]) { $out = $out -join "`n" }
    return [string]$out
}

# ---- parse RAW into tree + tmux blocks ----
# $script:treeRows is a List of [PSCustomObject]@{ Path; Type; Children; Parent }.
# $script:tmuxBlock holds the raw "<name> <ts>" lines for activity lookups.
# $script:skippedBadPaths counts wire-format-invariant violations for a single
# deduped stderr warning per session.
$script:treeRows         = [System.Collections.Generic.List[object]]::new()
$script:tmuxBlock        = ''
$script:skippedBadPaths  = 0
$script:truncatedRows    = $false
$script:truncatedDepth   = $false

function Read-Tree {
    param([string]$Raw)

    $idxTree = $Raw.IndexOf('---TREE---')
    $idxTmux = $Raw.IndexOf('---TMUX---')
    if ($idxTree -lt 0) {
        # No tree marker — treat the whole thing as tmux block (legacy / error path).
        $treeBlock = ''
        $script:tmuxBlock = if ($idxTmux -ge 0) { $Raw.Substring($idxTmux + '---TMUX---'.Length) } else { $Raw }
    } elseif ($idxTmux -lt 0) {
        $treeBlock = $Raw.Substring($idxTree + '---TREE---'.Length)
        $script:tmuxBlock = ''
    } else {
        $treeBlock = $Raw.Substring($idxTree + '---TREE---'.Length, $idxTmux - $idxTree - '---TREE---'.Length)
        $script:tmuxBlock = $Raw.Substring($idxTmux + '---TMUX---'.Length)
    }

    $script:treeRows.Clear()
    $script:skippedBadPaths = 0
    $script:truncatedRows   = $false
    $script:truncatedDepth  = $false

    foreach ($row in ($treeBlock -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        if ($row -eq '---TRUNCATED---')       { $script:truncatedRows  = $true; continue }
        if ($row -eq '---DEPTH-TRUNCATED---') { $script:truncatedDepth = $true; continue }

        # TAB-split via backtick-t in DOUBLE quotes (PowerShell's TAB escape
        # sequence — unambiguous, locale-independent, see plan §R7).
        $parts = $row -split "`t"
        if ($parts.Count -lt 2) { continue }
        $tp = $parts[0]
        $tt = $parts[1]
        $tc = if ($parts.Count -ge 3) { $parts[2] } else { '0' }
        if ([string]::IsNullOrEmpty($tp) -or [string]::IsNullOrEmpty($tt)) { continue }

        # Wire-format invariant (P6): every path is `.` (synthetic root) or
        # matches the allowlist regex. Drop bad rows silently and bump the
        # counter for a single deduped stderr warning. The type-validity
        # check catches TAB-in-name corruption that the path regex misses
        # (corrupted row's first field can pass the allowlist while $tt
        # holds garbage like "tab" or "F\t0"); see plan §R6 + bash parity.
        if ($tt -notmatch '^[RFP]$') {
            $script:skippedBadPaths++
            continue
        }
        if ($tp -ne '.' -and $tp -notmatch $rxTreePath) {
            $script:skippedBadPaths++
            continue
        }

        $parent =
            if ($tp -eq '.')          { '' }
            elseif ($tp.Contains('/')) { $tp.Substring(0, $tp.LastIndexOf('/')) }
            else                       { '' }

        $cnum = 0
        [int]::TryParse($tc, [ref]$cnum) | Out-Null

        $script:treeRows.Add([PSCustomObject]@{
            Path     = $tp
            Type     = $tt
            Children = $cnum
            Parent   = $parent
        })
    }

    if ($script:skippedBadPaths -gt 0) {
        [Console]::Error.WriteLine("claudehome: skipped $($script:skippedBadPaths) path with disallowed characters — rename on the mini to surface it")
    }
    if ($script:truncatedRows) {
        [Console]::Error.WriteLine('claudehome: tree truncated at 2000 entries — clean up your projects dir')
    }
    if ($script:truncatedDepth) {
        [Console]::Error.WriteLine('claudehome: tree depth >8 not shown — reorganize on the mini')
    }
}

# Initial fetch.
$raw = Invoke-RemoteFetch
Read-Tree -Raw $raw

# ---- tmux session activity lookup ----
function Get-SessionActivity {
    param([string]$Basename)
    $target = "claudehome-$Basename"
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    foreach ($line in ($script:tmuxBlock -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\s+', 2
        if ($parts.Count -ne 2) { continue }
        if ($parts[0] -ne $target) { continue }
        $ts = 0L
        if (-not [int64]::TryParse($parts[1], [ref]$ts)) { continue }
        $age = $now - $ts
        if ($age -lt 0) { $age = 0 }
        $label =
            if     ($age -lt 60)    { "${age}s ago" }
            elseif ($age -lt 3600)  { "$([Math]::Floor($age / 60))m ago" }
            elseif ($age -lt 86400) { "$([Math]::Floor($age / 3600))h ago" }
            else                    { "$([Math]::Floor($age / 86400))d ago" }
        return [PSCustomObject]@{ Ts = $ts; Label = $label }
    }
    return $null
}

# ---- Get-RowList ----
# Returns a list of [PSCustomObject]@{ Line; Kind; Payload } in spec-mandated
# order. Mirrors bash build_rows_for_path():
#   - [..  back] for non-root non-root_bucket frames
#   - folders alphabetical
#   - active projects descending by ts, then idle alphabetical
#   - synthetic (root) bucket only at true top level when both folders AND
#     root projects exist
#   - [new folder here] then [new project here] always last
function Get-RowList {
    param([string]$Path)

    $out = [System.Collections.Generic.List[object]]::new()

    if (-not [string]::IsNullOrEmpty($Path) -and $Path -ne '.root') {
        $out.Add([PSCustomObject]@{ Line = '[..  back]'; Kind = 'back'; Payload = '' })
    }

    $rootBucketMode = $false
    if ($Path -eq '.root') {
        $matchParent = ''
        $rootBucketMode = $true
    } else {
        $matchParent = $Path
    }

    $folderItems = [System.Collections.Generic.List[object]]::new()
    $activeItems = [System.Collections.Generic.List[object]]::new()
    $idleItems   = [System.Collections.Generic.List[object]]::new()

    $rootHasFolders  = $false
    $rootHasProjects = $false

    foreach ($r in $script:treeRows) {
        if ($r.Path -eq '.') { continue }
        if ([string]::IsNullOrEmpty($Path)) {
            if ($r.Parent -eq '' -and $r.Type -eq 'F') { $rootHasFolders  = $true }
            if ($r.Parent -eq '' -and $r.Type -eq 'P') { $rootHasProjects = $true }
        }
        if ($r.Parent -ne $matchParent) { continue }
        if ($rootBucketMode -and $r.Type -ne 'P') { continue }

        $basename = if ($r.Path.Contains('/')) { $r.Path.Substring($r.Path.LastIndexOf('/') + 1) } else { $r.Path }

        if ($r.Type -eq 'F') {
            $folderItems.Add([PSCustomObject]@{
                Line     = "$basename/  ($($r.Children))"
                Basename = $basename
                Path     = $r.Path
            })
        } else {
            $act = Get-SessionActivity -Basename $basename
            if ($null -ne $act) {
                $activeItems.Add([PSCustomObject]@{
                    Line     = "$basename  [active $($act.Label)]"
                    Basename = $basename
                    Ts       = [int64]$act.Ts
                    Path     = $r.Path
                })
            } else {
                $idleItems.Add([PSCustomObject]@{
                    Line     = "$basename  [idle]"
                    Basename = $basename
                    Path     = $r.Path
                })
            }
        }
    }

    foreach ($f in ($folderItems | Sort-Object -Property Basename -Culture ([System.Globalization.CultureInfo]::InvariantCulture))) {
        $out.Add([PSCustomObject]@{ Line = $f.Line; Kind = 'folder'; Payload = $f.Path })
    }
    foreach ($a in ($activeItems | Sort-Object @{Expression='Ts'; Descending=$true}, @{Expression='Basename'; Descending=$false})) {
        $out.Add([PSCustomObject]@{ Line = $a.Line; Kind = 'project'; Payload = $a.Path })
    }
    foreach ($i in ($idleItems | Sort-Object -Property Basename -Culture ([System.Globalization.CultureInfo]::InvariantCulture))) {
        $out.Add([PSCustomObject]@{ Line = $i.Line; Kind = 'project'; Payload = $i.Path })
    }

    # `(root)` bucket — only at true top level (Path == '') and only when both
    # root folders AND root projects exist. When shown, strip the per-project
    # root rows we already appended above (they duplicate the bucket contents).
    if ([string]::IsNullOrEmpty($Path) -and $rootHasFolders -and $rootHasProjects) {
        $rootN = 0
        foreach ($r in $script:treeRows) {
            if ($r.Type -eq 'P' -and $r.Parent -eq '') { $rootN++ }
        }
        # Strip top-level project rows we appended (Payload has no '/').
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $out) {
            if ($row.Kind -eq 'project' -and -not $row.Payload.Contains('/')) { continue }
            $kept.Add($row)
        }
        $out = $kept
        $out.Add([PSCustomObject]@{ Line = "(root)  ($rootN)"; Kind = 'root_bucket'; Payload = '.root' })
    }

    $out.Add([PSCustomObject]@{ Line = '[new folder here]';  Kind = 'new_folder';  Payload = '' })
    $out.Add([PSCustomObject]@{ Line = '[new project here]'; Kind = 'new_project'; Payload = '' })
    return $out
}

# ---- Select-One ----
# Renders $Lines via fzf (preferred) or numbered Read-Host menu. Returns the
# zero-based index of the picked row, or -1 for cancel/empty/Ctrl-C.
function Select-One {
    param([string[]]$Lines)
    if ($null -eq $Lines -or $Lines.Count -eq 0) { return -1 }

    $fzf = Get-Command fzf.exe -ErrorAction SilentlyContinue
    if ($fzf) {
        $picked = ($Lines -join "`n") | & fzf.exe --prompt='claudehome> ' --height=~50% --reverse
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($picked)) { return -1 }
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -eq $picked) { return $i }
        }
        return -1
    }

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        Write-Host ("{0,3}) {1}" -f ($i + 1), $Lines[$i])
    }
    while ($true) {
        $answer = Read-Host 'Select'
        if ([string]::IsNullOrEmpty($answer)) { return -1 }
        if ($answer -match '^\d+$') {
            $n = [int]$answer
            if ($n -ge 1 -and $n -le $Lines.Count) { return ($n - 1) }
        }
    }
}

# ---- Update-Tree ----
# Re-runs the SSH fetch + parser. Used after folder creation so the new folder
# is visible in the next picker render. Unlike Invoke-RemoteFetch (initial
# fetch — dies on SSH failure), Update-Tree keeps the stale tree on failure and
# warns to stderr. Mirrors bash refetch_tree's `|| return 0` behavior so the
# picker survives a transient network blip after a successful initial fetch.
function Update-Tree {
    $cmd = $remoteDataTpl.Replace('__PROJECTS_DIR__', $ProjectsDir)
    $out = & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $cmd 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine('claudehome: tree refresh failed; using cached view')
        return
    }
    if ($out -is [array]) { $out = $out -join "`n" }
    Read-Tree -Raw ([string]$out)
}

# ---- New-Folder ----
# Prompts for a basename, validates against the allowlist + sibling collision,
# creates the folder via SSH `mkdir -p`, refetches the tree. Returns $true on
# success, $false on user cancel / empty input.
function New-Folder {
    param([string]$ParentPath)

    while ($true) {
        $name = Read-Host 'New folder name'
        if ([string]::IsNullOrEmpty($name)) { return $false }
        if ($name -notmatch $rxProj) {
            [Console]::Error.WriteLine("  '$name' has unsupported characters. Allowed: letters, digits, '.', '_', '-'. Try again.")
            continue
        }
        if ($name -eq '.' -or $name -eq '..' -or $name.StartsWith('.')) {
            [Console]::Error.WriteLine("  '$name' is reserved. Pick a different name.")
            continue
        }
        # Sibling collision: any row at the same parent (folder OR project).
        $collide = $false
        foreach ($r in $script:treeRows) {
            if ($r.Parent -ne $ParentPath) { continue }
            $exb = if ($r.Path.Contains('/')) { $r.Path.Substring($r.Path.LastIndexOf('/') + 1) } else { $r.Path }
            if ($exb -eq $name) { $collide = $true; break }
        }
        if ($collide) {
            $where = if ([string]::IsNullOrEmpty($ParentPath)) { $name } else { "$ParentPath/$name" }
            [Console]::Error.WriteLine("  '$name' already exists at $where. Pick a different name.")
            continue
        }
        # Create on disk via SSH.
        $rel = if ([string]::IsNullOrEmpty($ParentPath)) { $name } else { "$ParentPath/$name" }
        $mkTpl = @'
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash --norc --noprofile -c 'mkdir -p __PROJECTS_DIR__/__REL__'
'@
        $mkCmd = $mkTpl.Replace('__PROJECTS_DIR__', $ProjectsDir).Replace('__REL__', $rel)
        & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $mkCmd 2>$null | Out-Null
        Update-Tree
        return $true
    }
}

# ---- New-Project ----
# Prompts for a basename. Sibling collision (same parent, any type) AND
# globally-unique scan (any P-type row with same basename) — error wording is
# byte-identical with bash AC-FT4. Returns the basename on success, $null on
# cancel / empty input. The mkdir for the project itself happens at attach
# time (idempotent — same as bash).
function New-Project {
    param([string]$ParentPath)

    while ($true) {
        $name = Read-Host 'New project name'
        if ([string]::IsNullOrEmpty($name)) { return $null }
        if ($name -notmatch $rxProj) {
            [Console]::Error.WriteLine("  '$name' has unsupported characters. Allowed: letters, digits, '.', '_', '-'. Try again.")
            continue
        }
        if ($name -eq '.' -or $name -eq '..' -or $name.StartsWith('.')) {
            [Console]::Error.WriteLine("  '$name' is reserved. Pick a different name.")
            continue
        }
        # Sibling collision (same parent, any type).
        $collide = $false
        foreach ($r in $script:treeRows) {
            if ($r.Parent -ne $ParentPath) { continue }
            $exb = if ($r.Path.Contains('/')) { $r.Path.Substring($r.Path.LastIndexOf('/') + 1) } else { $r.Path }
            if ($exb -eq $name) { $collide = $true; break }
        }
        if ($collide) {
            $where = if ([string]::IsNullOrEmpty($ParentPath)) { $name } else { "$ParentPath/$name" }
            [Console]::Error.WriteLine("  '$name' already exists at $where. Pick a different name.")
            continue
        }
        # Globally-unique scan: any P-type row anywhere in the tree with the
        # same basename. Cite the conflicting full path (AC-FT-PC4).
        $conflict = $null
        foreach ($r in $script:treeRows) {
            if ($r.Type -ne 'P') { continue }
            $exb = if ($r.Path.Contains('/')) { $r.Path.Substring($r.Path.LastIndexOf('/') + 1) } else { $r.Path }
            if ($exb -eq $name) { $conflict = $r.Path; break }
        }
        if ($null -ne $conflict) {
            [Console]::Error.WriteLine("  '$name' already exists at $conflict. Pick a different name.")
            continue
        }
        return $name
    }
}

# ---- Invoke-PickerLoop ----
# Recursive drill loop. Returns @{ Action='attach'; Project=<basename>;
# Parent=<parent path or ''> } on a project pick, or $null on cancel/back/exit.
# Unlike bash, PowerShell has no `set -e` constraint, so we use return values
# instead of globals.
function Invoke-PickerLoop {
    param([string]$Path)
    while ($true) {
        $rows = Get-RowList -Path $Path
        $lines = @($rows | ForEach-Object { $_.Line })
        $idx = Select-One -Lines $lines
        if ($idx -lt 0) { return $null }
        $row = $rows[$idx]
        switch ($row.Kind) {
            'back'         { return $null }
            'folder'       {
                $r = Invoke-PickerLoop -Path $row.Payload
                if ($null -ne $r) { return $r }
            }
            'root_bucket'  {
                $r = Invoke-PickerLoop -Path '.root'
                if ($null -ne $r) { return $r }
            }
            'project'      {
                $parent =
                    if ($Path -eq '.root') { '' }
                    elseif ($row.Payload.Contains('/')) { $row.Payload.Substring(0, $row.Payload.LastIndexOf('/')) }
                    else                                { '' }
                $basename = if ($row.Payload.Contains('/')) { $row.Payload.Substring($row.Payload.LastIndexOf('/') + 1) } else { $row.Payload }
                return @{ Action = 'attach'; Project = $basename; Parent = $parent }
            }
            'new_project'  {
                $parentForCreate = if ($Path -eq '.root') { '' } else { $Path }
                $name = New-Project -ParentPath $parentForCreate
                if ($null -ne $name) {
                    return @{ Action = 'attach'; Project = $name; Parent = $parentForCreate }
                }
            }
            'new_folder'   {
                $parentForCreate = if ($Path -eq '.root') { '' } else { $Path }
                if (New-Folder -ParentPath $parentForCreate) {
                    # Tree is refetched; loop re-renders with new folder visible.
                }
            }
        }
    }
}

# ---- top-level dispatch ----
$result = Invoke-PickerLoop -Path ''
if ($null -eq $result) { exit 0 }

$project    = $result.Project
$attachPath = $result.Parent

# Defense-in-depth: revalidate basename and parent path at the SSH boundary.
if ($project -notmatch $rxProj) {
    Die "claudehome: project directory '$project' has characters that cannot be safely passed to SSH.`n  Rename it on $HostName to use only letters, digits, '.', '_', '-'."
}
if (-not [string]::IsNullOrEmpty($attachPath) -and $attachPath -notmatch $rxTreePath) {
    Die "claudehome: parent path '$attachPath' has characters that cannot be safely passed to SSH."
}

# ---- attach (or create) tmux session ----
# Session name is `claudehome-<basename>` regardless of folder depth — the
# folder is invisible at the tmux layer (AC-FT-PC3).
# `-A` (no `-D`): attach if exists, create otherwise. Multiple clients may stay
# attached to the same session simultaneously — tmux reflows to the most-
# recently-active client.
# `mkdir -p` is idempotent: a no-op for existing projects, and creates the
# directory (and any missing parent folders) for newly-named ones.
$attachTpl = @'
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash --norc --noprofile -c '
  mkdir -p __PROJECTS_DIR__/__PARENT_AND_PROJECT__
  tmux new-session -A -s claudehome-__PROJECT__ -c __PROJECTS_DIR__/__PARENT_AND_PROJECT__ "claude; exec $SHELL"
'
'@
$parentAndProject = if ([string]::IsNullOrEmpty($attachPath)) { $project } else { "$attachPath/$project" }
$attachCmd = $attachTpl.Replace('__PARENT_AND_PROJECT__', $parentAndProject).Replace('__PROJECT__', $project).Replace('__PROJECTS_DIR__', $ProjectsDir)

& ssh.exe -t "$RemoteUser@$HostName" $attachCmd
exit $LASTEXITCODE
