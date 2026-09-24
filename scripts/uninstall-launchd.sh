#!/usr/bin/env bash
# Unload and remove the Shortcut→Trello reconciler LaunchAgent.
# Usage: ./scripts/uninstall-launchd.sh

set -euo pipefail

LABEL="com.aukoyy.shortcut-trello-reconcile"
DEST_PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

if launchctl print "${DOMAIN}/${LABEL}" &>/dev/null; then
  launchctl bootout "${DOMAIN}/${LABEL}" || true
  echo "Unloaded: ${DOMAIN}/${LABEL}"
else
  echo "Job not loaded: ${DOMAIN}/${LABEL}"
fi

if [[ -f "$DEST_PLIST" ]]; then
  rm -f "$DEST_PLIST"
  echo "Removed: $DEST_PLIST"
else
  echo "Plist already absent: $DEST_PLIST"
fi

echo "Done. Log file left in place: ${HOME}/Library/Logs/shortcut-trello-reconcile.log"
