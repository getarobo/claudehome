#!/usr/bin/env bash
# install.sh — symlink bin/claudehome into a PATH directory.
#   Default target: ~/.local/bin (no sudo).
#   Override:       ./install.sh --system   (uses sudo to target /usr/local/bin)

set -euo pipefail

# SC2155-clean: declare first, then assign so `cd`/`pwd` failures are not
# masked by the declaration's exit code.
REPO_DIR=
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -z "$REPO_DIR" ]]; then
  echo "install: cannot resolve repository directory." >&2
  exit 1
fi
SRC="${REPO_DIR}/bin/claudehome"

if [[ ! -x "$SRC" ]]; then
  chmod +x "$SRC" 2>/dev/null || {
    echo "install: ${SRC} not found or not executable." >&2
    exit 1
  }
fi

SYSTEM=0
for arg in "$@"; do
  case "$arg" in
    --system) SYSTEM=1 ;;
    -h|--help)
      echo "Usage: ./install.sh [--system]"
      echo "  --system   Install to /usr/local/bin (requires sudo)"
      exit 0
      ;;
    *) echo "install: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

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
  case ":$PATH:" in
    *":${TARGET_DIR}:"*) : ;;
    *) echo "  warning: ${TARGET_DIR} is not in your PATH."
       echo "  add this to your shell rc:  export PATH=\"${TARGET_DIR}:\$PATH\"" ;;
  esac
fi

if "$LINK" --help >/dev/null 2>&1; then
  echo "install: done. Run:  claudehome"
else
  echo "install: symlink created but \`claudehome --help\` failed; check PATH." >&2
  exit 1
fi
