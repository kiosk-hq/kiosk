#!/bin/sh
# install.sh — POSIX installer for the kiosk CLI.
#
# Production usage (once kiosk.tech is live):
#   curl -fsSL https://kiosk.tech/kiosk | sh
#
# Local dev usage (from this monorepo checkout):
#   ./kiosk-cli/install.sh
#
# Env overrides:
#   KIOSK_INSTALL_URL  — alternate binary source URL
#   KIOSK_INSTALL_DIR  — alternate destination directory (default: $XDG_BIN_HOME
#                        or ~/.local/bin)

set -eu

URL="${KIOSK_INSTALL_URL:-https://kiosk.tech/kiosk}"

resolve_dest_dir() {
  if [ -n "${KIOSK_INSTALL_DIR-}" ]; then
    printf '%s' "$KIOSK_INSTALL_DIR"
    return
  fi
  if [ -n "${XDG_BIN_HOME-}" ]; then
    printf '%s' "$XDG_BIN_HOME"
    return
  fi
  printf '%s/.local/bin' "$HOME"
}

DEST_DIR=$(resolve_dest_dir)
DEST="$DEST_DIR/kiosk"

mkdir -p "$DEST_DIR" || {
  printf 'install failed: cannot create %s\n' "$DEST_DIR" >&2
  exit 1
}

# Source detection: when invoked directly with a script path that has a
# sibling `bin/kiosk`, copy from there. When piped through `sh` (e.g.,
# `curl ... | sh`), `$0` is the shell name and the sibling lookup fails;
# we then fall through to the network download branch.
LOCAL_BIN=""
case "${0-}" in
  /*|./*|../*|*/*)
    SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    if [ -n "${SCRIPT_DIR-}" ] && [ -f "$SCRIPT_DIR/bin/kiosk" ]; then
      LOCAL_BIN="$SCRIPT_DIR/bin/kiosk"
    fi
    ;;
esac

if [ -n "$LOCAL_BIN" ]; then
  printf 'installing kiosk from local checkout: %s\n' "$LOCAL_BIN"
  cp "$LOCAL_BIN" "$DEST"
else
  printf 'downloading kiosk from %s\n' "$URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$DEST" || {
      printf 'install failed: curl could not fetch %s\n' "$URL" >&2
      exit 1
    }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$DEST" "$URL" || {
      printf 'install failed: wget could not fetch %s\n' "$URL" >&2
      exit 1
    }
  else
    printf 'install failed: neither curl nor wget on PATH\n' >&2
    exit 1
  fi
fi

chmod +x "$DEST"

if "$DEST" --version >/dev/null 2>&1; then
  installed_version=$("$DEST" --version)
  printf '\n  \033[1;32m✓\033[0m installed: %s -> %s\n' "$installed_version" "$DEST"
else
  printf 'install failed: %s does not run (missing curl/jq?)\n' "$DEST" >&2
  exit 1
fi

case ":${PATH-}:" in
  *":$DEST_DIR:"*) ;;
  *)
    printf '\n  \033[1;33m⚠\033[0m %s is not on your PATH\n' "$DEST_DIR"
    printf '    Add this to your shell rc:\n      export PATH="%s:$PATH"\n' "$DEST_DIR"
    ;;
esac

printf '\nrun  `kiosk --help`  to get started.\n'
