#!/usr/bin/env bash
# install_client.sh — install claudehome Mac client and run first-time setup wizard.
#   Default target: ~/.local/bin (no sudo).
#   Override:       ./install_client.sh --system   (uses sudo to target /usr/local/bin)
#
# Re-running this script is safe: prompts are skipped for values already saved
# in ~/.claudehomerc or set in the environment.

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
      echo "Usage: ./install_client.sh [--system]"
      echo "  --system   Install to /usr/local/bin (requires sudo)"
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

# ── Step 2: ensure TARGET_DIR is on PATH in shell rc ────────────────────────
if ! (( SYSTEM )); then
  # Pick the right rc file based on the active shell
  SHELL_RC="${HOME}/.zshrc"
  [[ "${SHELL:-}" == */bash ]] && SHELL_RC="${HOME}/.bashrc"
  if ! grep -qF "${TARGET_DIR}" "$SHELL_RC" 2>/dev/null; then
    {
      echo ""
      echo "# added by claudehome install"
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

_tailscale_peers() {
  "$TAILSCALE" status 2>/dev/null \
    | awk 'NR>1 { print $2 }' \
    | grep -v '^$' \
    | head -10 \
    || true
}

# ── Step 3: Tailscale check ──────────────────────────────────────────────────
echo ""
echo "── Checking Tailscale ──────────────────────────────────────────────────────"
# macOS GUI install puts the binary in the app bundle, not on PATH.
TAILSCALE=tailscale
if ! command -v tailscale >/dev/null 2>&1; then
  if [[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
    TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  else
    echo "install: Tailscale not found."
    echo "  1. Download and install: https://tailscale.com/download"
    echo "  2. Log in to the same Tailscale account you use on the Mac mini."
    echo "  3. Re-run: ./install_client.sh"
    open "https://tailscale.com/download" 2>/dev/null || true
    exit 0
  fi
fi
if ! "$TAILSCALE" status >/dev/null 2>&1; then
  echo "install: Tailscale is installed but not logged in or not running."
  echo "  Open the Tailscale menu bar app and log in, then re-run: ./install_client.sh"
  exit 0
fi
echo "install: Tailscale is running. ✓"

# ── Clear stale shell-rc exports (config file is now the source of truth) ────
for var in CLAUDEHOME_HOST CLAUDEHOME_USER CLAUDEHOME_PROJECTS_DIR; do
  # Unset from the current session immediately.
  unset "$var" 2>/dev/null || true
  # Remove any `export CLAUDEHOME_*=...` lines from the shell rc.
  if grep -qE "^export ${var}=" "$SHELL_RC" 2>/dev/null; then
    _tmp=$(mktemp)
    grep -v "^export ${var}=" "$SHELL_RC" > "$_tmp"
    mv "$_tmp" "$SHELL_RC"
    echo "install: removed stale 'export ${var}' from ${SHELL_RC} (now read from ${RC})."
  fi
done

# ── Step 4: init config file ─────────────────────────────────────────────────
if [[ ! -f "$RC" ]]; then
  cat > "$RC" <<'EOF'
# claudehome config — written by install_client.sh
# Environment variables take precedence over this file.
EOF
  echo "install: created ${RC}"
fi

echo ""
echo "── Mac mini configuration ──────────────────────────────────────────────────"

# ── Step 5: CLAUDEHOME_HOST ──────────────────────────────────────────────────
EXISTING_HOST="${CLAUDEHOME_HOST:-$(_rc_get CLAUDEHOME_HOST)}"
if [[ -n "$EXISTING_HOST" ]]; then
  echo "install: CLAUDEHOME_HOST already set to '${EXISTING_HOST}' — skipping."
  CHOSEN_HOST="$EXISTING_HOST"
else
  PEERS=$(_tailscale_peers)
  if [[ -n "$PEERS" ]]; then
    echo "Tailscale peers (pick one):"
    echo "$PEERS" | sed 's/^/  /'
  fi
  read -r -p "Enter Mac mini Tailscale hostname: " CHOSEN_HOST
  if [[ -z "$CHOSEN_HOST" ]]; then
    echo "install: hostname required." >&2
    exit 1
  fi
  _rc_set CLAUDEHOME_HOST "$CHOSEN_HOST"
  echo "install: saved CLAUDEHOME_HOST=${CHOSEN_HOST}"
fi

# ── Step 6: CLAUDEHOME_USER ──────────────────────────────────────────────────
EXISTING_USER="${CLAUDEHOME_USER:-$(_rc_get CLAUDEHOME_USER)}"
if [[ -n "$EXISTING_USER" ]]; then
  echo "install: CLAUDEHOME_USER already set to '${EXISTING_USER}' — skipping."
  CHOSEN_USER="$EXISTING_USER"
else
  read -r -p "Enter Mac mini SSH username (default: ${USER}): " CHOSEN_USER
  CHOSEN_USER="${CHOSEN_USER:-$USER}"
  _rc_set CLAUDEHOME_USER "$CHOSEN_USER"
  echo "install: saved CLAUDEHOME_USER=${CHOSEN_USER}"
fi

# ── Step 7: fzf (optional) ───────────────────────────────────────────────────
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

# ── Smoke test + summary ──────────────────────────────────────────────────────
echo ""
if "$LINK" --help >/dev/null 2>&1; then
  echo "────────────────────────────────────────────────────────────────────────────"
  echo "claudehome installed."
  echo ""
  echo "  Host:    ${CHOSEN_HOST}"
  echo "  User:    ${CHOSEN_USER}"
  echo "  Config:  ${RC}"
  echo ""
  echo "Next: authorize an SSH key on ${CHOSEN_HOST}."
  echo ""
  if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    echo "  Append your public key to ~/.ssh/authorized_keys on the Mac mini"
    echo "  (will prompt for the Mac account password):"
    echo ""
    echo "    ssh-copy-id ${CHOSEN_USER}@${CHOSEN_HOST}"
  else
    echo "  Generate an SSH key first (press Enter twice for no passphrase):"
    echo ""
    echo "    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C \"\$(hostname -s)\""
    echo ""
    echo "  Then copy it to the Mac mini:"
    echo ""
    echo "    ssh-copy-id ${CHOSEN_USER}@${CHOSEN_HOST}"
  fi
  echo ""
  echo "Verify:"
  echo "  ssh -o BatchMode=yes ${CHOSEN_USER}@${CHOSEN_HOST} echo ok    # must print: ok"
  echo ""
  echo "Then run:  claudehome"
else
  echo "install: smoke test failed — claudehome --help returned non-zero." >&2
  echo "  Make sure ${TARGET_DIR} is in your PATH." >&2
  exit 1
fi
