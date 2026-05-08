# Handoff: claudehome tmux + macOS Keychain access

> **Status: 2026-05-08 — Option 2 is now automated.**
> `install_server.sh` writes `~/Library/LaunchAgents/com.${USER}.tmux-server.plist` automatically (and the spec at `.omc/specs/deep-interview-claudehome-v1.md` covers it as AC-LOCAL4). Run the installer on the mini (or re-run; idempotent) and reboot to activate. The body below remains as the diagnosis context for future reference if Keychain ever breaks again for an unrelated reason.

## Problem

`claudehome` panes on the mac-mini cannot read items from the macOS login Keychain — even though the keychain is unlocked from the GUI. This breaks any project that uses Python `keyring` (e.g., the `daily-report` iCloud fetcher via the `icalendar-sync` skill) when run interactively from a claudehome session.

The mac-mini's daily scheduled run is **not** affected — it goes through a `~/Library/LaunchAgents/com.genehan.daily-report.plist` UserAgent that runs in the Aqua login session and gets keychain access normally. Only the interactive path (running things by hand inside a claudehome tmux pane) breaks.

## Root cause

The tmux server on the mac-mini was started **inside an SSH session**, not from the GUI desktop. Confirmed by:

```
$ tmux show-env -g | grep -i ssh
SSH_CLIENT=100.65.25.124 1879 22
SSH_CONNECTION=100.65.25.124 1879 100.116.215.28 22
SSH_TTY=/dev/ttys003
```

There is no launchd job pre-warming a GUI-sessioned tmux server (`launchctl list | grep tmux` empty, `~/Library/LaunchAgents/` has no tmux plist).

macOS binds Keychain access to the `securityd` session of whoever started the process. SSH sessions get a distinct security session that does not inherit the unlocked GUI Keychain — calls fail with `errSecInteractionNotAllowed` ("User interaction is not allowed"). Because the tmux *server* was the first SSH-sessioned process, every pane spawned by it inherits that broken session, even when reattached later.

Reference: `daily-report` repo, conversation 2026-05-08, where this was diagnosed against the iCloud fetcher.

## What's been ruled out

- ❌ Mac was locking the keychain → confirmed not the cause; keychain is unlocked from desktop.
- ❌ Bug in `daily-report` or `icalendar-sync` → SSH and bare-tmux paths fail identically; LaunchAgent path works.
- ❌ Login keychain ACL on individual items → would also fail from GUI Terminal, doesn't.

## Three fixes (pick one)

### Option 1 — Bootstrap tmux from the GUI after each reboot (cheapest)

Once per boot, on the mac-mini's physical desktop (or via Screen Sharing into the logged-in GUI):

1. Open `Terminal.app`.
2. Kill any existing SSH-sessioned tmux server: `tmux kill-server` (or `pkill tmux`).
3. Start a fresh server in the GUI session: `tmux new -d -s bootstrap`.
4. Detach. Future `claudehome` SSH connections will attach to this GUI-sessioned server, and panes inherit Aqua securityd → keychain works.

Drawback: manual step after every reboot. The mac-mini doesn't reboot often, but auto-updates do happen.

### Option 2 — LaunchAgent that pre-starts a tmux server (recommended for permanence)

Write `~/Library/LaunchAgents/com.genehan.tmux-server.plist` that runs `tmux new -d -s bootstrap` at login. Because it's a UserAgent, it loads into the Aqua session, so the resulting tmux server has GUI securityd. Subsequent claudehome SSH connections do `tmux new-session -A -s claudehome-<project>` — the `-A` attaches to the existing server.

Sketch:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.genehan.tmux-server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/tmux</string>
    <string>new-session</string>
    <string>-d</string>
    <string>-s</string>
    <string>bootstrap</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>/Users/genehan/Library/Logs/tmux-bootstrap.log</string>
  <key>StandardErrorPath</key><string>/Users/genehan/Library/Logs/tmux-bootstrap.log</string>
</dict>
</plist>
```

Load: `launchctl load ~/Library/LaunchAgents/com.genehan.tmux-server.plist`.

Verify after next login: `tmux show-env -g | grep SSH` should print **nothing** in panes attached from claudehome.

### Option 3 — Avoid Keychain in affected projects (most portable)

For `daily-report` (and any other project that hits Keychain via `keyring`), switch the secret source to env var or `chmod 600` config file. The `icalendar-sync` skill explicitly supports both — see its description: "credential setup via keyring/environment/config file."

Drawback: app-specific password sits on disk in plaintext (mitigated by file perms). Doesn't fix Keychain access for *other* future tools — it just sidesteps the problem per-project.

## Recommendation

**Option 2 + Option 3 in combination.** Option 2 makes claudehome panes generally Keychain-capable for any future tool; Option 3 makes `daily-report` resilient against this whole class of issue (e.g., if you ever reach the mac-mini *only* via SSH without going through tmux).

If you only want to do one thing right now, do Option 2.

## Validation steps after applying a fix

1. Detach all claudehome sessions, kill old tmux server if any.
2. SSH into mac-mini fresh (or open new claudehome session from a client).
3. In a pane: `tmux show-env -g | grep -i ssh` → for Option 2, should be empty.
4. In `daily-report`: `just dry-run-notify` → iCloud calendar block should populate without `keyring` errors.
5. Cross-check: `~/Library/Logs/daily-report.log` shows the next 08:30 KST scheduled run still succeeds (LaunchAgent path unchanged).

## Out of scope / do not touch

- The `daily-report` LaunchAgent plists (`com.genehan.daily-report.plist`, `…healthcheck.plist`) — already correct, do not modify.
- The window-narrowing change to `daily_report/fetchers/{gcal,icloud}.py` currently uncommitted on `main` — separate work, unrelated to this issue.
