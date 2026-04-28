# Deep Interview Spec: claudehome v1 Windows/PC client (PowerShell 7+)

## Metadata
- Interview ID: claudehome-pc-001
- Rounds: 2
- Final Ambiguity Score: 14.8%
- Type: brownfield (extension of v1 Mac client)
- Generated: 2026-04-24
- Threshold: 20%
- Status: PASSED
- Parent spec: `.omc/specs/deep-interview-claudehome-v1.md`

## Clarity Breakdown
| Dimension | Score | Weight | Weighted |
|-----------|-------|--------|----------|
| Goal Clarity | 0.92 | 0.35 | 0.322 |
| Constraint Clarity | 0.85 | 0.25 | 0.213 |
| Success Criteria | 0.82 | 0.25 | 0.205 |
| Context Clarity | 0.75 | 0.15 | 0.113 |
| **Total Clarity** | | | **0.852** |
| **Ambiguity** | | | **0.148** |

## Goal

Port the v1 bash client (`bin/claudehome`, `install.sh`) to a native Windows PowerShell 7 client (`bin/claudehome.ps1`, `bin/claudehome.cmd`, `install.ps1`) with **strict behavioral parity**: every v1 acceptance criterion (AC1–AC12) from the parent spec must pass identically when the tool is invoked from a PowerShell 7 prompt on Windows. The user-facing command is still `claudehome`; env var names, picker format, remote SSH payload, and session semantics match the bash version byte-for-byte.

The Mac mini (server) is untouched — no server-side changes.

## Constraints

### Shell target
- **PowerShell 7+ only (`pwsh.exe`)**. `#Requires -Version 7.0` in the script.
- Windows PowerShell 5.1 is explicitly **not supported** (uses `??`, `?:`, clean pipeline features that PS 5.1 lacks).

### Architecture — unchanged from v1
- Transport: SSH over Tailscale. Uses Windows OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`, on PATH since Windows 10 1803).
- Session persistence: tmux on the Mac mini. Same session naming `claudehome-<project>`, same `-A -D` flags, same `claude; exec $SHELL` launch.
- Remote command wrapping: identical `bash --norc --noprofile -c '…'` payload. No PC-specific variation.

### Configuration
- Env vars identical to bash: `$env:CLAUDEHOME_HOST`, `$env:CLAUDEHOME_USER`, `$env:CLAUDEHOME_PROJECTS_DIR`.
- Same defaults: `gene-mini` / `$env:USERNAME` / `~/projects/claudecode`.
- Same allowlist regex validation (strict character sets) applied to all four values (HOST, USER, PROJECTS_DIR, PROJECT-post-pick).

### Picker
- **Primary:** `fzf.exe` if present (install via `scoop install fzf` or `winget install junegunn.fzf`).
- **Fallback:** PowerShell `Read-Host`-driven numbered menu — the PS equivalent of bash `select`. No dependency on `Out-ConsoleGridView` or other optional modules.
- Row format identical to bash: `project-name  [active 2h ago]` / `project-name  [idle]`.

### Installation
- `install.ps1` at repo root — the PS mirror of `install.sh`.
- Behavior:
  1. Adds `<repo>\bin` to the current user's `PATH` via `[Environment]::SetEnvironmentVariable('PATH', …, 'User')`.
  2. Drops `bin\claudehome.cmd` shim containing `@pwsh -NoProfile -File "%~dp0claudehome.ps1" %*` (so typing `claudehome` from cmd/pwsh/anywhere invokes the script).
  3. Idempotent: if already installed, updates nothing silently. Refuses to overwrite a non-shim `.cmd` (TOCTOU risk is equivalent to bash version — acceptable).
  4. Prints a reminder that the user must open a new pwsh session for PATH changes to take effect.
- `--system` / machine-wide install is **not** in v1 scope (personal tool, no sudo-equivalent complexity).

### Repo layout
- Single repo, single branch.
- `bin/claudehome.ps1`, `bin/claudehome.cmd`, and `install.ps1` coexist with the existing bash `bin/claudehome` and `install.sh`.
- No separate `windows/` or `pc/` subdirectory.

### WezTerm / terminal
- The script does nothing WezTerm-specific. Standard ANSI output; any modern Windows terminal (WezTerm, Windows Terminal, Alacritty) renders claude correctly.
- Legacy `cmd.exe` / classic PowerShell host may render poorly — documented as "use a modern terminal" in README, not enforced.

### Parity pledge
- **All 12 v1 acceptance criteria** (AC1–AC12 from the parent spec) must pass when tested against this PC client, using the same verification steps.
- Internal implementation details (error message wording, exact exit-code semantics around Ctrl-C, log output) may deviate **only** where PS idioms require it, never for cosmetic preference.

## Non-Goals

- PowerShell 5.1 support (Windows PowerShell); pwsh 7+ only
- PowerShell Gallery publication / `Install-Module`
- winget manifest / MSIX / Chocolatey / Scoop package
- Pester test suite (acceptance testing is manual in v1 for both Mac and PC)
- Windows Terminal–specific features (tab title, split panes, bell hooks)
- `claudehome` CLI subcommands (`ls`, `kill`, `attach <name>`) — still v1 non-goals for both clients
- Config file on Windows (`.claudehomerc`, TOML, etc.) — env vars only, same as Mac
- `install.ps1 --system` / machine-wide install
- Administrator elevation (`Start-Process -Verb RunAs`)
- iPhone / iOS client (separate v2 pass)
- Behavior deviations from bash for subjective reasons
- Telemetry, auto-update, self-update

## Acceptance Criteria

### Inherited from v1 spec (AC1–AC12) — must pass identically on PC

AC1–AC12 from `.omc/specs/deep-interview-claudehome-v1.md` are the PC test manifest. Each must pass when the trigger is `claudehome` invoked at a pwsh 7 prompt on a Windows client (instead of bash on macOS). The underlying tmux session created on the Mac mini is byte-identical regardless of which client launched it, so AC5–AC8, AC10, AC11 are architecturally guaranteed by the parity pledge — the PC test is just "did a PC client successfully trigger the same AC".

### PC-specific acceptance criteria

- [ ] **AC-PC1** (Install) — On a fresh Windows PC with pwsh 7, Tailscale logged in, and `ssh gene-mini echo ok` already working, `git clone` this repo and run `.\install.ps1`. Expect: user PATH updated, `bin\claudehome.cmd` present, success message printed. A **new** pwsh session can run `claudehome` by bare name.
- [ ] **AC-PC2** (Help) — `claudehome --help` and `claudehome -h` in pwsh print the same usage text as the Mac version (same env var table, same session-lifecycle note, same tilde-quoting caveat).
- [ ] **AC-PC3** (Env vars) — `$env:CLAUDEHOME_HOST = 'alt-host'; claudehome` targets `alt-host`. Permanent user env var via `[Environment]::SetEnvironmentVariable(...,'User')` also takes effect in new pwsh sessions. Overrides work for `CLAUDEHOME_USER` and `CLAUDEHOME_PROJECTS_DIR` identically.
- [ ] **AC-PC4** (Injection guards) — `$env:CLAUDEHOME_HOST = 'evil;rm'; claudehome` exits non-zero with a clear `unsupported characters` message, same class as the bash version. Same for PROJECTS_DIR with a single quote, USER with a space, and project directories with special chars.
- [ ] **AC-PC5** (Picker fallback) — With `fzf.exe` on PATH, the picker is fzf. Rename/remove it (or run via `Remove-Item Env:PATH; claudehome` scenario), and the script falls back to a `Read-Host` numbered menu. Both paths show `[active <age>]` / `[idle]` annotations identical to bash.
- [ ] **AC-PC6** (`-A -D` semantics) — Attach from MacBook to `hello`. From the PC, run `claudehome`, pick `hello`. Expect: MacBook session cleanly detaches; PC takes over. Verifies `-D` flag is present in the remote command after PS quoting.
- [ ] **AC-PC7** (TTY + rendering) — Attached `claude` renders correctly in WezTerm on the PC: ANSI colors, spinner, claude status line all visible and unmangled. (Same check applies in Windows Terminal, but WezTerm is the documented happy path.)
- [ ] **AC-PC8** (Shim invocation) — From a `cmd.exe` prompt (not pwsh), typing `claudehome` launches the tool successfully via the `.cmd` shim. This verifies the shim works for non-pwsh shells, not just pwsh.
- [ ] **AC-PC9** (New-project parity) — All of AC13–AC18 from the parent spec pass identically when invoked from `claudehome.ps1` on Windows: `[new project]` is the last picker row; `Read-Host` prompts `New project name`; empty input exits 0; allowlist + duplicate names trigger retry; a fresh name creates the directory on the mini and attaches the user to a `claude` prompt in it via the same single SSH round-trip; existing projects are ordered by tmux activity descending with idle ones alphabetical below.

## Assumptions Exposed & Resolved

| Assumption | Challenge | Resolution |
|------------|-----------|------------|
| "Feature-identical" is self-evident | Does "identical" allow subtle UX drift for PS idioms? | Strict: all AC1–AC12 pass the same way; internal can diverge only when PS idiom demands, never for cosmetic preference |
| PS 5.1 compat is a freebie | Does supporting both PS 5.1 and 7 add meaningful cost? | Yes — loses `??`, `?:`, cleaner pipeline syntax, forces fallbacks. User only uses pwsh 7. Target pwsh 7+ exclusively, documented via `#Requires -Version 7.0` |
| An install script is overkill | Why not just tell users to edit their PATH manually? | Mac has `install.sh`; strict parity means PC should have equivalent ergonomics. `install.ps1` mirrors the Mac flow and saves a real-install-surface debugging round |
| Picker missing = error | Should missing fzf.exe fail the tool? | No. AC12 is part of the parity pledge — native `Read-Host` numbered menu is the PS equivalent of bash `select` |
| Windows OpenSSH differs in meaningful ways | Will `ssh -t` and nested command quoting behave like macOS? | No meaningful differences for our payload. Windows OpenSSH (10+) supports `-t`, inherits `ssh.exe`-level quoting. The `bash --norc --noprofile -c '…'` wrapper is the remote shell's concern, not the local client's |
| Claude Code Windows SSH bugs apply | Do #25659 and #29761 affect us? | No — those bugs hit when `claude` runs locally on Windows and tries to SSH out. We run `claude` on the Mac mini; Windows is purely an SSH client launching tmux. Orthogonal |
| We need WezTerm-specific code | Should we hint tab titles or color profiles? | No. Plain ANSI output is enough; WezTerm/Windows Terminal/Alacritty all render correctly without intervention |

## Technical Context (brownfield)

### Existing reference
- `bin/claudehome` — bash, ~140 lines, all ACs validated
- `install.sh` — bash, ~70 lines
- `.omc/specs/deep-interview-claudehome-v1.md` — parent spec (AC1–AC12)
- `.omc/plans/claudehome-v1-plan.md` — v1 consensus plan (Planner/Architect/Critic APPROVE)

Every behavior decision already lives in those four files. The PS port is mechanical.

### PowerShell-specific implementation notes

- **String quoting for nested SSH payload**: PowerShell double-quoted strings interpolate `$var` and backticks escape. The safest pattern for building the SSH argument is: construct the remote-bash payload as a PS here-string or single-quoted literal (to avoid accidental `$` expansion), then pass it to `ssh.exe` as a single argument. Variables we *do* want PS to expand (host, user, project, dir) get spliced via `"… $var …"` string formation **after** allowlist validation, so the only chars that reach the remote command are ones we've already constrained.
- **Running ssh.exe from pwsh**: Call directly as `ssh.exe "$user@$host" "$remoteCmd"`. Do **not** use `Invoke-Expression`. Use `$LASTEXITCODE` to branch on failure instead of `$?` (more robust for external processes).
- **Attach via exec**: pwsh has no exec equivalent; but `ssh -t` replaces stdin/stdout of the parent for the lifetime of the child, and when it exits, pwsh returns. That's functionally the same outcome — no leftover background ssh process.
- **`#Requires -Version 7.0`** at top of `claudehome.ps1` enforces pwsh 7+ at invocation.
- **ExecutionPolicy**: `git clone` doesn't apply Mark-of-the-Web (MOTW), so standard `RemoteSigned` policy permits the cloned scripts. If a user downloads the repo as a zip, MOTW might block; README will note `Unblock-File` as a fallback. The `.cmd` shim sidesteps ExecutionPolicy entirely because it invokes `pwsh.exe -NoProfile -File <path>` which uses the Bypass path in most default configurations.

### Implementation surface
- `bin/claudehome.ps1` — target ~150 lines (≈ same complexity as bash, plus PS's verbosity)
- `bin/claudehome.cmd` — 1 line of actual code: `@pwsh -NoProfile -File "%~dp0claudehome.ps1" %*` + a header comment
- `install.ps1` — target ~40 lines
- `README.md` — replace the "PC — Windows (not yet)" section with a real setup section (prereqs, install steps, env var notes, WezTerm tip)
- `CLAUDE.md` — one-line update noting the PS client now exists alongside the bash version

## Ontology (Key Entities)

Inherited from v1 — PC client does not introduce a new entity (it's a specialization of `Client`).

| Entity | Type | Fields | Relationships |
|--------|------|--------|---------------|
| Client | external | OS (macOS/Windows), shell (bash/pwsh), has SSH + optional fzf | Initiates SSH to MacMini |
| MacMini | external system | Tailscale hostname (`gene-mini`), has `tmux` + `claude` in PATH | Hosts Projects and TmuxSessions |
| Project | core | name, path (`~/projects/claudecode/<name>`) | Belongs to MacMini; has 0..1 TmuxSession |
| TmuxSession | core | name (`claudehome-<project>`), state, last_activity | Runs on MacMini |
| ClaudeCodeSession | core | `claude` process inside tmux | Replaceable child of TmuxSession |
| Shell | supporting | user's `$SHELL` on the mini | Takes over when ClaudeCodeSession exits |

## Ontology Convergence

| Round | Entities | New | Changed | Stable | Stability |
|-------|----------|-----|---------|--------|-----------|
| 0 (v1 inherited) | 6 | — | — | 6 | 100% |
| 1 | 6 | 0 | 0 | 6 | 100% |
| 2 | 6 | 0 | 0 | 6 | 100% |

Brownfield note: entity set is completely stable across both interview rounds and matches the v1 ontology exactly. The PC client does not introduce new domain concepts — it's a second **instance** of the `Client` entity, not a new entity type.

## Interview Transcript

<details>
<summary>Full Q&A (2 rounds)</summary>

### Round 1 — Success Criteria (pre-interview weakest, 0.50)
**Q:** What's the minimum bar to call `claudehome.ps1` v1 shipped? Strict parity with bash / parity on user-facing flow only / just work on this PC / proper open-source companion.
**A:** Strict parity with bash.
**Implications:** All AC1–AC12 must pass identically on PC. Internal deviation only when PS idiom demands.
**Ambiguity:** 19.6% (Goal: 0.92, Constraints: 0.68, Criteria: 0.80, Context: 0.75)

### Round 2 — Constraints (0.68)
**Q:** Install UX — install.ps1 (mirror of bash) / manual / PowerShell Gallery / no shim?
**A:** install.ps1 (mirror of bash). Preview selected showed the `git clone → .\install.ps1 → claudehome` flow.
**Implications:** Ship install.ps1 at repo root. Adds `<repo>\bin` to user PATH, drops `.cmd` shim. Idempotent, per-user, no sudo.
**Ambiguity:** 14.8% (Goal: 0.92, Constraints: 0.85, Criteria: 0.82, Context: 0.75)

</details>
