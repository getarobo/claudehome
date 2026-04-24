# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

`claudehome` is a personal always-on development environment powered by Claude Code. A Mac mini runs 24/7 as the central server for all Claude Code projects. Any device (MacBook Pro, PC, iPhone) can connect to it and pick up exactly where it left off. See `README.md` for the user-facing story.

## Architecture (one paragraph)

The client runs `bin/claudehome` (bash). It makes **one** SSH round-trip to the Mac mini over Tailscale, asking the remote to list projects under `CLAUDEHOME_PROJECTS_DIR` and any live tmux sessions. The remote command is wrapped in `bash --norc --noprofile -c '…'` so shell-profile noise (conda, nvm, pyenv, Tailscale banners) cannot contaminate the sentinel-delimited output. The client parses projects + session state, shows a picker (`fzf` preferred, bash `select` fallback), then runs `ssh -t … tmux new-session -A -s claudehome-<project> -c <dir> "claude; exec $SHELL"`. `tmux new-session -A` is idempotent: attach if the session exists, create if not. The `; exec $SHELL` tail keeps the tmux session alive after `claude` exits, so you drop to a shell and can relaunch in place. There is no daemon, no config file, and no state on the Mac mini beyond the tmux sessions themselves.

## Development

- **Main script:** `bin/claudehome` (bash, ~80 lines).
- **Installer:** `install.sh` — symlinks to `~/.local/bin/claudehome` (or `/usr/local/bin` with `--system`).
- **Lint:** `shellcheck bin/claudehome install.sh`.
- **Smoke test:** `bin/claudehome --help` must exit 0 and print usage.
- **Full integration** (resuming sessions, multi-project concurrency, etc.) requires a real Tailscale-reachable Mac mini with `tmux` and `claude` installed. The requires-mac-mini acceptance criteria are AC1–AC8 and AC11 in `.omc/specs/deep-interview-claudehome-v1.md`.

## Scope guardrails

v1 is Mac client only. The following are explicit non-goals — **do not add them** without updating the spec first:

- Subcommands beyond `--help` (`ls`, `kill`, `attach <name>`, `new`)
- Config files (YAML/TOML/`.claudehomerc`); env vars only
- Daemons, background workers, persistent state files, or anything outside plain tmux
- Windows / iPhone / web clients
- Packaging (npm, Homebrew formula, Docker, systemd)

Windows PowerShell and iPhone clients are planned but deliberately out of scope for this pass.

## Key docs

- `.omc/specs/deep-interview-claudehome-v1.md` — v1 Mac client spec, 12 acceptance criteria
- `.omc/plans/claudehome-v1-plan.md` — v1 Mac implementation plan with ADR, Architect + Critic consensus addendum
- `.omc/specs/deep-interview-claudehome-pc-v1.md` — v1 PC (PowerShell 7+) client spec, strict-parity port, 14.8% ambiguity, **pending ralplan + autopilot execution on a Windows machine**

## Resuming on a Windows PC

The PC (pwsh 7) port was scoped on macOS and left unbuilt so it can be executed natively on the target machine. When resuming on Windows:

1. `git pull` this repo to a working dir on the PC.
2. Open Claude Code in the repo root.
3. Invoke the 3-stage pipeline against the PC spec:
   ```
   /oh-my-claudecode:ralplan --consensus --direct --spec .omc/specs/deep-interview-claudehome-pc-v1.md
   ```
   When consensus is reached, the pipeline chains to autopilot automatically. Autopilot writes `bin/claudehome.ps1`, `bin/claudehome.cmd`, and `install.ps1`, updates README and CLAUDE.md, and runs static QA + validation review.

4. **Scope is locked by the spec** — strict parity with the bash client. Do not add subcommands, drop PS 5.1 compat, skip allowlist validation, or deviate from the bash `bin/claudehome` behavior without updating the spec first. All 12 parent-spec ACs plus 8 PC-specific ACs must pass.

5. After autopilot, run AC-PC1 through AC-PC8 from the spec as a manual verification checklist against your Windows environment.
