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

- `.omc/specs/deep-interview-claudehome-v1.md` — crystallized requirements, 12 acceptance criteria
- `.omc/plans/claudehome-v1-plan.md` — implementation plan with ADR, Architect + Critic consensus addendum
