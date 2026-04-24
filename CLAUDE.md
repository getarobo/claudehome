# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

`claudehome` is a personal always-on development environment powered by Claude Code. A Mac mini runs 24/7 as the central server for all Claude Code projects. Any device (MacBook Pro, PC, iPhone) can connect to it and pick up exactly where it left off. See `README.md` for the user-facing story.

## Architecture (one paragraph)

Each client (`bin/claudehome` on Mac, `bin/claudehome.ps1` on Windows) makes **one** SSH round-trip to the Mac mini over Tailscale, asking the remote to list projects under `CLAUDEHOME_PROJECTS_DIR` and any live tmux sessions. The remote command is wrapped in `bash --norc --noprofile -c '…'` so shell-profile noise (conda, nvm, pyenv, Tailscale banners) cannot contaminate the sentinel-delimited output. The client parses projects + session state, shows a picker (`fzf` preferred, `bash select` / `Read-Host` fallback), then runs `ssh -t … tmux new-session -A -D -s claudehome-<project> -c <dir> "claude; exec $SHELL"`. `tmux new-session -A` is idempotent: attach if the session exists, create if not. The `-D` flag detaches any other clients currently attached to the same session. The `; exec $SHELL` tail keeps the tmux session alive after `claude` exits. There is no daemon, no config file, and no state on the Mac mini beyond the tmux sessions themselves.

## Development

- **Main script (Mac):** `bin/claudehome` (bash, ~150 lines).
- **Main script (Windows):** `bin/claudehome.ps1` (pwsh 7+, ~150 lines) + `bin/claudehome.cmd` shim.
- **Installer (Mac):** `install.sh` — symlinks to `~/.local/bin/claudehome` (or `/usr/local/bin` with `--system`).
- **Installer (Windows):** `install.ps1` — adds `<repo>\bin` to user PATH, verifies shim.
- **Lint (Mac):** `shellcheck bin/claudehome install.sh`.
- **Lint (Windows):** `Invoke-ScriptAnalyzer bin/claudehome.ps1, install.ps1`.
- **Smoke test:** `bin/claudehome --help` / `bin/claudehome.ps1 --help` must exit 0 and print usage.
- **Full integration** requires a real Tailscale-reachable Mac mini with `tmux` and `claude` installed. The requires-mac-mini acceptance criteria are AC1–AC8 and AC11 in `.omc/specs/deep-interview-claudehome-v1.md`; PC-specific criteria AC-PC1–AC-PC8 are in `.omc/specs/deep-interview-claudehome-pc-v1.md`.

## Scope guardrails

The following are explicit non-goals — **do not add them** without updating the relevant spec first:

- Subcommands beyond `--help` (`ls`, `kill`, `attach <name>`, `new`)
- Config files (YAML/TOML/`.claudehomerc`); env vars only
- Daemons, background workers, persistent state files, or anything outside plain tmux
- iPhone / web clients
- Packaging (npm, Homebrew formula, Docker, systemd, PowerShell Gallery, winget manifest)
- `install.ps1 --system` / machine-wide install on Windows
- PowerShell 5.1 support (pwsh 7+ only for the Windows client)

iPhone client is planned but out of scope for this pass.

## Key docs

- `.omc/specs/deep-interview-claudehome-v1.md` — v1 Mac client spec, 12 acceptance criteria
- `.omc/plans/claudehome-v1-plan.md` — v1 Mac implementation plan with ADR, Architect + Critic consensus addendum
- `.omc/specs/deep-interview-claudehome-pc-v1.md` — v1 PC (PowerShell 7+) client spec, 8 PC-specific ACs
- `.omc/plans/claudehome-pc-v1-plan.md` — v1 PC implementation plan, Architect + Critic consensus APPROVED

## Windows PC — post-install verification

After running `.\install.ps1`, open a **new** pwsh window and run the following checklist (AC-PC1–AC-PC8 from the spec):

- **AC-PC1** — `claudehome` by bare name opens the picker and attaches successfully.
- **AC-PC2** — `claudehome --help` and `claudehome -h` print the usage text with the env var table.
- **AC-PC3** — `$env:CLAUDEHOME_HOST = 'alt-host'; claudehome` targets `alt-host` in the error message.
- **AC-PC4** — `$env:CLAUDEHOME_HOST = 'evil;rm'; claudehome` exits 1 with "unsupported characters".
- **AC-PC5** — With fzf on PATH: arrow-key picker. Without fzf: numbered `Read-Host` menu. Both show `[active …]`/`[idle]` annotations.
- **AC-PC6** — Attach from MacBook to a project, then pick the same project from the PC — MacBook detaches cleanly.
- **AC-PC7** — Attached `claude` renders correctly in WezTerm (ANSI colors, spinner, status line).
- **AC-PC8** — From `cmd.exe`, typing `claudehome` launches the tool via the `.cmd` shim.
