# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

`claudehome` is a personal always-on development environment powered by Claude Code. A Mac mini runs 24/7 as the central server for all Claude Code projects. Any device (MacBook Pro, PC, iPhone) can connect to it and pick up exactly where it left off. See `README.md` for the user-facing story.

## Architecture (one paragraph)

Each client (`bin/claudehome` on Mac, `bin/claudehome.ps1` on Windows) loads config from `~/.claudehomerc` (if present), then makes **one** SSH round-trip to the Mac mini over Tailscale, asking the remote to list projects under `CLAUDEHOME_PROJECTS_DIR` and any live tmux sessions. **Local mode:** when `CLAUDEHOME_HOST` resolves to one of this machine's own IPs (auto-detected via `dscacheutil`/`ifconfig` intersection, or forced with `CLAUDEHOME_LOCAL=1`), the bash client skips the SSH layer entirely and runs both the listing and the attach locally — same picker UX, same tmux semantics, no loopback hop. The PC client is remote-only by design. The remote command is wrapped in `bash --norc --noprofile -c '…'` so shell-profile noise (conda, nvm, pyenv, Tailscale banners) cannot contaminate the sentinel-delimited output. The client parses projects + session state, shows a picker (`fzf` preferred, `bash select` / `Read-Host` fallback), then runs `ssh -t … tmux new-session -A -s claudehome-<project> -c <dir> "claude; exec $SHELL"`. `tmux new-session -A` is idempotent: attach if the session exists, create if not. We deliberately omit `-D` so multiple clients may stay attached to the same session simultaneously (tmux reflows to the most-recently-active client). The `; exec $SHELL` tail keeps the tmux session alive after `claude` exits.

## Development

- **Main script (Mac):** `bin/claudehome` (bash, ~310 lines).
- **Main script (Windows):** `bin/claudehome.ps1` (pwsh 7+, ~228 lines) + `bin/claudehome.cmd` shim.
- **Installer (Mac client):** `install_client.sh` — symlinks CLI, runs setup wizard (Tailscale check, host/user prompts, optional fzf), writes `~/.claudehomerc`.
- **Installer (Mac server / local mode):** `install_server.sh` — symlinks CLI on the mini itself for local-mode use (skip Tailscale check, skip ssh-copy-id guidance, write `CLAUDEHOME_LOCAL=1`). Used when SSH'd into the mini from another device (iPhone Termius/Blink) and you want `claudehome` to run the picker locally with no loopback SSH. Does **not** install tmux, claude, or Tailscale — those stay manual per README §1. Also writes `~/Library/LaunchAgents/com.${USER}.tmux-server.plist` so the mini's tmux server starts in the Aqua securityd session at GUI login (macOS Keychain access for panes — see spec AC-LOCAL4).
- **Installer (Windows):** `install_client.ps1` — adds `<repo>\bin` to user PATH, runs setup wizard, writes `~/.claudehomerc`.
- **Config file:** `~/.claudehomerc` — KEY=VALUE format, written by installers. Env vars take precedence.
- **Lint (Mac):** `shellcheck bin/claudehome install_client.sh`.
- **Lint (Windows):** `Invoke-ScriptAnalyzer bin/claudehome.ps1, install_client.ps1`.
- **Smoke test:** `bin/claudehome --help` / `bin/claudehome.ps1 --help` must exit 0 and print usage.
- **Full integration** requires a real Tailscale-reachable Mac mini with `tmux` and `claude` installed. The requires-mac-mini acceptance criteria are AC1–AC8 and AC11 in `.omc/specs/deep-interview-claudehome-v1.md`; PC-specific criteria AC-PC1–AC-PC9 are in `.omc/specs/deep-interview-claudehome-pc-v1.md`.

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
