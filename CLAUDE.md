# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

`claudehome` is a personal always-on development environment powered by Claude Code. A Mac mini runs 24/7 as the central server for all Claude Code projects. Any device (MacBook Pro, PC, iPhone) can connect to it and pick up exactly where it left off. See `README.md` for the user-facing story.

## Architecture (one paragraph)

Each client (`bin/claudehome` on Mac, `bin/claudehome.ps1` on Windows) loads config from `~/.claudehomerc` (if present), then makes **one** SSH round-trip to the Mac mini over Tailscale, asking the remote to walk `CLAUDEHOME_PROJECTS_DIR` and emit a sentinel-delimited tree (`---TREE---<path TAB type TAB child_count rows>---TMUX---<sessions>`, capped at 2000 entries / depth 8 with `---TRUNCATED---` / `---DEPTH-TRUNCATED---` warnings). **Local mode:** when `CLAUDEHOME_HOST` resolves to one of this machine's own IPs (auto-detected via `dscacheutil`/`ifconfig` intersection, or forced with `CLAUDEHOME_LOCAL=1`), the bash client skips the SSH layer entirely and runs both the listing and the attach locally — same picker UX, same tmux semantics, no loopback hop. The PC client is remote-only by design. The remote command is wrapped in `bash --norc --noprofile -c '…'` so shell-profile noise (conda, nvm, pyenv, Tailscale banners) cannot contaminate the sentinel-delimited output. **5-type structure:** every directory under the projects root classifies as exactly one of **Folder** (no `CLAUDE.md`, basename does not end `_suite`), **Suite** (no `CLAUDEHOME.md`, basename ends `_suite` — a workspace cluster grouping a Hub + Members), **Project** (has `CLAUDE.md`, no Suite ancestor), **Hub** (has `CLAUDE.md`, parent IS a Suite, basename ends `_hub` — docs/registry for Members), or **Member** (has `CLAUDE.md`, has a Suite ancestor, not a Hub). Folders/Suites drill; Projects/Hubs/Members attach. The picker is a **drill-down** — top level shows folders/suites alphabetical, then root-level projects active-first then idle, then a single `[new...]` row that prompts for type (folder/suite/project/hub/member, depending on parent context). The server emits 4 wire codes (R/F/S/P); the client parser synthesizes Hub/Member from P rows via path-string ancestor walk. Folders are pure organization on disk; tmux session names remain `claudehome-<basename>` regardless of folder depth, so Project/Hub/Member names are globally unique across the tree. The client renders one picker per drill level (`fzf` preferred, `bash select` / `Read-Host` fallback), then runs `ssh -t … tmux new-session -A -s claudehome-<project> -c <dir> "claude; exec $SHELL"`. `tmux new-session -A` is idempotent: attach if the session exists, create if not. We deliberately omit `-D` so multiple clients may stay attached to the same session simultaneously (tmux reflows to the most-recently-active client). The `; exec $SHELL` tail keeps the tmux session alive after `claude` exits. **Hub-aware scaffolding:** when `[new...] → member` is picked inside a Suite that has exactly one `*_hub` direct child, the new Member gets `git init` + a `CLAUDE.md` with `@<hub-abs>/README.md` import + a row appended to `<hub>/projects.md`.

## Development

- **Main script (Mac):** `bin/claudehome` (bash, ~1400 lines).
- **Main script (Windows):** `bin/claudehome.ps1` (pwsh 7+, ~960 lines) + `bin/claudehome.cmd` shim.
- **Installer (Mac client):** `install_client.sh` — symlinks CLI, runs setup wizard (Tailscale check, host/user prompts, optional fzf), writes `~/.claudehomerc`.
- **Installer (Mac server / local mode):** `install_server.sh` — symlinks CLI on the mini itself for local-mode use (skip Tailscale check, skip ssh-copy-id guidance, write `CLAUDEHOME_LOCAL=1`). Used when SSH'd into the mini from another device (iPhone Termius/Blink) and you want `claudehome` to run the picker locally with no loopback SSH. Does **not** install tmux, claude, or Tailscale — those stay manual per README §1. Also writes `~/Library/LaunchAgents/com.${USER}.tmux-server.plist` so the mini's tmux server starts in the Aqua securityd session at GUI login (macOS Keychain access for panes — see spec AC-LOCAL4).
- **Installer (Windows):** `install_client.ps1` — adds `<repo>\bin` to user PATH, runs setup wizard, writes `~/.claudehomerc`.
- **Config file:** `~/.claudehomerc` — KEY=VALUE format, written by installers. Env vars take precedence.
- **Lint (Mac):** `shellcheck bin/claudehome install_client.sh`.
- **Lint (Windows):** `Invoke-ScriptAnalyzer bin/claudehome.ps1, install_client.ps1`.
- **Smoke test:** `bin/claudehome --help` / `bin/claudehome.ps1 --help` must exit 0 and print usage.
- **Full integration** requires a real Tailscale-reachable Mac mini with `tmux` and `claude` installed. The requires-mac-mini acceptance criteria are AC1–AC8 and AC11 in `.omc/specs/deep-interview-claudehome-v1.md`; PC-specific criteria AC-PC1–AC-PC9 are in `.omc/specs/deep-interview-claudehome-pc-v1.md`. Folder-tree v1 adds AC-FT1–AC-FT12 (Mac), AC-FT-PC1–AC-FT-PC10 (PC), and AC-FT-LOCAL1–AC-FT-LOCAL2 in `.omc/specs/deep-interview-claudehome-folder-tree-v1.md`. **5-type v1 supersedes folder-tree-v1's heuristic** and adds AC-5T1–AC-5T20 (Mac), AC-5T-PC1–AC-5T-PC14 (PC), and AC-5T-LOCAL1–AC-5T-LOCAL2 in `.omc/specs/deep-interview-claudehome-5type-v1.md`.

## Scope guardrails

The following are explicit non-goals — **do not add them** without updating the relevant spec first:

- Subcommands beyond `--help` (`ls`, `kill`, `attach <name>`, `new <name>`) — to create a project, use the in-picker `[new project]` option (AC13–AC18). The CLI surface stays at `claudehome` / `claudehome --help`; no extra args.
- Config files beyond `~/.claudehomerc`; that single dotfile is the only allowed config file
- Daemons, background workers, persistent state files, or anything outside plain tmux *(carve-out: the tmux-server LaunchAgent installed by `install_server.sh` is the one allowed exception, justified by macOS Keychain audit-session inheritance — see spec AC-LOCAL4. The agent does no work beyond `tmux new-session -d`.)*
- iPhone / web clients
- Packaging (npm, Homebrew formula, Docker, systemd, PowerShell Gallery, winget manifest)
- `install_client.ps1 --system` / machine-wide install on Windows. (The bash `install_client.sh` and `install_server.sh` do support `--system` — the non-goal is PowerShell-specific.)
- PowerShell 5.1 support (pwsh 7+ only for the Windows client)
- Server-side bootstrap (mini setup remains manual per README) *(except the tmux-server LaunchAgent in `install_server.sh` — see the daemon non-goal carve-out above)*

iPhone access is solved via any iOS SSH app (Termius, Blink) + Tailscale + the mini's local-mode CLI (`install_server.sh`). A native iOS client is intentionally not pursued — do not propose one.

## Key docs

- `.omc/specs/deep-interview-claudehome-v1.md` — v1 Mac client spec, AC1–AC18 + AC-LOCAL1–3
- `.omc/plans/claudehome-v1-plan.md` — v1 Mac implementation plan with ADR, Architect + Critic consensus addendum
- `.omc/specs/deep-interview-claudehome-pc-v1.md` — v1 PC (PowerShell 7+) client spec, AC-PC1–AC-PC9
- `.omc/plans/claudehome-pc-v1-plan.md` — v1 PC implementation plan, Architect + Critic consensus APPROVED
- `.omc/specs/deep-interview-claudehome-folder-tree-v1.md` — folder-tree v1 spec (drill-down picker, arbitrary nesting), AC-FT1–AC-FT12 + AC-FT-PC1–AC-FT-PC10 + AC-FT-LOCAL1–AC-FT-LOCAL2
- `.omc/plans/claudehome-folder-tree-v1-plan.md` — folder-tree v1 implementation plan, ralplan consensus (2 iterations) APPROVED
- `.omc/specs/deep-interview-claudehome-5type-v1.md` — 5-type structure v1 spec (Folder/Suite/Project/Hub/Member, CLAUDE.md heuristic, single `[new...]` row, hub-aware scaffolding), AC-5T1–AC-5T20 + AC-5T-PC1–AC-5T-PC14 + AC-5T-LOCAL1–AC-5T-LOCAL2
- `.omc/plans/claudehome-5type-v1-plan.md` — 5-type v1 implementation plan, ralplan consensus (2 iterations) APPROVED

## Windows PC — post-install verification

After running `.\install_client.ps1`, open a **new** pwsh window and run the following checklist (AC-PC1–AC-PC9 from the spec):

- **AC-PC1** — `claudehome` by bare name opens the picker and attaches successfully.
- **AC-PC2** — `claudehome --help` and `claudehome -h` print the usage text with the env var table.
- **AC-PC3** — `$env:CLAUDEHOME_HOST = 'alt-host'; claudehome` targets `alt-host` in the error message.
- **AC-PC4** — `$env:CLAUDEHOME_HOST = 'evil;rm'; claudehome` exits 1 with "unsupported characters".
- **AC-PC5** — With fzf on PATH: arrow-key picker. Without fzf: numbered `Read-Host` menu. Both show `[active …]`/`[idle]` annotations.
- **AC-PC6** — Attach from MacBook to a project, then pick the same project from the PC — both clients remain attached to the session simultaneously, sharing live view (tmux reflows to whichever client typed last).
- **AC-PC7** — Attached `claude` renders correctly in WezTerm (ANSI colors, spinner, status line).
- **AC-PC8** — From `cmd.exe`, typing `claudehome` launches the tool via the `.cmd` shim.
- **AC-PC9** — `[new project]` is the **last** picker row, with existing projects above it ordered by tmux activity descending (idle ones alphabetical below the active group). Selecting it prompts for a name, refuses duplicates and disallowed characters with a retry, and lands the user at a `claude` prompt in the new directory on the mini (parity with Mac AC13–AC18).

### Folder-tree v1 (AC-FT-PC1–AC-FT-PC10) — superseded by 5-type v1 below

Folder-tree v1 introduced the drill-down picker. **5-type v1 supersedes its classification heuristic** (was: every-immediate-child-is-dir → Folder; now: has-`CLAUDE.md` → Project) and the `(root)` synthetic bucket is removed. Folder-tree v1 ACs remain valid where they don't conflict with 5-type v1.

### 5-type v1 (AC-5T-PC1–AC-5T-PC14)

After updating to 5-type v1 in pwsh, repeat from a **new** pwsh window:

- **AC-5T-PC1** — A directory with no `CLAUDE.md` and no `_suite` suffix classifies as Folder; picker shows `<name>/  (N)`.
- **AC-5T-PC2** — A directory with no `CLAUDE.md` and `_suite` suffix classifies as Suite; picker shows `<name>_suite/  (N)`.
- **AC-5T-PC3** — A directory with `CLAUDE.md` and no Suite ancestor classifies as Project; picker shows `<name>  [active/idle]`; pick → tmux attach `claudehome-<basename>`.
- **AC-5T-PC4** — A directory with `CLAUDE.md`, parent is a Suite, basename ends `_hub` classifies as Hub; picker shows `<name>_hub  HUB  [active/idle]`.
- **AC-5T-PC5** — A directory with `CLAUDE.md` + Suite ancestor (transitive through sub-folders) classifies as Member; picker shows `<name>  member  [active/idle]`. A `*_hub`-named dir not at Suite top-level is also a Member, not a Hub.
- **AC-5T-PC6** — `[new...]` row appears as the last picker row at every drill level; selecting it prompts `Create what?` with a context-aware type list (root → folder/suite/project; Folder → folder/project; Suite-no-Hub → folder/member/hub; Suite-with-Hub → folder/member; sub-Folder inside Suite → folder/member).
- **AC-5T-PC7** — `[new...] → suite` auto-appends `_suite` if missing; rejects names containing `_suite` substring (trailing or interior, e.g. `gene-mini_suite_v2` rejected with `claudehome: name '_suite' substring not allowed; type just the prefix and the suffix is auto-appended`).
- **AC-5T-PC8** — Same auto-suffix and substring-rejection behavior for `_hub`.
- **AC-5T-PC9** — `[new...] → member` inside a Suite-with-Hub prompts for description, runs `git init`, writes `CLAUDE.md` with `@<hub-abs>/README.md` import + description, appends row to `<hub>/projects.md`. Tmux attaches.
- **AC-5T-PC10** — `[new...] → member` inside a Suite-without-Hub creates plain Member with `# <name>\n` CLAUDE.md only (no scaffolding); no description prompt.
- **AC-5T-PC11** — Multi-Hub Suite: `[new...] → member` warns `claudehome: multiple *_hub siblings found in <suite-root>; skipping hub-aware writes` and creates plain Member with `# <name>\n` CLAUDE.md.
- **AC-5T-PC12** — Globally-unique scan covers Project/Hub/Member basenames across the entire tree. Error wording byte-identical with Mac AC-5T4: `"  '<name>' already exists at <full-path>. Pick a different name."`
- **AC-5T-PC13** — `Invoke-ScriptAnalyzer bin\claudehome.ps1, install_client.ps1 -Severity Warning,Error` exits 0 with no findings.
- **AC-5T-PC14** — Mac↔PC byte parity: creating a Member from PC produces byte-identical files on the mini as creating it from Mac (CLAUDE.md content, projects.md row, .git/ structure modulo timestamps).

## Migrating to 5-type v1

5-type v1 changes the classification rule from "every immediate child is a directory → Folder" to "has `CLAUDE.md` → Project, else Folder/Suite by basename suffix." Existing flat projects without a `CLAUDE.md` flip from Project to Folder.

**Recovery (one-liner, idempotent):** before running `claudehome` for the first time after upgrade, on the mini run:

```sh
for d in ~/projects/claudehome-projects/*/; do
  [ -d "$d" ] && [ ! -f "$d/CLAUDE.md" ] && touch "$d/CLAUDE.md"
done
```

This adds an empty `CLAUDE.md` to any flat project that doesn't have one, restoring its Project classification. Run again any time you want to flip a Folder back to a Project (touch will no-op for existing files).

**Legacy `_pjt` suffix:** the never-shipped hub-aware-v1 spec used `_pjt` as the workspace-cluster suffix. The 5-type model uses `_suite` instead. If you have any `*_pjt/` directories from that earlier spec, rename them to `*_suite/` — the 5-type code does NOT detect or warn about `_pjt`; they classify as plain Folders.
