# claudehome PC (PowerShell 7) v1 Implementation Plan

**Spec:** `.omc/specs/deep-interview-claudehome-pc-v1.md`
**Parent spec:** `.omc/specs/deep-interview-claudehome-v1.md`
**Parent plan:** `.omc/plans/claudehome-v1-plan.md`
**Date:** 2026-04-24
**Mode:** RALPLAN-DR (SHORT) — brownfield mechanical port, strict parity pledge
**Target runtime:** Windows 10/11 + PowerShell 7+ (`pwsh.exe`)

---

## 1. RALPLAN-DR Summary

### Principles

1. **Strict behavioral parity with bash.** Every AC1–AC12 passes identically on the PC client. Internal deviation is only permitted where a PS idiom demands it, never for cosmetic preference.
2. **Mechanical port, not rewrite.** Section-for-section mirror of `bin/claudehome`. Same env vars, same allowlists, same SSH payload, same picker row format.
3. **Single SSH round-trip for data fetch, single SSH for attach.** The bash design is already optimal; do not redesign.
4. **Graceful degradation.** fzf preferred, `Read-Host` numbered menu always works. Missing Mac mini = clear error, never hang.
5. **Injection-safe by allowlist.** Values that reach the remote `bash -c '...'` string are constrained by strict regex *before* interpolation; the PS string-building path cannot introduce new attack surface.

### Decision Drivers (top 3)

1. **Parity pledge.** Spec mandates strict AC1–AC12 parity + AC-PC1..AC-PC8. Every decision must preserve byte-identical remote behavior.
2. **Injection safety across two quoting layers.** PowerShell's `$`-interpolation plus bash's `'...'` quoting creates two layers that must not interact. The allowlist must run *before* any string interpolation.
3. **Zero-config ergonomics.** The user installs with `.\install.ps1` and types `claudehome`. No profile edits, no `Set-ExecutionPolicy`, no administrator prompt.

### Choice Points & Viable Options

#### CP1: How to build the remote SSH payload safely

| Option | Pros | Cons |
|--------|------|------|
| **A: Single-quoted PS literal for the bash payload template, splice validated vars via `-f` or `"…$var…"` after validation** | `$` inside the bash payload (e.g. `$SHELL`) stays literal. Validated vars are guaranteed injection-free by the regex. One argument passed to `ssh.exe`. | Requires discipline: two separate steps (literal template + splice) and careful use of format operator. |
| B: Double-quoted PS string with backtick-escaped `` `$SHELL `` | One-liner, looks like the bash source. | Any accidentally un-escaped `$` expands silently. Easy to regress when editing. High review burden. |
| C: Here-string (`@'…'@`) literal, then `.Replace()` placeholders | Zero interpolation surprises. Very explicit. | More verbose. `.Replace()` chains are harder to read than formatted strings. |

**Chosen: A.** Best tradeoff between readability and safety. Validation happens *before* interpolation, so by construction the only characters that reach the remote shell are `[a-zA-Z0-9._~/-]`. Use `"bash --norc --noprofile -c '$payload'"` style only after the payload has been assembled from a single-quoted literal with validated splices.

#### CP2: Picker fallback implementation

| Option | Pros | Cons |
|--------|------|------|
| **A: `Read-Host` numbered menu (manual `for` loop)** | Zero dependencies. Matches bash `select` semantics. Works in any pwsh 7 host. Mentioned explicitly in spec. | Slightly more code than `Out-ConsoleGridView`. |
| B: `Out-ConsoleGridView` (Microsoft.PowerShell.ConsoleGuiTools) | Nicer UX. | Optional module, not installed by default. Spec explicitly rules it out. |
| C: `Out-GridView` (WinForms) | Built-in on Windows PowerShell. | Not in pwsh 7 by default on all hosts; GUI popup violates TUI parity. Spec rules it out. |

**Chosen: A.** Spec-mandated. Implementation is ~10 lines of pwsh.

#### CP3: Invoking `ssh.exe` — direct call vs `Start-Process` vs `Invoke-Expression`

| Option | Pros | Cons |
|--------|------|------|
| **A: Direct call `ssh.exe arg1 arg2 …`** | Standard PS pattern. Argument array handled correctly. `$LASTEXITCODE` reflects ssh's exit. Stdin/stdout inherit from pwsh host → TTY works for `ssh -t`. | None for our use case. |
| B: `Start-Process ssh.exe -Wait` | Explicit process object. | Breaks TTY inheritance; `ssh -t` cannot draw a full-screen tmux UI through a `Start-Process` redirection. Disqualifier. |
| C: `Invoke-Expression` on a constructed string | Looks like bash `eval`. | Double-parses the string — introduces a second injection surface. Spec explicitly forbids. |

**Chosen: A.** Forbidden in spec: B and C. Direct call preserves the inherited TTY, which is required for AC-PC6, AC-PC7, AC3, AC4, AC6.

#### CP4: Idempotent PATH update in `install.ps1`

| Option | Pros | Cons |
|--------|------|------|
| **A: Read User PATH, split on `;`, append `<repo>\bin` if absent, write back via `[Environment]::SetEnvironmentVariable(..., 'User')`** | Same mental model as bash `install.sh`. Per-user scope; no admin needed. | Changes only take effect in *new* pwsh sessions — must print a reminder. |
| B: Modify `$PROFILE` to `$env:PATH += …` | Takes effect in next pwsh session without logoff. | Pollutes user profile. Doesn't help `cmd.exe` users (AC-PC8 would fail). |
| C: Create a symlink in a directory already on PATH (e.g. `%USERPROFILE%\bin`) | Mirrors bash `~/.local/bin` flow. | That directory is not on the default Windows PATH; creating and adding it is the same work as option A. Symlinks on Windows require either Dev Mode or admin — extra preconditions. |

**Chosen: A.** Cleanest mirror of bash `install.sh` semantics, one persisted PATH change, works for cmd.exe and pwsh alike, no admin required. Combined with the `.cmd` shim (CP5), this satisfies AC-PC1 and AC-PC8.

#### CP5: `.cmd` shim contents

| Option | Pros | Cons |
|--------|------|------|
| **A: `@pwsh -NoProfile -File "%~dp0claudehome.ps1" %*`** | Spec-mandated exact form. `-NoProfile` avoids profile noise. `-File` sidesteps ExecutionPolicy for `.ps1` invoked via `pwsh.exe`. `%~dp0` anchors to the shim's own dir (relocatable). `%*` forwards all args. | None. |
| B: `@pwsh -NoProfile -Command "& '%~dp0claudehome.ps1' %*"` | Slightly more flexible arg handling. | Re-parses args through PS parser → extra quoting surface. `-File` is the canonical form. |

**Chosen: A.** Exact string mandated by spec:
```
@pwsh -NoProfile -File "%~dp0claudehome.ps1" %*
```

---

## 2. Implementation Plan

### Deliverable 1: `bin/claudehome.ps1` (~150 lines)

#### Section 1 — Preamble (lines ~1–10)

```powershell
#Requires -Version 7.0
# claudehome.ps1 — PowerShell 7+ port of bin/claudehome.
# Strict parity with bash; see .omc/specs/deep-interview-claudehome-pc-v1.md.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'   # ensures consistent arg-passing on pwsh 7.0–7.6
$PSNativeCommandUseErrorActionPreference = $false  # prevents non-zero exit from native commands triggering $ErrorActionPreference = 'Stop'
```

**Satisfies:** AC-PC1 preconditions (runtime gate), baseline error hygiene.

#### Section 2 — Help (lines ~11–35)

```powershell
if ($args.Count -ge 1 -and $args[0] -in @('-h','--help')) {
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
```

Notes: single-quoted here-string (`@'...'@`) keeps `$env:USERNAME` and `$env:CLAUDEHOME_*` literal in the help text — identical to bash `<<'USAGE'`. Closing `'@` at column 0.

**Satisfies:** AC-PC2 (help text parity), part of AC1.

#### Section 3 — Config resolution (lines ~36–42)

```powershell
$HostName    = if ($env:CLAUDEHOME_HOST)          { $env:CLAUDEHOME_HOST }          else { 'gene-mini' }
$RemoteUser  = if ($env:CLAUDEHOME_USER)          { $env:CLAUDEHOME_USER }          else { $env:USERNAME }
$ProjectsDir = if ($env:CLAUDEHOME_PROJECTS_DIR)  { $env:CLAUDEHOME_PROJECTS_DIR }  else { '~/projects/claudecode' }
```

Avoid `$Host` (automatic variable conflict) — use `$HostName`. `??` is tempting but `if/else` reads identically to the bash `${VAR:-default}` and is unambiguous under StrictMode for unset env vars.

**Satisfies:** AC-PC3 (env var overrides), AC9.

#### Section 4 — Validate config (lines ~43–60)

```powershell
$rxHost  = '^[a-zA-Z0-9._-]+$'
$rxUser  = '^[a-zA-Z0-9._-]+$'
$rxPath  = '^[a-zA-Z0-9._~/-]+$'
$rxProj  = '^[a-zA-Z0-9._-]+$'

if ($HostName    -notmatch $rxHost) { Write-Error "claudehome: CLAUDEHOME_HOST='$HostName' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '-'"; exit 1 }
if ($RemoteUser  -notmatch $rxUser) { Write-Error "claudehome: CLAUDEHOME_USER='$RemoteUser' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '-'"; exit 1 }
if ($ProjectsDir -notmatch $rxPath) { Write-Error "claudehome: CLAUDEHOME_PROJECTS_DIR='$ProjectsDir' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '/', '~', '-'"; exit 1 }
```

Note: `Write-Error` with `$ErrorActionPreference = 'Stop'` throws. To preserve the bash "stderr message + exit 1" flavor without a stack trace, use `[Console]::Error.WriteLine(...)` + `exit 1` instead (cleaner output, matches AC-PC4 expectation). Final form:

```powershell
function Die([string]$msg) { [Console]::Error.WriteLine($msg); exit 1 }
if ($HostName -notmatch $rxHost) { Die "claudehome: CLAUDEHOME_HOST='$HostName' has unsupported characters.`n  Allowed: letters, digits, '.', '_', '-'" }
# ... same for user, projects dir
```

**Satisfies:** AC-PC4 (injection guards), part of AC9.

#### Section 5 — Fetch picker data (single SSH round-trip) (lines ~61–85)

Build the remote bash payload with zero PS `$` expansion, splice only the validated `$ProjectsDir`:

**Note (Arch-R1):** The `-f` format operator throws `FormatException` on `#{session_name}` because .NET treats `{word}` as an unresolvable placeholder. Use a single-quoted here-string with a named sentinel token and `.Replace()` instead:

```powershell
$remoteDataTpl = @'
bash --norc --noprofile -c '
  ls -1 __PROJECTS_DIR__ 2>/dev/null || true
  echo ---TMUX---
  tmux list-sessions -F "#{session_name} #{session_activity}" 2>/dev/null || true
'
'@
$remoteDataCmd = $remoteDataTpl.Replace('__PROJECTS_DIR__', $ProjectsDir)

# Invoke ssh.exe directly. Capture stdout; discard stderr to /dev/null equivalent.
$raw = & ssh.exe -o BatchMode=yes -o ConnectTimeout=5 "$RemoteUser@$HostName" $remoteDataCmd 2>$null
if ($LASTEXITCODE -ne 0) {
    Die @"
claudehome: cannot reach $RemoteUser@$HostName over SSH.
  - Check Tailscale is up on both devices:   tailscale status
  - Check Mac mini Remote Login is enabled:  System Settings > General > Sharing
  - Check your SSH key is authorized on the Mac mini.
"@
}
```

Key points:
- `& ssh.exe …` — direct native invocation (CP3-A), not `Invoke-Expression`.
- `$LASTEXITCODE` branch (CP3 rationale), not `$?`.
- `2>$null` drops ssh's stderr banner on success/failure; the `Die` message replaces it.
- `$raw` is a string or array of strings depending on host — use `-join "`n"` downstream if needed.

**Satisfies:** part of AC1, AC2, AC-PC4 (no injection — `$ProjectsDir` is allowlist-validated), AC10 (no server state).

#### Section 6 — Parse + build picker rows (lines ~86–120)

```powershell
# Normalize to a single string with LF separators to mirror bash here-string behavior.
if ($raw -is [array]) { $raw = ($raw -join "`n") }
$raw = [string]$raw

# Split on sentinel; first occurrence wins.
$sentinel = "`n---TMUX---`n"
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
    if ($parts.Count -eq 2) { $sessions[$parts[0]] = [int64]$parts[1] }
}

# Build picker rows parallel to project names.
$pickerLines = New-Object System.Collections.Generic.List[string]
$pickerNames = New-Object System.Collections.Generic.List[string]
$now = [int64][double]::Parse(((Get-Date -UFormat %s)))  # pwsh7: [DateTimeOffset]::Now.ToUnixTimeSeconds() is cleaner

foreach ($project in ($projectsBlock -split "`r?`n")) {
    $project = $project.Trim()
    if ([string]::IsNullOrEmpty($project)) { continue }
    $sname = "claudehome-$project"
    if ($sessions.ContainsKey($sname)) {
        $age = [int64]($now - $sessions[$sname])
        if ($age -lt 0) { $age = 0 }
        $label = if     ($age -lt 60)    { "${age}s ago" }
                 elseif ($age -lt 3600)  { "$([int]($age/60))m ago" }
                 elseif ($age -lt 86400) { "$([int]($age/3600))h ago" }
                 else                    { "$([int]($age/86400))d ago" }
        $pickerLines.Add("$project  [active $label]")
    } else {
        $pickerLines.Add("$project  [idle]")
    }
    $pickerNames.Add($project)
}

if ($pickerNames.Count -eq 0) {
    Die @"
claudehome: no projects found in $ProjectsDir on $HostName.
  Create one with: ssh $RemoteUser@$HostName 'mkdir -p $ProjectsDir/my-project'
"@
}
```

Prefer `[DateTimeOffset]::Now.ToUnixTimeSeconds()` for `$now` — no locale/culture pitfalls. Row format uses **two spaces** before `[` to match bash exactly (so `"$project  [..."` where it's literally two spaces).

**Satisfies:** AC2 (row format), AC1 (listing), part of AC-PC5.

#### Section 7 — Picker (fzf or Read-Host numbered menu) (lines ~121–150)

```powershell
# Prefer fzf.exe if on PATH; otherwise Read-Host numbered menu (bash `select` equivalent).
$fzf = Get-Command fzf.exe -ErrorAction SilentlyContinue
if ($fzf) {
    $selected = ($pickerLines -join "`n") | & fzf.exe --prompt='claudehome> ' --height=~50%
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($selected)) { exit 0 }  # Ctrl-C / Esc
} else {
    for ($i = 0; $i -lt $pickerLines.Count; $i++) {
        Write-Host ("{0,3}) {1}" -f ($i + 1), $pickerLines[$i])
    }
    while ($true) {
        $answer = Read-Host 'Select a project'
        if ([string]::IsNullOrEmpty($answer)) { exit 0 }   # EOF / Ctrl-C — bash `select` exits on EOF
        if ($answer -match '^\d+$') {
            $n = [int]$answer
            if ($n -ge 1 -and $n -le $pickerLines.Count) {
                $selected = $pickerLines[$n - 1]
                break
            }
        }
        # Invalid: bash `select` re-prompts. Mirror that.
    }
}

# Extract project name (everything before the double-space annotation).
$project = ($selected -split '  ', 2)[0]

# Revalidate the project name against the same allowlist.
if ($project -notmatch $rxProj) {
    Die @"
claudehome: project directory '$project' has characters that cannot be safely passed to SSH.
  Rename it on $HostName to use only letters, digits, '.', '_', '-'.
"@
}
```

**Satisfies:** AC-PC5 (picker fallback parity), AC12, AC-PC4 (post-pick revalidation).

#### Section 8 — Attach via tmux (lines ~151–170)

```powershell
# Build attach payload with a SINGLE-QUOTED here-string so $SHELL stays literal for remote bash.
# Validated variables are spliced via -f (format operator):
#   {0} = $project  (first positional arg — do not reorder)
#   {1} = $ProjectsDir  (second positional arg — do not reorder)
$attachTpl = @'
bash --norc --noprofile -c '
  tmux new-session -A -D -s claudehome-{0} -c {1}/{0} "claude; exec $SHELL"
'
'@
$attachCmd = $attachTpl -f $project, $ProjectsDir

# Direct ssh.exe call with -t for TTY allocation. pwsh has no exec; when ssh -t exits,
# control returns to pwsh — functionally equivalent (no orphan processes).
& ssh.exe -t "$RemoteUser@$HostName" $attachCmd
exit $LASTEXITCODE
```

Key points:
- `@'…'@` single-quoted here-string → `$SHELL` stays literal, reaches the remote `bash -c '...'` and is expanded there. Identical to bash `exec $SHELL` inside the escaped double-quotes.
- `-A -D` both present in the remote tmux invocation (AC-PC6).
- `-t` for TTY (AC-PC7; needed for claude's ANSI/spinner).
- No `Invoke-Expression`, no `Start-Process` — direct native call (CP3-A).
- Exit code propagated.

**Satisfies:** AC3, AC4, AC5, AC6, AC7, AC8, AC10, AC11, AC-PC6, AC-PC7.

#### Accepted PS-idiom deviations from bash

1. **No `exec ssh` equivalent.** `& ssh.exe -t …` + `exit $LASTEXITCODE` is the accepted PS analog. Side effect: pwsh remains the parent process until ssh exits, but no orphan process is left behind.
2. **`Read-Host` loop has no built-in EOF/Ctrl-D exit.** Ctrl-C is the expected exit path. This matches bash `select`'s Ctrl-D semantics well enough for v1.
3. **`Set-StrictMode -Version 3.0` + `$ErrorActionPreference = 'Stop'` approximates `set -euo pipefail`** but does not cover mid-pipeline failures in the same way. Mitigated by `$PSNativeCommandUseErrorActionPreference = $false` for native-command blocks (see Section 1 preamble).

---

### Deliverable 2: `bin/claudehome.cmd` (1 line + header)

```cmd
@REM claudehome shim — invokes the PowerShell 7 script from cmd.exe or pwsh.
@pwsh -NoProfile -File "%~dp0claudehome.ps1" %*
```

**Satisfies:** AC-PC1 (bare-name invocation works), AC-PC8 (cmd.exe shim).

---

### Deliverable 3: `install.ps1` (~40 lines)

```powershell
#Requires -Version 7.0
# install.ps1 — install claudehome PC client for the current user.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$binDir   = Join-Path $repoRoot 'bin'
$ps1Path  = Join-Path $binDir 'claudehome.ps1'
$cmdPath  = Join-Path $binDir 'claudehome.cmd'

# 1. Sanity: script files must exist in bin/.
if (-not (Test-Path -LiteralPath $ps1Path)) { [Console]::Error.WriteLine("install.ps1: $ps1Path not found."); exit 1 }

# 2. Drop / verify the .cmd shim (idempotent).
$shimBody = '@pwsh -NoProfile -File "%~dp0claudehome.ps1" %*'
if (Test-Path -LiteralPath $cmdPath) {
    $existing = (Get-Content -LiteralPath $cmdPath -Raw).Trim()
    if ($existing -notlike '*pwsh*claudehome.ps1*') {
        [Console]::Error.WriteLine("install.ps1: $cmdPath exists but isn't our shim. Refusing to overwrite.")
        exit 1
    }
} else {
    Set-Content -LiteralPath $cmdPath -Value $shimBody -Encoding ASCII
}

# 3. Add <repo>\bin to the current user's PATH (idempotent).
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$entries  = if ($userPath) { $userPath -split ';' } else { @() }
if ($entries -notcontains $binDir) {
    $newPath = if ([string]::IsNullOrEmpty($userPath)) { $binDir } else { "$userPath;$binDir" }
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Write-Host "Added $binDir to your user PATH."
    Write-Host "Open a NEW pwsh (or cmd.exe) session for the change to take effect."
} else {
    Write-Host "$binDir already in user PATH; nothing to do."
}

# 4. Smoke test: claudehome.cmd --help from the current process (uses the live .ps1).
$smokeProc = & $cmdPath --help 2>&1
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("install.ps1: smoke test failed. Output:`n$smokeProc")
    exit 1
}

Write-Host ''
Write-Host 'claudehome installed. In a NEW shell session, run: claudehome'
```

Notes:
- `Set-Content -Encoding ASCII` avoids BOM (cmd.exe is fussy about BOM on `.cmd` files).
- PATH update uses `[Environment]::SetEnvironmentVariable(..., 'User')` per spec. No `$PROFILE` mutation. No admin.
- `-notcontains $binDir` is case-sensitive; Windows PATH is case-insensitive. For maximum idempotency, compare with `-ieq` in a Where-Object:

```powershell
if (-not ($entries | Where-Object { $_ -ieq $binDir })) { ... }
```

Use that form in the final implementation.

- TOCTOU parity with bash: we check-then-write. Acceptable per spec.

**Satisfies:** AC-PC1, part of AC-PC8 (shim in place).

---

### Deliverable 4: `README.md` — replace "PC — Windows (not yet)" section

Replace lines 139–148 (current placeholder) with a real setup block mirroring the Mac client section. Outline:

1. **Prerequisites (Windows client, do once)**
   - pwsh 7+: `winget install Microsoft.PowerShell` (or existing install)
   - Tailscale: same tailnet as the mini (`winget install tailscale.tailscale`)
   - Windows OpenSSH client (pre-installed on Win10 1803+; confirm with `where.exe ssh`)
   - fzf (optional, recommended): `winget install junegunn.fzf` or `scoop install fzf`
2. **Install the CLI**
   ```powershell
   git clone git@github.com:sr-gene/claudehome.git $HOME\projects\claudehome
   Set-Location $HOME\projects\claudehome
   .\install.ps1
   ```
   Open a **new** pwsh window, then `claudehome`.
3. **If your Windows username differs from your mini account**
   ```powershell
   [Environment]::SetEnvironmentVariable('CLAUDEHOME_USER', 'genehan', 'User')
   ```
   Same for `CLAUDEHOME_HOST` if the mini's Tailscale name isn't `gene-mini`.
4. **ExecutionPolicy / MOTW note.** `git clone` does not apply MOTW, so `RemoteSigned` is fine. If you downloaded a ZIP, run `Unblock-File .\install.ps1` before executing.
5. **Terminal tip.** Use WezTerm, Windows Terminal, or Alacritty. Legacy cmd.exe / classic PowerShell host render poorly — use the shim from `cmd.exe` only to confirm it works, not for daily use.
6. **One-line cross-link:** `cmd.exe` users can also type `claudehome` once the shim is on PATH (AC-PC8).

Troubleshooting section (extension of the existing Mac troubleshooting):
- `claudehome: cannot reach gene-mini over SSH` — run `ssh gene-mini echo ok` in pwsh; if it prompts for a password, you need to authorize your key (see Mac mini setup).
- `claudehome not recognized` — open a **new** pwsh session; PATH changes don't apply to the current one.
- Picker falls back to numbered menu even with fzf installed — verify `Get-Command fzf.exe` resolves.

### Deliverable 5: `CLAUDE.md` — one-line update

Update the development section to add PS client alongside the bash client:

**Before:** `- **Main script:** \`bin/claudehome\` (bash, ~80 lines).`
**After:**
```
- **Main script (Mac):** `bin/claudehome` (bash, ~150 lines).
- **Main script (Windows):** `bin/claudehome.ps1` (pwsh 7+, ~150 lines), plus `bin/claudehome.cmd` shim.
- **Installer:** `install.sh` (Mac) / `install.ps1` (Windows).
- **Lint:** `shellcheck bin/claudehome install.sh`; `Invoke-ScriptAnalyzer bin/claudehome.ps1 install.ps1`.
```

Also remove / update the "Resuming on a Windows PC" block since the PC client now exists — replace it with a pointer to the README PC section.

---

## 3. Acceptance Criteria Map

### Inherited AC1–AC12 (mapped to PC plan sections)

| AC | Description | PC Plan Section | Verification Type |
|----|-------------|-----------------|-------------------|
| AC1 | Picker lists every project subdir | Sections 5–7 | requires-mac-mini |
| AC2 | Rows show name + state + last-activity | Section 6 (two-space separator, `[active …]` / `[idle]`) | requires-mac-mini |
| AC3 | No-session select creates tmux + launches claude + attaches | Section 8 (`tmux new-session -A -D`) | requires-mac-mini |
| AC4 | Existing-session select attaches; live output resumes | Section 8 | requires-mac-mini |
| AC5 | Close lid: tmux + claude persist | Section 8 (inherent tmux behavior) | requires-mac-mini |
| AC6 | Re-attach after disconnect: scrollback intact | Section 8 (inherent tmux behavior) | requires-mac-mini |
| AC7 | `/exit` drops to shell, not session kill | Section 8 (`claude; exec $SHELL` — literal `$SHELL` via single-quoted here-string) | requires-mac-mini |
| AC8 | Two concurrent sessions don't interfere | Section 8 (unique session names) | requires-mac-mini |
| AC9 | Env var overrides work | Section 3 | local-runnable |
| AC10 | No daemon/config/state on Mac mini | Architecture (no server-side component) | static |
| AC11 | Standard tmux keybindings, no wrapper | Section 8 (`exec ssh -t … tmux new-session …` with no intermediary) | static |
| AC12 | fzf picker + select-equivalent fallback | Section 7 | local-runnable |

### PC-specific AC-PC1–AC-PC8

| AC | Description | PC Plan Section | Verification Type |
|----|-------------|-----------------|-------------------|
| AC-PC1 | `.\install.ps1` → new pwsh → bare `claudehome` works | Deliverable 3 (install.ps1) + Deliverable 2 (shim) | requires-windows-host |
| AC-PC2 | `--help`/`-h` parity with bash | Section 2 (single-quoted here-string) | local-runnable |
| AC-PC3 | `$env:CLAUDEHOME_*` overrides and User-scope env vars take effect | Section 3 | local-runnable + requires-windows-host |
| AC-PC4 | Injection guards (evil host, quoted dir, spaced user, bad project) | Sections 4 & 7 (allowlists applied *before* interpolation) | local-runnable |
| AC-PC5 | fzf on PATH → fzf picker; no fzf → Read-Host numbered menu | Section 7 | local-runnable |
| AC-PC6 | `-A -D` semantics: attach from PC forcibly detaches MacBook | Section 8 (both flags present after PS quoting) | requires-mac-mini |
| AC-PC7 | Claude renders correctly in WezTerm (ANSI, spinner, status line) | Section 8 (`ssh -t` direct native call, no Start-Process) | requires-mac-mini |
| AC-PC8 | `claudehome` from cmd.exe launches via `.cmd` shim | Deliverable 2 + Deliverable 3 (PATH) | requires-windows-host |

---

## 4. Test / Verification Plan

### Phase 1 — Static verification (no Windows host, no Mac mini needed)

1. **PSScriptAnalyzer** — `Invoke-ScriptAnalyzer -Path bin/claudehome.ps1, install.ps1 -Severity Warning,Error`. Zero warnings/errors.
2. **Syntax check** — `pwsh -NoProfile -Command "Get-Command -Syntax bin/claudehome.ps1"` (or parse via AST): script parses.
3. **`--help` text parity** — diff the help text block in `bin/claudehome.ps1` against `bin/claudehome` lines 9–28. Only expected delta: `$USER` → `$env:USERNAME` and the tilde-quoting one-liner uses PS syntax.
4. **AC10 / AC11 code review** — grep for forbidden patterns: `Invoke-Expression`, `iex`, `Start-Process.*ssh`, `@"…$SHELL…"@` (double-quoted here-string containing `$SHELL`). None may appear.
5. **Allowlist-before-splice review** — confirm every use of `$HostName`, `$RemoteUser`, `$ProjectsDir`, `$project` inside an ssh argument or `-f` splice is preceded in control flow by a `-notmatch` regex guard.

### Phase 2 — Local-runnable (Windows host, no Mac mini needed)

6. **AC-PC2** — `pwsh -File bin/claudehome.ps1 --help` and `... -h`; diff against bash `bin/claudehome --help`. Same env var table, same tilde caveat.
7. **AC-PC4** —
   - `$env:CLAUDEHOME_HOST='evil;rm'; .\bin\claudehome.ps1` → exit 1, "unsupported characters" message.
   - `$env:CLAUDEHOME_PROJECTS_DIR="foo'bar"; .\bin\claudehome.ps1` → exit 1.
   - `$env:CLAUDEHOME_USER='bad user'; .\bin\claudehome.ps1` → exit 1 (space rejected).
   - Clear the vars; confirm default-path case still fails only because no Mac mini is reachable.
   - **Default-config validation (Critic-C1):** unset all `CLAUDEHOME_*` env vars (`Remove-Item Env:CLAUDEHOME_HOST, Env:CLAUDEHOME_USER, Env:CLAUDEHOME_PROJECTS_DIR -ErrorAction SilentlyContinue`) and run `.\bin\claudehome.ps1`; confirm the error is SSH-reach-failure ("cannot reach gene-mini over SSH"), NOT "unsupported characters". This verifies the default values `gene-mini`, `$env:USERNAME`, and `~/projects/claudecode` all pass the allowlist.
8. **AC-PC5 (fallback)** —

   Phase 2 Step 8 — AC-PC5 picker fallback mock:
   1. Create `$env:TEMP\mock-ssh\` directory.
   2. Write a file named `ssh.cmd` (a `.cmd` stub) that echoes the canned payload:
      - Contents: `@echo foo && echo ---TMUX--- && echo claudehome-foo 1714000000`
   3. Prepend `$env:TEMP\mock-ssh` to `$env:PATH` so it shadows the real `ssh.exe`.
   4. Run `.\bin\claudehome.ps1` — with `fzf.exe` on PATH, fzf should appear with one row: `foo  [active Xh ago]`.
   5. Temporarily rename/remove `fzf.exe` from PATH; re-run — `Read-Host` numbered menu should appear with same row.
   6. Restore PATH when done.
9. **AC-PC3 (env vars)** — set `[Environment]::SetEnvironmentVariable('CLAUDEHOME_HOST','alt-host','User')`; open new pwsh; `.\bin\claudehome.ps1` error message must reference `alt-host`.
10. **install.ps1 dry-run** — clone repo to a temp dir, run `.\install.ps1`, verify:
    - `bin\claudehome.cmd` created.
    - User PATH contains `<tempRepo>\bin` (via `[Environment]::GetEnvironmentVariable('PATH','User')`).
    - Re-running `.\install.ps1` prints "already in user PATH" and does not duplicate.
    - Smoke test passes (`--help` output printed).
11. **AC-PC8** — from `cmd.exe` in a **new** shell, type `claudehome --help`. Usage prints.

### Phase 3 — Mac-mini integration (requires real Tailscale + Mac mini + Windows host)

Deferred to the user. Produce a checklist in the handoff:

12. **AC-PC1** — fresh PC, clone + `.\install.ps1`, new pwsh, `claudehome` picks projects and attaches.
13. **AC-PC6** — attach to `hello` from MacBook. From PC, pick `hello`. MacBook detaches cleanly; PC takes over. Verifies `-D` present.
14. **AC-PC7** — in the attached claude session on PC/WezTerm, confirm ANSI colors, spinner animations, and the status line all render.
15. **AC1–AC8** — repeat Mac-mini ACs 1–8 from `bin/claudehome` verified steps, now triggered from pwsh on the PC.

### Phase ordering
Static (5 min) → Local-runnable (15 min) → Mac mini integration (20 min). Total ~40 minutes when a Windows host + Mac mini are both reachable.

---

## 5. ADRs

### ADR-PC-1: Allowlist-before-interpolation as the sole injection defense

**Decision.** All four interpolated values (`$HostName`, `$RemoteUser`, `$ProjectsDir`, `$project`) are validated against strict regex allowlists *before* any string interpolation or splice. No additional quoting or escaping is performed.

**Drivers.**
1. Mirror the bash client's defense — parity pledge.
2. Minimize cognitive load: one guard (regex) instead of two (regex + escape).
3. Two quoting layers (PS outer, bash inner) would otherwise require either double-escaping or a metaprogrammed serializer; allowlist trivially makes both layers safe because the surviving character set is a strict subset of both shells' literal-safe set.

**Alternatives considered.**
1. **Use `[System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent` + bash `printf %q` serializers.** Rejected — more code, not needed, diverges from bash.
2. **Use `ssh -o SendEnv=…` to pass variables out-of-band.** Rejected — Mac mini's `sshd_config` would need `AcceptEnv` — introduces a server-side change. Violates "no server-side changes" constraint.
3. **Pass values as ssh arguments directly (no remote `bash -c`).** Rejected — the data-fetch command is multi-line, and we must run under `bash --norc --noprofile` to shed profile noise (Revision 1 from parent plan).

**Why chosen.** Zero new attack surface relative to bash. The allowlist character set `[a-zA-Z0-9._~/-]` is fully literal in both POSIX sh single-quote and PS double/single-quote contexts.

**Consequences.** A project named `my project` or `foo'bar` on the Mac mini is rejected with a clear message. Documented in README (inherited from bash version).

**Follow-ups.** If any user reports their project directory needs special characters (spaces, Unicode), that becomes a v2 conversation with a real escape strategy — not a v1 scope expansion.

### ADR-PC-2: Single-quoted here-string templates + `-f` splice for remote payload

**Decision.** Build the two remote payloads (data-fetch and attach) as single-quoted here-strings (`@'…'@`) and splice validated values via the `-f` format operator. Do not use double-quoted strings for any string that contains a bash `$VAR` reference.

**Drivers.**
1. The attach payload must contain a literal `$SHELL` for the remote bash to expand.
2. PS double-quoted strings silently interpolate `$SHELL` → empty string, silently breaking AC7 with no diagnostic.
3. Code review burden: a single-quoted here-string is unambiguously literal; reviewers don't need to audit every `$` in the template.

**Alternatives.** Double-quoted with backtick-escaped `` `$SHELL `` — rejected as fragile (one missed backtick breaks silently).

**Consequences.** Slight verbosity; requires `-f` placeholders. Worth it for safety.

**Follow-ups.** None.

### ADR-PC-3: Direct native `ssh.exe` invocation (no `Start-Process`, no `Invoke-Expression`)

**Decision.** Call `& ssh.exe arg1 arg2 …` directly. Branch on `$LASTEXITCODE`, not `$?`.

**Drivers.**
1. `ssh -t` requires TTY inheritance; `Start-Process` by default redirects/detaches stdin — breaks tmux redraw (AC-PC7).
2. `Invoke-Expression` introduces a second injection surface — spec forbids.
3. `$?` on external processes flips on *any* stderr write even for exit 0; `$LASTEXITCODE` is the documented correct signal.

**Alternatives.** `Start-Process -Wait -NoNewWindow` — still redirects stdin handles in pwsh 7 on Windows in ways that mangle tmux's fullscreen redraw. Rejected.

**Consequences.** pwsh returns when `ssh -t` exits — functionally equivalent to bash `exec ssh …` (no orphan process, no leftover child).

Stderr routing: `2>$null` on the data-fetch ssh call suppresses stderr from `ssh.exe`. Under `$ErrorActionPreference = 'Stop'`, native-command stderr written to PS's error stream can throw; `$PSNativeCommandUseErrorActionPreference = $false` (set in preamble) prevents this. The `Die` message replaces any suppressed ssh error text.

**Follow-ups.** None.

### ADR-PC-4: Per-user PATH update via `[Environment]::SetEnvironmentVariable`

**Decision.** `install.ps1` adds `<repo>\bin` to User-scope PATH. No admin, no `$PROFILE` mutation, no `HKLM` write.

**Drivers.**
1. Mirror bash `install.sh` semantics (per-user, no sudo in happy path).
2. Enable `cmd.exe` invocation too (AC-PC8) — `$PROFILE` would only help pwsh.
3. Windows has no `~/.local/bin` convention on PATH; we must add our own dir.

**Alternatives.** `HKLM` machine-wide PATH — rejected, needs admin, spec explicitly excludes `--system`.

**Consequences.** Changes apply only in new shells. Install script prints a reminder. Idempotent via case-insensitive comparison.

**Follow-ups.** A future `uninstall.ps1` could symmetrically remove the entry — not in v1 scope.

---

## 6. Scope Guardrails Confirmation

- [x] No subcommands beyond `--help` / `-h` — confirmed.
- [x] No config files (YAML/TOML/`.claudehomerc`); env vars only — confirmed.
- [x] No daemon / background workers / state files on Mac mini — confirmed (tmux only; remote command unchanged).
- [x] No iPhone / web client, no extra platforms — confirmed.
- [x] No packaging (PowerShell Gallery, winget manifest, MSIX, Chocolatey, Scoop) — confirmed.
- [x] No `install.ps1 --system` / HKLM PATH — confirmed.
- [x] No Pester test suite — confirmed (manual AC verification per spec).
- [x] No Windows Terminal / WezTerm-specific integrations — confirmed (plain ANSI only).
- [x] PS 5.1 support not attempted — `#Requires -Version 7.0` enforces pwsh 7+.
- [x] LoC budget: `bin/claudehome.ps1` ~150 lines, `install.ps1` ~40 lines, `bin/claudehome.cmd` 1 line — within budget.

---

## 7. Handoff Notes for Autopilot

- Execute this plan as-is. No scope expansion.
- All 12 parent-spec ACs + 8 PC-specific ACs must pass.
- Static (Phase 1) + local-runnable (Phase 2) verification can run headlessly on any Windows host — autopilot executes them.
- **Mac-mini-integration (Phase 3) must NOT be assumed reachable from autopilot's environment.** Produce a handoff checklist for the user to run after autopilot finishes.
- When replacing the "PC — Windows (not yet)" README section, preserve the iPhone placeholder (still out of v1 scope).
- The `CLAUDE.md` "Resuming on a Windows PC" block should be replaced with a 1-line reference to the new README PC section, since the PC client now exists.
- **File creation order (Critic-M3):** autopilot must write deliverables in this sequence: (1) `bin/claudehome.ps1`, (2) `bin/claudehome.cmd`, (3) `install.ps1`, (4) `README.md`, (5) `CLAUDE.md`. The smoke test in `install.ps1` calls `bin/claudehome.cmd --help` and requires both (1) and (2) to exist.

---

## 8. Open Questions

*(Appended to `.omc/plans/open-questions.md` by Planner; copied here for traceability.)*

- None from Planner. Spec ambiguity 14.8% (PASSED); every decision above is either spec-mandated or traces to a ranked driver.

---

## 9. Consensus Addendum

**Consensus status:** APPROVED by Architect + Critic (2026-04-24, iter 2). Plan is ready for autopilot execution.

**Architect iter 1:** SOUND_WITH_REVISIONS (Arch-R1 through Arch-R5).
**Critic iter 1:** ITERATE (Critic-C1, Critic-C3, Critic-M1, Critic-M3).
**Architect iter 2:** APPROVE — all revisions correctly applied; one cosmetic nit on line 97 comment (non-blocking, autopilot may soften inline comment wording for `$PSNativeCommandUseErrorActionPreference` to read: "allows native commands to write stderr without triggering a terminating error under Stop").
**Critic iter 2:** APPROVE — all 5 iter-1 blocking items resolved; two non-blocking minors (stale timestamp label in M1 mock step, imprecise comment at line 97 — both cosmetic).

### Revisions incorporated (Planner iter 2)

- **Arch-R1 [CRITICAL]:** Replaced `-f` with `.Replace('__PROJECTS_DIR__', $ProjectsDir)` in Section 5 fetch payload to avoid `FormatException` on `#{session_name}`.
- **Arch-R2 [CRITICAL]:** Zero-projects guard confirmed present in Section 6.
- **Arch-R3 [HIGH]:** Verbatim help text confirmed present in Section 2.
- **Arch-R4 [HIGH]:** Added `$PSNativeCommandArgumentPassing = 'Standard'` and `$PSNativeCommandUseErrorActionPreference = $false` to preamble.
- **Arch-R5 [MEDIUM]:** Added "Accepted PS-idiom deviations" subsection after Section 8.
- **Critic-C1 [CRITICAL]:** Added default-config validation test to Phase 2 Step 7.
- **Critic-C3 [CRITICAL]:** Added stderr routing paragraph to ADR-PC-3.
- **Critic-M1 [MAJOR]:** Concrete mock-ssh recipe in Phase 2 Step 8.
- **Critic-M3 [MAJOR]:** File-creation order in Handoff Notes.

### Handoff to autopilot

Execute this plan as-is. Deliverable order: `bin/claudehome.ps1` → `bin/claudehome.cmd` → `install.ps1` → `README.md` → `CLAUDE.md`. Run Phase 1 + Phase 2 verification headlessly; produce a Phase 3 user checklist (AC-PC1, AC-PC6, AC-PC7 and AC1–AC8) for manual verification on a Windows host with Tailscale + Mac mini.
