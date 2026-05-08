# Changelog

All notable changes to `claudehome` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses 4-part versioning: `MAJOR.MINOR.BUILD.REVISION`.

## [1.3.0.0] - 2026-05-08

### Added
- **5-type structural classification** (`Folder`, `Suite`, `Project`, `Hub`, `Member`) replacing folder-tree-v1's binary heuristic. Each directory is exactly one type, computed from three signals: presence of `CLAUDE.md`, basename suffix (`_suite`/`_hub`), and Suite ancestor. Folders/Suites drill; Projects/Hubs/Members attach. Picker shows `<name>/  (N)` for Folder/Suite, `<name>  [active/idle]` for Project, `<name>_hub  HUB  [active/idle]` for Hub, `<name>  member  [active/idle]` for Member.
- **Single `[new...]` picker row** with context-aware type prompt (root → folder/suite/project; Folder → folder/project; Suite-no-Hub → folder/member/hub; Suite-with-Hub → folder/member; sub-Folder inside Suite → folder/member). Replaces the separate `[new folder here]`/`[new project here]` rows from folder-tree-v1.
- **Hub-aware scaffolding** for Members in a Suite-with-Hub: the new Member gets `git init` + a `CLAUDE.md` with `@<hub-abs>/README.md` import + appended row in `<hub>/projects.md`. A description prompt fires only in this case.
- **Auto-suffix policy** for Suite/Hub names: prefix-only input auto-appends `_suite`/`_hub`; names already containing the substring anywhere (e.g., `gene-mini_suite_v2`) are rejected with a clear stderr message.
- **`warn()` / `Write-WarnStderr` helpers** defined near the top of each client. Always succeed (return 0 / no-op) so they're safe under `set -euo pipefail` and `$ErrorActionPreference = 'Stop'`.

### Changed
- **Heuristic flipped** from "every immediate child is a directory → Folder" to `[ -f $p/CLAUDE.md ]`. 10 of the user's 14 existing flat projects (those without `CLAUDE.md`) flip to Folder on upgrade. Recovery is one idempotent line documented in CLAUDE.md "Migrating to 5-type v1": `for d in ~/projects/claudehome-projects/*/; do [ -d "$d" ] && [ ! -f "$d/CLAUDE.md" ] && touch "$d/CLAUDE.md"; done`.
- **Wire format** widened from `R/F/P` (3 type codes) to `R/F/S/P/H/M` (6 codes). Server emits 4 codes (`R/F/S/P`); the client parser synthesizes Hub and Member from P rows via path-string ancestor walk. Parser regex widened to `^[RFSPHM]$`.

### Removed
- **`(root)` synthetic bucket** is gone. Top-level picker shows folders/suites and root-level projects flat in one screen, ordered: folders/suites alphabetical → projects/hubs/members active-first then idle alphabetical → `[new...]`. The `[..  back]` row only appears at non-root drill levels.

### Security
- **CRITICAL — RCE in description channel, fixed.** The free-text description for new Members was interpolated raw into the outer `bash -c '...'` SSH command. A single quote in the description (e.g. `hello'; touch /tmp/PWN; echo '`) closed the outer quote and allowed arbitrary command execution on the mini under the SSH user. Added `_sq_escape` helper (`'` → `'\''`) applied to description and pipe-escaped description in both clients. PowerShell also gained a quoted `<<'CLAUDEMD_EOF'` heredoc to prevent remote `$()`/backtick expansion inside the CLAUDE.md body. Caught by the autopilot Phase-4 security reviewer; verified neutralized via PoC. Allowlist-protected fields (project/hub/member names, hub-abs path) were never vulnerable.

### Documentation
- **5-type spec** (`.omc/specs/deep-interview-claudehome-5type-v1.md`): 36 testable AC (20 Mac AC-5T1..AC-5T20, 14 PC AC-5T-PC1..AC-5T-PC14, 2 LOCAL AC-5T-LOCAL1..AC-5T-LOCAL2). Produced via deep-interview at 13.3% ambiguity (PASSED).
- **5-type plan** (`.omc/plans/claudehome-5type-v1-plan.md`, ~1050 lines): 2 ralplan consensus iterations, both Architect and Critic APPROVED.
- **Subsumed:** `.omc/specs/deep-interview-claudehome-hub-aware-v1.md` and `.omc/plans/claudehome-hub-aware-v1-plan.md` — earlier hub-aware-only proposal (used `_pjt` suffix). Folded into the 5-type spec; legacy `*_pjt/` directories are not recognized by the new code (classify as plain Folders); rename to `*_suite/` to opt in.
- **CLAUDE.md** updated: Architecture paragraph rewritten for 5-type model; line counts updated to ~1400 bash / ~960 pwsh; Key docs gain the 5-type spec/plan; Windows post-install verification adds AC-5T-PC1..PC14; new "Migrating to 5-type v1" section with the recovery one-liner and `_pjt` deprecation note.

### Operations
- Three-stage pipeline (deep-interview → ralplan → autopilot) drove the entire change. Critic caught 4 critical patches (auto-suffix substring rejection, undefined `warn()` under `set -e`, fixture regenerate vs extend, AC count discrepancy) in iteration 1; iteration 2 approved cleanly. Autopilot Phase-4 security review caught the description-channel RCE before it shipped.

## [1.2.0.0] - 2026-05-08

### Added
- **Folder-tree v1: drill-down picker over arbitrary nesting.** Replaces the flat `ls -1` discovery in `bin/claudehome` and `bin/claudehome.ps1` with a single-SSH-roundtrip tree-walk emitter and a recursive drill-down picker. New wire format: `---TREE---<path TAB type TAB child_count rows>---TMUX---<sessions>` with `---TRUNCATED---` (>2000 entries) and `---DEPTH-TRUNCATED---` (>8 levels) sentinels surfaced as stderr warnings client-side. Folders organize projects on disk; tmux session names stay `claudehome-<basename>` regardless of folder depth.
- **`[new folder here]` and `[new project here]` rows** in the picker, available at every drill level. `[..  back]` row at row 1 of every non-root drill. Synthetic `(root)` bucket appears at top-level only when both folders and root projects coexist.
- **Globally-unique project names** across the entire tree. Sibling collision check at the prompt; full-tree scan also enforced. Reserved names `.`, `..`, and leading-dot rejected at the prompt (these would either escape the projects root or be filtered by the emitter's hidden-path exclusion, surprising the user on next launch).
- **Wire-format invariant enforcement** in the parser (allowlist regex + type-validity check). A directory with TAB/newline/non-allowlist characters in its name is silently dropped with a single deduped stderr warning per session, instead of corrupting the parse.

### Changed
- **Bash drill-down state machine** uses globals (`PICKER_RESULT`, `PICKER_PROJECT`, `PICKER_PARENT`) to signal between picker frames, NOT non-zero return codes. Required because `set -euo pipefail` aborts on any non-zero return from a function call before a `case "$?"` can read it (verified empirically during ralplan consensus iter-1). PowerShell uses the discriminated-object form (no `set -e` constraint).
- **Truncation handling:** `awk -v RS='\0' -v ORS='\0' 'NR<=2000'` is broken on macOS BWK awk (consumes the entire NUL-stream as one record). Replaced with a portable bash counter `i=$((i+1)); [ "$i" -gt 2000 ] && break` inside the `while read -r -d ''` loop. The `total=$(find ... \| wc -l)` pre-walk count + `---TRUNCATED---` sentinel emission unchanged → R1 mitigation preserved.

### Documentation
- **Folder-tree v1 spec** (`.omc/specs/deep-interview-claudehome-folder-tree-v1.md`): 24 AC (12 Mac AC-FT1..AC-FT12, 10 PC AC-FT-PC1..AC-FT-PC10, 2 LOCAL AC-FT-LOCAL1..AC-FT-LOCAL2). Deep-interview, 14% ambiguity (PASSED).
- **Folder-tree v1 plan** (`.omc/plans/claudehome-folder-tree-v1-plan.md`, 685 lines): 2 ralplan consensus iterations APPROVED.
- **CLAUDE.md** Architecture paragraph updated for drill-down + globally-unique naming; Windows post-install verification gained AC-FT-PC1..PC10.

## [1.1.0.0] - 2026-05-08

### Added
- **tmux-server LaunchAgent on the mini** for macOS Keychain access in claudehome panes. `install_server.sh` writes `~/Library/LaunchAgents/com.${USER}.tmux-server.plist`; the agent runs `tmux new-session -d -s bootstrap` at next GUI login so the persistent tmux server lives in the Aqua securityd session. Panes spawned by that server inherit Aqua securityd, so Python `keyring`, `security` CLI, `git credential-osxkeychain`, and iCloud frameworks all work — previously they failed with `errSecInteractionNotAllowed`. Plist validated with `plutil -lint`; the installer does **not** `launchctl load` (would bind to the wrong launchd domain when run from SSH). Activation happens at next GUI login/reboot; any pre-existing SSH-sessioned tmux server must be killed first (`tmux kill-server` or reboot) for the new server to take over the default socket.

### Fixed
- **Korean / UTF-8 rendering inside tmux + claude over SSH.** `bash --norc --noprofile -c '...'` skipped the user profile that sets `LANG`, and OpenSSH does not forward `LANG`/`LC_ALL` by default — remote tmux sessions inherited `C`/`POSIX` locale, mangling Korean (and any non-ASCII / CJK / emoji). Both `bin/claudehome` and `bin/claudehome.ps1` now prefix the remote bash invocation with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`, in both the picker-fetch and attach paths. On Windows, `$OutputEncoding` and `[Console]::{Output,Input}Encoding` are also set to UTF-8 so pwsh does not garble bytes flowing to/from `ssh.exe` before WezTerm draws. Local-mode path is intentionally untouched (inherits the calling shell's locale and was reported working).

### Documentation
- **Spec amendment** (`Amendment 2026-05-08`) adds **AC-LOCAL4** covering the LaunchAgent and explicitly justifies it as a deliberate, narrowly-scoped exception to the v1 "no daemons / no server-side bootstrap" non-goals. The agent does no work beyond `tmux new-session -d`.
- **CLAUDE.md** carves out the LaunchAgent exception against the "Daemons, background workers, persistent state files" and "Server-side bootstrap" non-goals; the install_server.sh description is extended to mention the plist.
- **README.md** §1 step 8 explains the LaunchAgent and activation steps; the non-goal list is updated with the carve-out.
- `.omc/keychain-tmux-handoff.md` (the original Option 1 / 2 / 3 diagnosis from 2026-05-08) gains a status header noting Option 2 is now automated by `install_server.sh`. Body retained as future-reference context if Keychain ever breaks again for an unrelated reason.

### Operations
- Backfilled annotated tags `v1.0.3.0` and `v1.0.3.1` against their original bump commits — both versions had been committed but never tagged.

## [1.0.3.1] - 2026-05-06

### Documentation
- **Mac v1 spec amendment** allowing `~/.claudehomerc`. Supersedes the original "env vars only, no config file in v1" wording in §Configuration, the "Config file, YAML/TOML settings" non-goal, the "No config files" trade-off line, and the "no config file" clause inside AC10. The rc file (`KEY=VALUE` per line, `#` comments, env vars take precedence) has been load-bearing since v1.0.1.0; the spec text now matches what was shipped.
- **PC v1 spec amendment** recording (a) PC client is remote-only by design — `AC-LOCAL1–3` explicitly do not apply on PC, `bin/claudehome.ps1` has no IP-resolution / hostname-intersection logic, and AC-PC2 "same env var table" is loosened to permit the missing `CLAUDEHOME_LOCAL` row in PC `--help`; (b) `~/.claudehomerc` is allowed on PC, mirroring the Mac amendment. The "strict behavioral parity" pledge remains scoped to AC1–AC12 + AC13–AC18.
- **CLAUDE.md refresh.** Stale line counts (`bin/claudehome` ~150 → ~310, `bin/claudehome.ps1` ~150 → ~228); stale AC-PC range fixed in two spots (AC-PC1–AC-PC8 → AC-PC1–AC-PC9, since AC-PC9 was added with `[new project]` parity); `--system` non-goal clarified as PowerShell-specific (the bash `install_client.sh` and `install_server.sh` do support `--system`).

## [1.0.3.0] - 2026-05-06

### Changed
- **Default projects root renamed** from `~/projects/claudecode` to `~/projects/claudehome-projects`. The old name read like Claude Code's own directory rather than "the directory where claudehome looks for your projects." Mild breaking change for installs that were on the default; existing `~/.claudehomerc` files override the default and are unaffected. Anyone on the old default needs to either move the directory or pin the old path explicitly with `CLAUDEHOME_PROJECTS_DIR=~/projects/claudecode` in `~/.claudehomerc`.

### Documentation
- **Setup restructured into 4 sections.** Old shape interleaved Mac mini and client installs under one "Install software" section, then Tailscale admin console came after — meaning `install_client.sh`/`.ps1` prompted for the mini's hostname *before* the admin-console rename. New shape: §1 Mac mini install → §2 Tailscale admin console (rename mini, enable MagicDNS) → §3 Install clients (Mac/Windows/iPhone H4 subsections) → §4 SSH key setup. Admin-console rename now happens before any client wizard asks for a hostname.
- **Best-README-Template install style.** Each platform's steps are numbered list items with code blocks indented under the parent step. Section H3s carry the order; H4 sub-letters (1a/1b/...) dropped.
- **Tailscale admin console screenshots.** New `docs/images/` directory; §2 now includes tray-menu navigation, devices list with the mini renamed, and a Terminal screenshot illustrating `<mini-user>`.
- **SFTP client screenshots.** Cyberduck (Mac) and WinSCP (Windows) connection-dialog screenshots wired into the Sending files section.
- **`<mini-user>@<mini-host>` SSH login form spelled out** in §2 with an example (`genehan@gene-mini`) and a note that the macOS prompt's hostname is the local one, not the Tailscale one.
- **Native iOS client formally a non-goal.** Termius/Blink + Tailscale + local-mode CLI on the mini is the documented iPhone story.
- **`install_server.sh` moved to §1 step 8.** Local-mode CLI install on the mini was an iPhone-section step but it's a mini-side install; relocated so the mini is fully provisioned in one place.

### Build
- `.gitignore`: added `.claude/` (per-developer Claude Code settings).

## [1.0.2.1] - 2026-04-30

### Documentation
- **README iPhone section.** Replaced the placeholder with the real-world path: Tailscale iOS app, an SSH client (Termius free tier recommended; Blink as paid alternative; iSH explicitly the wrong tool), key generation/authorization, and `install_server.sh` on the mini so SSH'ing in and typing `claudehome` opens the picker locally.

### Build
- **Shellcheck CI.** GitHub Actions workflow at `.github/workflows/shellcheck.yml` runs `shellcheck` against `bin/claudehome`, `install_client.sh`, and `install_server.sh` on every push to `main` and on PRs.
- Fixed two findings so the first run goes green: SC2088 `disable` on the `case '~/'*` glob pattern in `bin/claudehome` (false positive — literal pattern in `case`, not a tilde expansion); replaced `echo "$PEERS" | sed 's/^/  /'` in `install_client.sh` with bash parameter expansion `"  ${PEERS//$'\n'/$'\n  '}"` per SC2001.

## [1.0.2.0] - 2026-04-30

### Added
- **Local mode for `claudehome` on the mini itself.** When `CLAUDEHOME_HOST` resolves to one of this machine's own IPs (auto-detected via hostname/IP intersection, or forced with `CLAUDEHOME_LOCAL=1`), the bash client skips the SSH layer entirely and runs the picker + tmux attach locally. Common case: SSH'd into the mini from an iPhone (Termius/Blink) — same picker UX, no loopback hop. Detection layers: explicit override → `localhost`/`127.*`/`::1` → hostname forms → IP-resolution intersection (catches macOS `LocalHostName` vs `HostName` vs Tailscale node-name variants). Spec amendment: AC-LOCAL1–3 in the v1 spec.
- **`install_server.sh`.** Focused installer for the mini itself: symlinks the CLI, writes `CLAUDEHOME_LOCAL=1` to `~/.claudehomerc`, and skips Tailscale / `ssh-copy-id` guidance (irrelevant when installing on the server). Scope is the CLI install only — tmux/claude/Tailscale bootstrap stays manual per README §1.

### Changed
- **Multi-client shared attach.** Removed `-D` from `tmux new-session -A -D` in both `bin/claudehome` and `bin/claudehome.ps1`. Multiple clients can now stay attached to the same session simultaneously — walk between PC, MacBook, and phone with all views live. Tmux reflows to whichever client typed last. AC-PC6 amended (previous wording asserted the kick behavior).

### Fixed
- **Help-text wording.** `claudehome --help` (Mac + PC) now correctly states that `[new project]` is the **last** picker row (was previously "first" — predated the recency-ordering change in `9623ed5`).

## [1.0.1.0] - 2026-04-29

### Changed
- **Installers renamed.** `install.sh` → `install_client.sh`, `install.ps1` → `install_client.ps1`. Clarifies they are *client-side* installers, distinct from server-side mini setup. All references updated across README, CLAUDE.md, CHANGELOG, and `bin/claudehome*` help text.
- **SSH key authorization decoupled from installer wizards.** Both wizards now skip key generation and `ssh-copy-id`; key authorization is a manual one-time step per README §1c with platform-specific instructions (Mac uses `ssh-copy-id`, Windows uses `ssh-keygen` + remote `Add-Content` since OpenSSH for Windows lacks `ssh-copy-id`). Installer scope narrows to local config (`~/.claudehomerc`, PATH, `fzf`).

### Documentation
- New **"Sending files"** section in README between Usage and Configuration, recommending Cyberduck (Mac), WinSCP (Windows), and FileZilla (cross-platform) for SFTP transfer over the existing Tailscale hostname + SSH key. No CLI feature added — `claudehome` stays a session-attach tool.

## [1.0.0.0] - 2026-04-27

First production release. Mac + Windows clients are at byte-level parity
on the user-visible flow (AC1–AC18 / AC-PC1–AC-PC9 documented in
`.omc/specs/`). Mac client AC13–AC18 verified end-to-end against the live
Mac mini at this version; PC AC-PC9 still requires hands-on Windows
verification.

No code changes between `v0.1.0.0` and `v1.0.0.0` — this is purely a
version-label promotion to mark "v1 shipped".

## [0.1.0.0] - 2026-04-27

Initial versioning baseline. Captures the state of the repository at the
point versioning was introduced.

### Includes
- Mac client (`bin/claudehome`) with picker, single SSH round-trip, tmux
  session-follows-the-user behavior (`-A -D`), and idempotent attach.
- Windows client (`bin/claudehome.ps1` + `.cmd` shim) at byte-level parity
  with the Mac client.
- `install_client.sh` and `install_client.ps1` setup wizards with config file
  (`~/.claudehomerc`), Tailscale + SSH key onboarding, and optional `fzf`.
- `[new project]` picker option for in-line project creation
  (`mkdir -p` folded into the attach payload, single round-trip preserved).
- Recency-ordered picker: active sessions sorted by `tmux session_activity`
  descending, idle projects alphabetical below, `[new project]` last.
- `--reverse` fzf layout so the cursor lands on the most-recently-used
  project at the top.
- Acceptance criteria AC1–AC18 (Mac) and AC-PC1–AC-PC9 (PC) documented in
  `.omc/specs/`.
