#!/bin/sh
set -e

LISTEN_PORT="${RELAY_LISTEN_PORT:-5000}"
TARGET_HOST="${RELAY_TARGET_HOST:?RELAY_TARGET_HOST is required}"
TARGET_SRT_PORT="${RELAY_TARGET_SRT_PORT:-8890}"
HEALTH_PORT="${RELAY_HEALTH_PORT:-8080}"
DNS_CHECK_INTERVAL="${RELAY_DNS_CHECK_INTERVAL:-30}"

# Background HTTP health check — returns 200 OK so UptimeRobot can monitor
health_server() {
  RESPONSE="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
  while true; do
    printf "$RESPONSE" | ncat -l -p "$HEALTH_PORT" --send-only >/dev/null 2>&1 || true
  done
}
if [ "$HEALTH_PORT" != "0" ]; then
  health_server &
  echo "health check: http://0.0.0.0:${HEALTH_PORT}"
fi

# Resolve hostname to IP address
resolve_host() {
  getent hosts "$1" 2>/dev/null | awk '{print $1}' | head -1
}

CURRENT_IP=$(resolve_host "$TARGET_HOST")
echo "srtla relay: listening on :${LISTEN_PORT}, forwarding to ${TARGET_HOST}:${TARGET_SRT_PORT} (${CURRENT_IP})"

# Start srtla_rec in background (not exec) so we can monitor DNS changes
# Pass resolved IP instead of hostname to avoid stale DNS cache in srtla_rec
srtla_rec --srtla_port "$LISTEN_PORT" \
          --srt_hostname "$CURRENT_IP" \
          --srt_port "$TARGET_SRT_PORT" \
          --log_level info &
SRTLA_PID=$!

# Forward SIGTERM/SIGINT to srtla_rec for clean container shutdown
trap 'kill "$SRTLA_PID" 2>/dev/null; wait "$SRTLA_PID" 2>/dev/null; exit 0' TERM INT

# Monitor DNS and restart srtla_rec if ingest IP changes
while true; do
  sleep "$DNS_CHECK_INTERVAL" &
  wait $! 2>/dev/null || true

  # Check if srtla_rec crashed — restart it
  if ! kill -0 "$SRTLA_PID" 2>/dev/null; then
    echo "srtla_rec exited unexpectedly, restarting"
    CURRENT_IP=$(resolve_host "$TARGET_HOST")
    srtla_rec --srtla_port "$LISTEN_PORT" \
              --srt_hostname "$CURRENT_IP" \
              --srt_port "$TARGET_SRT_PORT" \
              --log_level info &
    SRTLA_PID=$!
    continue
  fi

  # Check if DNS changed — restart srtla_rec to pick up new IP
  NEW_IP=$(resolve_host "$TARGET_HOST")
  if [ -n "$NEW_IP" ] && [ "$NEW_IP" != "$CURRENT_IP" ]; then
    echo "DNS change detected: ${CURRENT_IP} -> ${NEW_IP}, restarting srtla_rec"
    CURRENT_IP="$NEW_IP"
    kill "$SRTLA_PID" 2>/dev/null || true
    wait "$SRTLA_PID" 2>/dev/null || true
    srtla_rec --srtla_port "$LISTEN_PORT" \
              --srt_hostname "$CURRENT_IP" \
              --srt_port "$TARGET_SRT_PORT" \
              --log_level info &
    SRTLA_PID=$!
  fi
done
