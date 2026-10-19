#!/usr/bin/env bash
# Remove ModelMatrix from this Mac.
#   ./Scripts/uninstall.sh          remove the app, controller, CLI and completions; keep profiles and usage history
#   ./Scripts/uninstall.sh --purge  also delete profiles, usage history and settings
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SYSTEM_APPLICATIONS_DIR="/Applications"
BUNDLE_ID="io.github.hackstar1337.modelmatrix.app"
CONTROLLER_LABEL="io.github.hackstar1337.modelmatrix.controller"
SUPPORT_DIR="$HOME/Library/Application Support/ModelMatrix"
PURGE=0

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help)
      sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

# Quit the app first, then any controller it left behind.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -f 'ModelMatrix(\.app/Contents/MacOS/ModelMatrix|App)' >/dev/null 2>&1 || true
pkill -f 'ModelMatrixController serve' >/dev/null 2>&1 || true

# A controller registered as a launch agent (headless installs).
launchctl bootout "gui/$(id -u)/$CONTROLLER_LABEL" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$CONTROLLER_LABEL.plist"

rm -rf "$ROOT_DIR/dist/ModelMatrix.app"
rm -rf "${INSTALL_DIR:?}/ModelMatrix.app"
if [ -w "$SYSTEM_APPLICATIONS_DIR" ]; then
  rm -rf "${SYSTEM_APPLICATIONS_DIR:?}/ModelMatrix.app"
fi

rm -f "$BIN_DIR/modelmatrixctl"
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/modelmatrixctl"
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions/_modelmatrixctl"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions/modelmatrixctl.fish"

# cfprefsd caches preferences in memory; deleting only the plist would let a
# reinstall read the old values back. `defaults delete` clears the cache too.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults delete "$BUNDLE_ID.widget" >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
rm -f "$HOME/Library/Preferences/$BUNDLE_ID.widget.plist"
rm -rf "$HOME/Library/Containers/$BUNDLE_ID.widget"
rm -rf "$HOME/Library/Application Scripts/$BUNDLE_ID.widget"

printf 'removed=%s\n' "$INSTALL_DIR/ModelMatrix.app"
if [ "$PURGE" -eq 1 ]; then
  rm -rf "${SUPPORT_DIR:?}"
  printf 'purged=%s\n' "$SUPPORT_DIR"
else
  printf 'kept=%s (profiles and usage history; rerun with --purge to delete)\n' "$SUPPORT_DIR"
fi
