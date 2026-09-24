#!/bin/sh
# Pushes Gluetun's current forwarded port into qBittorrent.
#
# Runs in Gluetun's network namespace, so qBittorrent's WebUI is on
# localhost. No credentials are sent: qBittorrent must have "Bypass
# authentication for clients on localhost" enabled (Options > WebUI).
PORT_FILE="/gluetun/forwarded_port"
QBIT="http://localhost:8080"
LAST=""

echo "[port-sync] starting"
while true; do
  if [ -f "$PORT_FILE" ]; then
    PORT=$(cat "$PORT_FILE" 2>/dev/null)
    if [ -n "$PORT" ] && [ "$PORT" != "$LAST" ]; then
      if curl -sf "$QBIT/api/v2/app/setPreferences" \
           --data "json={\"listen_port\":$PORT}" >/dev/null; then
        echo "[port-sync] qBittorrent listen port set to $PORT"
        LAST="$PORT"
      else
        echo "[port-sync] update failed (qBittorrent not ready?), retrying"
      fi
    fi
  else
    echo "[port-sync] no forwarded port file yet, waiting"
  fi
  sleep 30
done
