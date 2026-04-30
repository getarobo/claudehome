# Changelog

All notable changes to `claudehome` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses 4-part versioning: `MAJOR.MINOR.BUILD.REVISION`.

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
