#!/usr/bin/env bash
# Install and load the Shortcut→Trello reconciler as a user LaunchAgent.
# Usage: ./scripts/install-launchd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.aukoyy.shortcut-trello-reconcile"
SRC_PLIST="$REPO_ROOT/launchd/${LABEL}.plist"
DEST_DIR="${HOME}/Library/LaunchAgents"
DEST_PLIST="${DEST_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

if [[ ! -f "$SRC_PLIST" ]]; then
  echo "error: missing plist: $SRC_PLIST" >&2
  exit 1
fi

if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo "error: .env not found at $REPO_ROOT/.env" >&2
  echo "Copy .env.example → .env and fill credentials before installing." >&2
  exit 1
fi

if [[ ! -x "$REPO_ROOT/reconcile.sh" ]]; then
  chmod +x "$REPO_ROOT/reconcile.sh"
fi

mkdir -p "$DEST_DIR" "$LOG_DIR"

# Unload existing job if present (ignore failures — may not be loaded yet).
if launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; then
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
fi

cp "$SRC_PLIST" "$DEST_PLIST"
chmod 644 "$DEST_PLIST"

launchctl bootstrap "$DOMAIN" "$DEST_PLIST"
launchctl enable "${DOMAIN}/${LABEL}" || true
launchctl kickstart -k "${DOMAIN}/${LABEL}"

echo "Installed and started: ${LABEL}"
echo "  plist:  $DEST_PLIST"
echo "  logs:   ${LOG_DIR}/shortcut-trello-reconcile.log"
echo "  check:  launchctl print ${DOMAIN}/${LABEL}"
