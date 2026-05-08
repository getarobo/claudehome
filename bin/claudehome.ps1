#Requires -Version 7.0
# claudehome.ps1 — PowerShell 7+ port of bin/claudehome.
# Strict parity with bash; see .omc/specs/deep-interview-claudehome-5type-v1.md
# and .omc/plans/claudehome-5type-v1-plan.md.
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

# Write-WarnStderr — print prefixed warning to stderr.
# Defined early so all helpers can use it. Always succeeds. Pwsh equivalent of
# bash `warn()`; AC-5T-PC14 byte-identical-bytes principle keeps the wording in
# lockstep with bash's warn helper.
function Write-WarnStderr {
    param([string]$Message)
    [Console]::Error.WriteLine("claudehome: $Message")
}

# ---- help ----
if ($args.Count -ge 1 -and $args[0] -in @('-h', '--help')) {
    @'
Usage: claudehome

  Lists project directories under CLAUDEHOME_PROJECTS_DIR on the Mac mini,
  shows tmux session state for each, and attaches via SSH over Tailscale.
  Sessions are named claudehome-<project> and outlive any claude process.

  5-type structure: Folders organize, Suites group masterplan workspaces
  (*_suite), Projects/Hubs/Members are attachable. The last picker row is
  [new...] — pick a type and a name. Suite-with-Hub Members get hub-aware
  scaffolding (git init + @-import + projects.md row). Project/Hub/Member
  names are globally unique across the whole tree; tmux sessions are named
  claudehome-<basename> regardless of depth.

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

function Invoke-Die {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

if (-not $HostName) {
    Invoke-Die "claudehome: CLAUDEHOME_HOST is not set.`n  Run .\install_client.ps1 to configure, or: `$env:CLAUDEHOME_HOST = '<tailscale-hostname>'"
}
if ($HostName    -notmatch $rxHost) { Invoke-Die "claudehome: CLAUDEHOME_HOST='$HostName' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '-'" }
if ($RemoteUser  -notmatch $rxUser) { Invoke-Die "claudehome: CLAUDEHOME_USER='$RemoteUser' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '-'" }
if ($ProjectsDir -notmatch $rxPath) { Invoke-Die "claudehome: CLAUDEHOME_PROJECTS_DIR='$ProjectsDir' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '/', '~', '-'" }

# ---- remote tree-walk emitter (single-SSH fetch) ----
# Wire format: ---TREE---<rows>---TMUX---<sessions>
# Rows: <relpath>\t<type>\t<child_count>; type ∈ {R, F, S, P} on the wire
# (server emits 4 codes; H/M synthesized client-side by Read-Tree).
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
        if [ "$rel" = "." ]; then
          t=R
        elif [ -f "$p/CLAUDE.md" ]; then
          t=P
        else
          case "${p##*/}" in
            *_suite) t=S ;;
            *)       t=F ;;
          esac
        fi
        n_all=0
        if [ "$t" = "F" ] || [ "$t" = "S" ] || [ "$t" = "R" ]; then
          for c in "$p"/* "$p"/.[!.]* "$p"/..?* ; do
            [ -e "$c" ] || continue
            n_all=$(( n_all + 1 ))
          done
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
        Invoke-Die @"
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
# Type field is mutable so the post-classification pass can promote P → H/M and
# demote nested S → F. PowerShell's Sort-Object by property still works on
# PSCustomObject after Set-Item-style mutation.
$script:treeRows         = [System.Collections.Generic.List[object]]::new()
$script:tmuxBlock        = ''
$script:skippedBadPaths  = 0
$script:truncatedRows    = $false
$script:truncatedDepth   = $false

# Invoke-PostClassifyTree — mirror of bash post_classify_tree.
#   1. For each P-row, if any ancestor segment ends `_suite`, promote to M.
#      If additionally the immediate parent ends `_suite` AND row basename ends
#      `_hub`, promote to H instead. Spec §3.2.
#   2. For each S-row whose ancestor chain contains `_suite`, demote to F and
#      emit one stderr warning per offending path. AC-5T7.
# Idempotent: safe to call after Read-Tree in both initial fetch and refresh.
function Invoke-PostClassifyTree {
    foreach ($r in $script:treeRows) {
        if ($r.Type -ne 'P') { continue }
        $segs = $r.Path -split '/'
        $nSegs = $segs.Count
        $hasSuiteAncestor = $false
        $parentIsSuite = $false
        # Walk segs[0..nSegs-2] (every ancestor — exclude the row itself).
        for ($j = 0; $j -lt $nSegs - 1; $j++) {
            if ($segs[$j] -match '_suite$') {
                $hasSuiteAncestor = $true
                if ($j -eq $nSegs - 2) { $parentIsSuite = $true }
            }
        }
        if ($hasSuiteAncestor) {
            $rowBasename = $segs[$nSegs - 1]
            if ($parentIsSuite -and $rowBasename -match '_hub$') {
                $r.Type = 'H'
            } else {
                $r.Type = 'M'
            }
        }
    }

    # Second pass: nested-Suite demotion.
    foreach ($r in $script:treeRows) {
        if ($r.Type -ne 'S') { continue }
        $segs = $r.Path -split '/'
        $nSegs = $segs.Count
        for ($j = 0; $j -lt $nSegs - 1; $j++) {
            if ($segs[$j] -match '_suite$') {
                $r.Type = 'F'
                Write-WarnStderr "nested Suites not supported; treating $($r.Path) as Folder"
                break
            }
        }
    }
}

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

        # Wire-format invariant: every path is `.` (synthetic root) or matches
        # the allowlist regex. Drop bad rows silently and bump the counter for
        # a single deduped stderr warning. Type-validity catches TAB-in-name
        # corruption that the path regex misses. Server emits R/F/S/P; parser
        # also accepts H/M so test fixtures can inject hand-crafted rows.
        if ($tt -notmatch '^[RFSPHM]$') {
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

    Invoke-PostClassifyTree

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
#   - [..  back] for non-root frames
#   - Folders + Suites alphabetical (interleaved by basename)
#   - Projects + Hubs + Members active-then-idle alphabetical
#   - [new...] always last
# Kinds: back, folder (F or S, drillable), project (P/H/M, attachable),
# new_anything. The (root) bucket from folder-tree-v1 is dropped — top-level
# now shows Folders/Suites + Projects/Hubs/Members + [new...] flat.
function Get-RowList {
    param([string]$Path)

    $out = [System.Collections.Generic.List[object]]::new()

    if (-not [string]::IsNullOrEmpty($Path)) {
        $out.Add([PSCustomObject]@{ Line = '[..  back]'; Kind = 'back'; Payload = '' })
    }

    $matchParent = $Path

    $folderItems = [System.Collections.Generic.List[object]]::new()
    $activeItems = [System.Collections.Generic.List[object]]::new()
    $idleItems   = [System.Collections.Generic.List[object]]::new()

    foreach ($r in $script:treeRows) {
        if ($r.Path -eq '.') { continue }
        if ($r.Parent -ne $matchParent) { continue }

        $basename = if ($r.Path.Contains('/')) { $r.Path.Substring($r.Path.LastIndexOf('/') + 1) } else { $r.Path }

        switch ($r.Type) {
            'F' {
                $folderItems.Add([PSCustomObject]@{
                    Line     = "$basename/  ($($r.Children))"
                    Basename = $basename
                    Path     = $r.Path
                })
            }
            'S' {
                # Suite renders as `<name>_suite/  (N)` — `_suite` is part of
                # basename. Folders + Suites interleave alphabetically.
                $folderItems.Add([PSCustomObject]@{
                    Line     = "$basename/  ($($r.Children))"
                    Basename = $basename
                    Path     = $r.Path
                })
            }
            { $_ -in 'P', 'H', 'M' } {
                # Badge column: between basename and activity.
                $badge = switch ($r.Type) {
                    'H' { 'HUB' }
                    'M' { 'member' }
                    default { '' }
                }
                $act = Get-SessionActivity -Basename $basename
                $actCol = if ($null -ne $act) { "[active $($act.Label)]" } else { '[idle]' }
                $line = if ($badge) { "$basename  $badge  $actCol" } else { "$basename  $actCol" }

                if ($null -ne $act) {
                    $activeItems.Add([PSCustomObject]@{
                        Line     = $line
                        Basename = $basename
                        Ts       = [int64]$act.Ts
                        Path     = $r.Path
                    })
                } else {
                    $idleItems.Add([PSCustomObject]@{
                        Line     = $line
                        Basename = $basename
                        Path     = $r.Path
                    })
                }
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

    $out.Add([PSCustomObject]@{ Line = '[new...]'; Kind = 'new_anything'; Payload = '' })
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
# Re-runs the SSH fetch + parser. Used after creation so the new entry is
# visible in the next picker render. Keeps the stale tree on failure and warns
# (mirrors bash refetch_tree's `|| return 0` behavior so the picker survives a
# transient network blip after a successful initial fetch).
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

# ---- name validation + collision helpers (creation flow) ----

# Test-NameAllowlist <name> — returns $true on accept, prints stderr + returns
# $false on reject. Mirrors bash _validate_name. Empty string returns $false.
function Test-NameAllowlist {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name -notmatch $rxProj) {
        [Console]::Error.WriteLine("  '$Name' has unsupported characters. Allowed: letters, digits, '.', '_', '-'. Try again.")
        return $false
    }
    if ($Name -eq '.' -or $Name -eq '..' -or $Name.StartsWith('.')) {
        [Console]::Error.WriteLine("  '$Name' is reserved. Pick a different name.")
        return $false
    }
    return $true
}

# Test-SiblingCollision <parent> <name> — returns $true if any row at $parent
# already has basename $name (any type). Mirrors bash _check_sibling_collision.
function Test-SiblingCollision {
    param([string]$ParentPath, [string]$Name)
    foreach ($r in $script:treeRows) {
        if ($r.Parent -ne $ParentPath) { continue }
        $exb = if ($r.Path.Contains('/')) { $r.Path.Substring($r.Path.LastIndexOf('/') + 1) } else { $r.Path }
        if ($exb -eq $Name) { return $true }
    }
    return $false
}

# Get-GlobalConflict <name> — returns the conflicting full path string if any
# P/H/M row anywhere shares the basename, $null otherwise. Mirrors bash
# _check_global_unique. Folder/Suite skip this check.
function Get-GlobalConflict {
    param([string]$Name)
    foreach ($r in $script:treeRows) {
        if ($r.Type -notin @('P', 'H', 'M')) { continue }
        $exb = if ($r.Path.Contains('/')) { $r.Path.Substring($r.Path.LastIndexOf('/') + 1) } else { $r.Path }
        if ($exb -eq $Name) { return $r.Path }
    }
    return $null
}

# Invoke-WalkToSuiteRoot <drillPath> — walk segments of $drillPath looking for
# the closest-to-root segment ending `_suite`. Returns its accumulated path, or
# '' if none. Mirrors bash walk_to_suite_root.
function Invoke-WalkToSuiteRoot {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $segs = $Path -split '/'
    $acc = ''
    foreach ($seg in $segs) {
        $acc = if ($acc) { "$acc/$seg" } else { $seg }
        if ($seg -match '_suite$') { return $acc }
    }
    return ''
}

# Get-HubInfo <suiteRel> — single SSH probe at the Suite root counting `*_hub`
# direct children that have CLAUDE.md. Returns @{ Count = <int>; Path = <abs|empty> }.
# Mirrors bash detect_hub. On Multi-Hub, Path is empty (caller warns + skips).
function Get-HubInfo {
    param([string]$SuiteRel)
    $info = [PSCustomObject]@{ Count = 0; Path = '' }
    if ([string]::IsNullOrEmpty($SuiteRel)) { return $info }
    $tpl = @'
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash --norc --noprofile -c '
  cd __PROJECTS_DIR__ 2>/dev/null || exit 0
  suite="__SUITE_REL__"
  n=0; first=
  for h in "$suite"/*_hub; do
    [ -d "$h" ] && [ -f "$h/CLAUDE.md" ] || continue
    n=$((n+1))
    [ -z "$first" ] && first=$(cd "$h" 2>/dev/null && pwd -P)
  done
  printf "%s\t%s\n" "$n" "$first"
'
'@
    $cmd = $tpl.Replace('__PROJECTS_DIR__', $ProjectsDir).Replace('__SUITE_REL__', $SuiteRel)
    $out = & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $cmd 2>$null
    if ($LASTEXITCODE -ne 0 -or $null -eq $out) { return $info }
    if ($out -is [array]) { $out = $out -join "`n" }
    $line = ([string]$out).Trim()
    if ([string]::IsNullOrEmpty($line)) { return $info }
    $parts = $line -split "`t", 2
    if ($parts.Count -lt 1) { return $info }
    $cnt = 0
    [int]::TryParse($parts[0], [ref]$cnt) | Out-Null
    $info.Count = $cnt
    if ($cnt -eq 1 -and $parts.Count -ge 2) {
        $info.Path = $parts[1]
    }
    return $info
}

# Read-Description — single-line description prompt for Member creation. Empty
# input yields the placeholder string. Embedded newlines are rejected with a
# re-prompt. Mirrors bash prompt_description.
function Read-Description {
    while ($true) {
        $desc = Read-Host 'One-line description (optional)'
        if ($null -eq $desc) {
            return '<one-line description goes here>'
        }
        if ($desc.Contains("`n") -or $desc.Contains("`r")) {
            Write-WarnStderr 'description must be single-line'
            continue
        }
        if ([string]::IsNullOrEmpty($desc)) {
            return '<one-line description goes here>'
        }
        return $desc
    }
}

# ---- creation actions (per-type) ----
#
# Each action returns @{ Ok = $true|$false; Kind = 'folder'|'attach'; Name = <basename> }
# on success, or $null on failure. `Kind = 'folder'` means re-render the picker
# at the same drill level (Folder/Suite created); `Kind = 'attach'` means break
# out of the picker and tmux-attach (Project/Hub/Member created).

# Invoke-CreateFolder <parent> <name> — empty mkdir + tree refresh.
function Invoke-CreateFolder {
    param([string]$ParentPath, [string]$Name)
    $rel = if ([string]::IsNullOrEmpty($ParentPath)) { $Name } else { "$ParentPath/$Name" }
    Invoke-RemoteMkdir -Rel $rel
    Update-Tree
    return @{ Ok = $true; Kind = 'folder'; Name = $Name }
}

# Invoke-CreateSuite <parent> <prefix> — auto-suffix `_suite`, mkdir, refresh.
function Invoke-CreateSuite {
    param([string]$ParentPath, [string]$Prefix)
    $final = "${Prefix}_suite"
    $rel = if ([string]::IsNullOrEmpty($ParentPath)) { $final } else { "$ParentPath/$final" }
    Invoke-RemoteMkdir -Rel $rel
    Update-Tree
    return @{ Ok = $true; Kind = 'folder'; Name = $final }
}

# Invoke-CreateProject <parent> <name> — mkdir + 1-line CLAUDE.md, then attach.
function Invoke-CreateProject {
    param([string]$ParentPath, [string]$Name)
    $rel = if ([string]::IsNullOrEmpty($ParentPath)) { $Name } else { "$ParentPath/$Name" }
    Invoke-RemoteMkdir -Rel $rel
    Invoke-WriteMinimalClaudeMd -Rel $rel -Name $Name
    return @{ Ok = $true; Kind = 'attach'; Name = $Name }
}

# Invoke-CreateHub <parent> <prefix> — auto-suffix `_hub`, mkdir, write
# CLAUDE.md + README.md + projects.md template, then attach. The Hub is then
# attachable like any P/H/M.
function Invoke-CreateHub {
    param([string]$ParentPath, [string]$Prefix)
    $final = "${Prefix}_hub"
    $rel = if ([string]::IsNullOrEmpty($ParentPath)) { $final } else { "$ParentPath/$final" }
    Invoke-RemoteMkdir -Rel $rel
    Invoke-WriteHubScaffold -Rel $rel -HubName $final
    return @{ Ok = $true; Kind = 'attach'; Name = $final }
}

# Invoke-CreateMember <parent> <name> <suiteRoot> — full hub-aware Member
# creation. mkdir, then optionally git init + @-import CLAUDE.md + projects.md
# row when exactly one Hub exists at the Suite root. On Multi-Hub or no-Hub,
# falls back to a plain `# <name>\n` CLAUDE.md.
function Invoke-CreateMember {
    param([string]$ParentPath, [string]$Name, [string]$SuiteRoot)
    $rel = if ([string]::IsNullOrEmpty($ParentPath)) { $Name } else { "$ParentPath/$Name" }
    Invoke-RemoteMkdir -Rel $rel

    $hub = Get-HubInfo -SuiteRel $SuiteRoot
    if ($hub.Count -eq 0) {
        Invoke-WriteMinimalClaudeMd -Rel $rel -Name $Name
    } elseif ($hub.Count -ge 2) {
        $suiteAbs = "$ProjectsDir/$SuiteRoot"
        Write-WarnStderr "multiple *_hub siblings found in ${suiteAbs}; skipping hub-aware writes"
        Invoke-WriteMinimalClaudeMd -Rel $rel -Name $Name
    } else {
        $desc = Read-Description
        Invoke-HubAwareWrites -Rel $rel -Name $Name -HubAbs $hub.Path -Description $desc
    }

    return @{ Ok = $true; Kind = 'attach'; Name = $Name }
}

# ---- remote-write helpers (single SSH per call; warn-and-continue on failure) ----

# Invoke-RemoteMkdir <rel> — idempotent mkdir under projects root.
function Invoke-RemoteMkdir {
    param([string]$Rel)
    $tpl = @'
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash --norc --noprofile -c 'mkdir -p __PROJECTS_DIR__/__REL__'
'@
    $cmd = $tpl.Replace('__PROJECTS_DIR__', $ProjectsDir).Replace('__REL__', $Rel)
    & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $cmd 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-WarnStderr "mkdir failed for $Rel; continuing" }
}

# Invoke-WriteMinimalClaudeMd <rel> <name> — write `# <name>\n` to
# <projects_root>/<rel>/CLAUDE.md (skip if file exists). Idempotent.
function Invoke-WriteMinimalClaudeMd {
    param([string]$Rel, [string]$Name)
    $tpl = @'
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash --norc --noprofile -c '
  f=__PROJECTS_DIR__/__REL__/CLAUDE.md
  [ -f "$f" ] || printf "# %s\n" "__NAME__" > "$f"
'
'@
    $cmd = $tpl.Replace('__PROJECTS_DIR__', $ProjectsDir).Replace('__REL__', $Rel).Replace('__NAME__', $Name)
    & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $cmd 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-WarnStderr "write failed for $Rel/CLAUDE.md" }
}

# Invoke-WriteHubScaffold <rel> <hubName> — write Hub CLAUDE.md, README.md,
# projects.md header. Idempotent on per-file basis.
function Invoke-WriteHubScaffold {
    param([string]$Rel, [string]$HubName)
    $tpl = @'
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash --norc --noprofile -c '
  d=__PROJECTS_DIR__/__REL__
  [ -f "$d/CLAUDE.md" ]   || printf "# %s\n" "__HUB_NAME__" > "$d/CLAUDE.md"
  [ -f "$d/README.md" ]   || printf "# %s\n\nHub README.\n" "__HUB_NAME__" > "$d/README.md"
  if [ ! -f "$d/projects.md" ]; then
    {
      printf "| Name | Description | Status | Owner | Notes |\n"
      printf "|------|-------------|--------|-------|-------|\n"
    } > "$d/projects.md"
  fi
'
'@
    $cmd = $tpl.Replace('__PROJECTS_DIR__', $ProjectsDir).Replace('__REL__', $Rel).Replace('__HUB_NAME__', $HubName)
    & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $cmd 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-WarnStderr "hub scaffold write failed for $Rel" }
}

# Invoke-HubAwareWrites <rel> <name> <hubAbs> <description> — the four
# hub-aware writes for a Member. All warn-and-continue; never abort.
#   1. git init in the member directory
#   2. write CLAUDE.md with @-import to the Hub README
#   3. append a row to <hub>/projects.md (only if it exists and is non-empty)
# Pipe in description is escaped only in the projects.md row; left literal in
# CLAUDE.md body. Description is delivered via quoted bash heredoc inside the
# SSH payload to prevent expansion.
function Invoke-HubAwareWrites {
    param([string]$Rel, [string]$Name, [string]$HubAbs, [string]$Description)
    $descPipeEscaped = $Description -replace '\|', '\|'
    # Escape single quotes for safe inclusion inside the outer `bash -c '...'`
    # quoted block. Without this, a `'` in $Description closes the outer quote
    # and allows arbitrary command execution on the mini under $RemoteUser
    # (verified RCE; security review iter-1 finding). The bash idiom is to
    # close-quote, escape-quote, reopen-quote: `'` -> `'\''`.
    # The heredoc EOF marker is also quoted (`<<'CLAUDEMD_EOF'`) so remote
    # bash does not perform $() / backtick expansion inside CLAUDE.md body.
    $descSq        = $Description -replace "'", "'\''"
    $descPipeSq    = $descPipeEscaped -replace "'", "'\''"
    $tpl = @'
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash --norc --noprofile -c '
  member=__PROJECTS_DIR__/__REL__
  hub="__HUB_ABS__"
  ( cd "$member" 2>/dev/null && git init >/dev/null 2>&1 ) || true
  cat > "$member/CLAUDE.md" <<'\''CLAUDEMD_EOF'\''
# __NAME__

@__HUB_ABS__/README.md

__DESCRIPTION__
CLAUDEMD_EOF
  if [ -s "$hub/projects.md" ]; then
    printf "| %s | %s | active | — | — |\n" "__NAME__" "__DESCRIPTION_ESCAPED__" >> "$hub/projects.md"
  fi
'
'@
    $cmd = $tpl.
        Replace('__PROJECTS_DIR__', $ProjectsDir).
        Replace('__REL__', $Rel).
        Replace('__HUB_ABS__', $HubAbs).
        Replace('__NAME__', $Name).
        Replace('__DESCRIPTION_ESCAPED__', $descPipeSq).
        Replace('__DESCRIPTION__', $descSq)
    & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $cmd 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-WarnStderr "hub-aware writes failed for $Rel" }
}

# ---- Read-TypeChoice ----
# Reads a creation-type choice from stdin. Accepts substring prefix matches
# (e.g., `f` → `folder`); ambiguous prefix re-prompts. Empty input/Ctrl-D
# returns ''. Mirrors bash _read_type_choice.
function Read-TypeChoice {
    param([string[]]$ValidTypes)
    $valid = $ValidTypes -join ' '
    while ($true) {
        $answer = Read-Host "Create what? [$valid]"
        if ($null -eq $answer -or [string]::IsNullOrEmpty($answer)) { return '' }
        # Exact match wins.
        $matched = $null
        foreach ($v in $ValidTypes) {
            if ($v -eq $answer) { $matched = $v; break }
        }
        if (-not $matched) {
            $prefixHits = @($ValidTypes | Where-Object { $_.StartsWith($answer) })
            if ($prefixHits.Count -eq 1) {
                $matched = $prefixHits[0]
            } elseif ($prefixHits.Count -gt 1) {
                $matched = 'AMBIGUOUS'
            }
        }
        if (-not $matched -or $matched -eq 'AMBIGUOUS') {
            Write-WarnStderr "invalid type '$answer'; expected one of: $valid"
            continue
        }
        return $matched
    }
}

# ---- Invoke-NewAnything ----
# Single dispatch point for the [new...] picker row. See spec §3.3.
# Returns @{ Ok=$true; Kind='folder'|'attach'; Name=<basename>; Parent=<parent path> }
# on success, or $null on cancel.
function Invoke-NewAnything {
    param([string]$ParentPath)

    # 1. Determine parent type.
    $parentType = if ([string]::IsNullOrEmpty($ParentPath)) {
        'R'
    } else {
        $row = $script:treeRows | Where-Object { $_.Path -eq $ParentPath } | Select-Object -First 1
        if ($row) { $row.Type } else { '' }
    }
    if ($parentType -notin @('R', 'F', 'S')) {
        Write-WarnStderr '[new...] not available at this drill level'
        return $null
    }

    # 2. Compute valid creation types from parent type.
    # F is structurally ambiguous (plain Folder vs. sub-Folder inside a Suite);
    # walk_to_suite_root disambiguates. S is always at a Suite root; check for
    # existing Hub via Get-HubInfo.
    $suiteRoot = ''
    $validTypes = @()
    switch ($parentType) {
        'R' { $validTypes = @('folder', 'suite', 'project') }
        'F' {
            $suiteRoot = Invoke-WalkToSuiteRoot -Path $ParentPath
            if ($suiteRoot) {
                $validTypes = @('folder', 'member')
            } else {
                $validTypes = @('folder', 'project')
            }
        }
        'S' {
            $suiteRoot = $ParentPath
            $hub = Get-HubInfo -SuiteRel $suiteRoot
            if ($hub.Count -eq 0) {
                $validTypes = @('folder', 'member', 'hub')
            } else {
                $validTypes = @('folder', 'member')
            }
        }
    }

    # 3. Prompt for type.
    $type = Read-TypeChoice -ValidTypes $validTypes
    if ([string]::IsNullOrEmpty($type)) { return $null }

    # 4. Prompt for name (loop on validation errors).
    while ($true) {
        $promptText = switch ($type) {
            'folder'  { 'New folder name' }
            'project' { 'New project name' }
            'suite'   { 'New suite name (suffix _suite is auto-appended)' }
            'hub'     { 'New hub name (suffix _hub is auto-appended)' }
            'member'  { 'New member name' }
        }
        $name = Read-Host $promptText
        if ([string]::IsNullOrEmpty($name)) { return $null }

        # Suite/Hub: reject any user-typed `_suite`/`_hub` substring (suffix
        # OR interior) before auto-appending. Pwsh `-match '_suite'` matches
        # the substring anywhere — equivalent to bash glob `*_suite|*_suite_*`.
        if ($type -eq 'suite' -and $name -match '_suite') {
            Write-WarnStderr "name '_suite' substring not allowed; type just the prefix and the suffix is auto-appended."
            continue
        }
        if ($type -eq 'hub' -and $name -match '_hub') {
            Write-WarnStderr "name '_hub' substring not allowed; type just the prefix and the suffix is auto-appended."
            continue
        }

        if (-not (Test-NameAllowlist -Name $name)) {
            continue
        }

        # final_name = what actually lands on disk after auto-suffix.
        $finalName = switch ($type) {
            'suite' { "${name}_suite" }
            'hub'   { "${name}_hub" }
            default { $name }
        }

        # Sibling collision check (any type at same parent).
        if (Test-SiblingCollision -ParentPath $ParentPath -Name $finalName) {
            $where = if ([string]::IsNullOrEmpty($ParentPath)) { $finalName } else { "$ParentPath/$finalName" }
            [Console]::Error.WriteLine("  '$finalName' already exists at $where. Pick a different name.")
            continue
        }

        # Globally-unique scan for project/hub/member basenames.
        if ($type -in @('project', 'hub', 'member')) {
            $conflict = Get-GlobalConflict -Name $finalName
            if ($null -ne $conflict) {
                [Console]::Error.WriteLine("  '$finalName' already exists at $conflict. Pick a different name.")
                continue
            }
        }

        # 5. Dispatch to type-specific creator.
        $result = switch ($type) {
            'folder'  { Invoke-CreateFolder  -ParentPath $ParentPath -Name $finalName }
            'suite'   { Invoke-CreateSuite   -ParentPath $ParentPath -Prefix $name }
            'project' { Invoke-CreateProject -ParentPath $ParentPath -Name $finalName }
            'hub'     { Invoke-CreateHub     -ParentPath $ParentPath -Prefix $name }
            'member'  { Invoke-CreateMember  -ParentPath $ParentPath -Name $finalName -SuiteRoot $suiteRoot }
        }
        if ($null -ne $result -and $result.Ok) {
            $result.Parent = $ParentPath
            return $result
        }
        return $null
    }
}

# ---- Invoke-PickerLoop ----
# Recursive drill loop. Returns @{ Action='attach'; Project=<basename>;
# Parent=<parent path or ''> } on a project pick, or $null on cancel/back/exit.
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
            'project'      {
                $parent =
                    if ($row.Payload.Contains('/')) { $row.Payload.Substring(0, $row.Payload.LastIndexOf('/')) }
                    else                            { '' }
                $basename = if ($row.Payload.Contains('/')) { $row.Payload.Substring($row.Payload.LastIndexOf('/') + 1) } else { $row.Payload }
                return @{ Action = 'attach'; Project = $basename; Parent = $parent }
            }
            'new_anything' {
                $r = Invoke-NewAnything -ParentPath $Path
                if ($null -ne $r -and $r.Ok) {
                    if ($r.Kind -eq 'attach') {
                        return @{ Action = 'attach'; Project = $r.Name; Parent = $r.Parent }
                    }
                    # Folder/Suite: tree was refetched; loop re-renders this level.
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
    Invoke-Die "claudehome: project directory '$project' has characters that cannot be safely passed to SSH.`n  Rename it on $HostName to use only letters, digits, '.', '_', '-'."
}
if (-not [string]::IsNullOrEmpty($attachPath) -and $attachPath -notmatch $rxTreePath) {
    Invoke-Die "claudehome: parent path '$attachPath' has characters that cannot be safely passed to SSH."
}

# ---- attach (or create) tmux session ----
# Session name is `claudehome-<basename>` regardless of folder depth — the
# folder is invisible at the tmux layer (AC-FT-PC3, spec line 134-136).
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
