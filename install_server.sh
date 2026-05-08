#!/usr/bin/env bash
# install_server.sh — install claudehome on the Mac mini for LOCAL mode.
#   Use this when you SSH into the mini (e.g., from iPhone Termius/Blink) and
#   want to run `claudehome` directly on the mini, skipping the loopback SSH.
#
#   Default target: ~/.local/bin (no sudo).
#   Override:       ./install_server.sh --system   (uses sudo to target /usr/local/bin)
#
# Re-running is safe — values already in ~/.claudehomerc are kept.
#
# Scope: installs only the claudehome CLI + config. Does NOT install tmux,
# claude, or Tailscale — those remain manual per README §1.

set -euo pipefail

REPO_DIR=
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -z "$REPO_DIR" ]]; then
  echo "install: cannot resolve repository directory." >&2
  exit 1
fi
SRC="${REPO_DIR}/bin/claudehome"
RC="${HOME}/.claudehomerc"

if [[ ! -x "$SRC" ]]; then
  chmod +x "$SRC" 2>/dev/null || {
    echo "install: ${SRC} not found or not executable." >&2
    exit 1
  }
fi

# ---- parse flags ----
SYSTEM=0
for arg in "$@"; do
  case "$arg" in
    --system) SYSTEM=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./install_server.sh [--system]

Installs claudehome on THIS Mac mini for LOCAL mode — the CLI runs the
picker and tmux attach directly, with no loopback SSH. Useful when you
SSH into this mini from another device (iPhone via Termius/Blink, etc.)
and want the same picker UX.

  --system   Install to /usr/local/bin (requires sudo)

Scope: installs only the claudehome CLI + config. Does NOT install
tmux, claude, or Tailscale — those remain manual per README §1.
EOF
      exit 0
      ;;
    *) echo "install: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

# ── Step 1: symlink ──────────────────────────────────────────────────────────
if (( SYSTEM )); then
  TARGET_DIR=/usr/local/bin
  LINK="${TARGET_DIR}/claudehome"
  if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    echo "install: ${LINK} exists and is not a symlink; refusing to overwrite." >&2
    exit 1
  fi
  echo "install: symlinking to ${LINK} (sudo)…"
  sudo ln -sf "$SRC" "$LINK"
else
  TARGET_DIR="${HOME}/.local/bin"
  LINK="${TARGET_DIR}/claudehome"
  mkdir -p "$TARGET_DIR"
  if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    echo "install: ${LINK} exists and is not a symlink; refusing to overwrite." >&2
    exit 1
  fi
  ln -sf "$SRC" "$LINK"
  echo "install: symlinked ${LINK} → ${SRC}"
fi

# ── Step 2: PATH ─────────────────────────────────────────────────────────────
SHELL_RC="${HOME}/.zshrc"
[[ "${SHELL:-}" == */bash ]] && SHELL_RC="${HOME}/.bashrc"
if ! (( SYSTEM )); then
  if ! grep -qF "${TARGET_DIR}" "$SHELL_RC" 2>/dev/null; then
    {
      echo ""
      echo "# added by claudehome install_server.sh"
      echo "export PATH=\"${TARGET_DIR}:\$PATH\""
    } >> "$SHELL_RC"
    echo "install: added ${TARGET_DIR} to PATH in ${SHELL_RC}"
  fi
fi

# ── helpers ──────────────────────────────────────────────────────────────────
_rc_get() {
  local key="$1"
  [[ -f "$RC" ]] || return 0
  grep -E "^${key}=" "$RC" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
_rc_set() {
  local key="$1" val="$2"
  if [[ -f "$RC" ]] && grep -qE "^${key}=" "$RC" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    grep -v "^${key}=" "$RC" > "$tmp"
    echo "${key}=${val}" >> "$tmp"
    mv "$tmp" "$RC"
  else
    echo "${key}=${val}" >> "$RC"
  fi
}

# ── Clear stale shell-rc exports (config file is the source of truth) ────────
for var in CLAUDEHOME_HOST CLAUDEHOME_USER CLAUDEHOME_PROJECTS_DIR CLAUDEHOME_LOCAL; do
  unset "$var" 2>/dev/null || true
  if grep -qE "^export ${var}=" "$SHELL_RC" 2>/dev/null; then
    _tmp=$(mktemp)
    grep -v "^export ${var}=" "$SHELL_RC" > "$_tmp"
    mv "$_tmp" "$SHELL_RC"
    echo "install: removed stale 'export ${var}' from ${SHELL_RC} (now read from ${RC})."
  fi
done

# ── Step 3: init config file ─────────────────────────────────────────────────
if [[ ! -f "$RC" ]]; then
  cat > "$RC" <<'EOF'
# claudehome config — written by install_server.sh
# Environment variables take precedence over this file.
EOF
  echo "install: created ${RC}"
fi

echo ""
echo "── Local mode configuration ────────────────────────────────────────────────"

# ── Step 4: CLAUDEHOME_HOST (defaults to `hostname -s`) ──────────────────────
# Value is essentially advisory in local mode (CLAUDEHOME_LOCAL=1 wins), but
# we still set it so the validation pass succeeds and so flipping LOCAL=0 for
# loopback tests makes sense.
EXISTING_HOST="$(_rc_get CLAUDEHOME_HOST)"
if [[ -n "$EXISTING_HOST" ]]; then
  echo "install: CLAUDEHOME_HOST already set to '${EXISTING_HOST}' — skipping."
  CHOSEN_HOST="$EXISTING_HOST"
else
  DEFAULT_HOST=$(hostname -s 2>/dev/null || hostname || echo "")
  read -r -p "Tailscale hostname of this mini (default: ${DEFAULT_HOST}): " CHOSEN_HOST
  CHOSEN_HOST="${CHOSEN_HOST:-$DEFAULT_HOST}"
  if [[ -z "$CHOSEN_HOST" ]]; then
    echo "install: hostname required." >&2
    exit 1
  fi
  _rc_set CLAUDEHOME_HOST "$CHOSEN_HOST"
  echo "install: saved CLAUDEHOME_HOST=${CHOSEN_HOST}"
fi

# ── Step 5: CLAUDEHOME_USER (defaults to $USER) ──────────────────────────────
EXISTING_USER="$(_rc_get CLAUDEHOME_USER)"
if [[ -n "$EXISTING_USER" ]]; then
  echo "install: CLAUDEHOME_USER already set to '${EXISTING_USER}' — skipping."
  CHOSEN_USER="$EXISTING_USER"
else
  CHOSEN_USER="$USER"
  _rc_set CLAUDEHOME_USER "$CHOSEN_USER"
  echo "install: saved CLAUDEHOME_USER=${CHOSEN_USER}"
fi

# ── Step 6: CLAUDEHOME_LOCAL=1 (always written explicitly) ───────────────────
_rc_set CLAUDEHOME_LOCAL 1
echo "install: saved CLAUDEHOME_LOCAL=1"

# ── Step 7: dependency sanity check ──────────────────────────────────────────
echo ""
echo "── Dependencies ────────────────────────────────────────────────────────────"
MISSING=0
if command -v tmux >/dev/null 2>&1; then
  echo "install: tmux found. ✓"
else
  echo "install: tmux NOT FOUND on PATH. Install before using claudehome:"
  echo "  brew install tmux"
  MISSING=1
fi
if command -v claude >/dev/null 2>&1; then
  echo "install: claude found. ✓"
else
  echo "install: claude NOT FOUND on PATH. Install before using claudehome:"
  echo "  curl -fsSL https://claude.ai/install.sh | bash"
  MISSING=1
fi

# ── Step 8: optional fzf ─────────────────────────────────────────────────────
echo ""
echo "── Optional: fzf (arrow-key picker) ───────────────────────────────────────"
if command -v fzf >/dev/null 2>&1; then
  echo "install: fzf already installed. ✓"
elif command -v brew >/dev/null 2>&1; then
  echo "install: installing fzf via Homebrew…"
  brew install fzf \
    || echo "install: fzf install failed (non-fatal — numbered menu will be used)."
else
  echo "install: fzf not found and Homebrew not available."
  echo "  Numbered menu will be used. To enable arrow-key picker: brew install fzf"
fi

# ── Step 9: tmux LaunchAgent (macOS Keychain access fix) ─────────────────────
# Why this exists: macOS binds Keychain access to the GUI (Aqua) securityd
# session. When the tmux server is first started inside an SSH session, every
# pane it spawns inherits the SSH securityd, and tools that read Keychain
# (Python keyring, security CLI, git credential-osxkeychain, iCloud frameworks)
# fail with errSecInteractionNotAllowed.
#
# This LaunchAgent pre-starts a tmux server in the Aqua session at GUI login,
# so future `tmux new-session -A` attaches to the GUI-sessioned server and
# panes inherit Aqua securityd → Keychain works.
#
# We only WRITE the plist here. We do NOT `launchctl load` it: that would load
# it into whatever launchd domain this script is running in (typically the SSH
# domain when run from a remote shell), defeating the purpose. The plist
# auto-loads on next GUI login.
#
# Spec: AC-LOCAL4 in .omc/specs/deep-interview-claudehome-v1.md
# Diagnosis: .omc/keychain-tmux-handoff.md
echo ""
echo "── tmux LaunchAgent (Keychain access for panes) ───────────────────────────"
TMUX_BIN="$(command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)"
LA_LABEL="com.${USER}.tmux-server"
LA_DIR="${HOME}/Library/LaunchAgents"
LA_PATH="${LA_DIR}/${LA_LABEL}.plist"
LA_LOG="${HOME}/Library/Logs/tmux-bootstrap.log"
mkdir -p "$LA_DIR"

cat > "$LA_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LA_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${TMUX_BIN}</string>
    <string>new-session</string>
    <string>-d</string>
    <string>-s</string>
    <string>bootstrap</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <false/>

  <key>StandardOutPath</key>
  <string>${LA_LOG}</string>

  <key>StandardErrorPath</key>
  <string>${LA_LOG}</string>
</dict>
</plist>
EOF

if plutil -lint "$LA_PATH" >/dev/null 2>&1; then
  echo "install: wrote ${LA_PATH}"
  echo "install: plutil validated ✓"
  echo ""
  echo "  Why: macOS Keychain access requires the GUI (Aqua) securityd session."
  echo "       Without this, claudehome panes inherit the SSH securityd and"
  echo "       tools like Python keyring, 'security' CLI, and iCloud auth fail"
  echo "       with errSecInteractionNotAllowed."
  echo ""
  echo "  Activation (the plist does not auto-load from this shell):"
  echo "    The plist auto-loads on next GUI login. To activate now:"
  echo "      1. Reboot the mini, OR log out and back in on its desktop"
  echo "         (Screen Sharing also counts as a GUI login)."
  echo "      2. Any pre-existing SSH-sessioned tmux server must die first —"
  echo "         'tmux kill-server' (kills all sessions) or just reboot."
  echo "  Verify after activation:"
  echo "      tmux show-env -g | grep -i ssh    # prints nothing"
else
  echo "install: WARNING — ${LA_PATH} failed plist validation; removing." >&2
  rm -f "$LA_PATH"
fi

# ── Smoke test + summary ─────────────────────────────────────────────────────
echo ""
if "$LINK" --help >/dev/null 2>&1; then
  echo "────────────────────────────────────────────────────────────────────────────"
  echo "claudehome installed on this mini in LOCAL mode."
  echo ""
  echo "  Host:    ${CHOSEN_HOST}"
  echo "  User:    ${CHOSEN_USER}"
  echo "  Local:   1"
  echo "  Config:  ${RC}"
  echo ""
  if (( MISSING )); then
    echo "Install the dependencies flagged above before running claudehome."
    echo ""
  fi
  echo "Open a new shell (or:  source ${SHELL_RC})"
  echo "Then run:  claudehome"
  echo ""
  echo "When you SSH into this mini from another device, claudehome runs"
  echo "the picker directly on this mini — no loopback SSH."
else
  echo "install: smoke test failed — claudehome --help returned non-zero." >&2
  echo "  Make sure ${TARGET_DIR} is in your PATH." >&2
  exit 1
fi
