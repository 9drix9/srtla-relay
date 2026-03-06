#!/bin/sh
set -e

LISTEN_PORT="${RELAY_LISTEN_PORT:-5000}"
TARGET_HOST="${RELAY_TARGET_HOST:?RELAY_TARGET_HOST is required}"
TARGET_SRT_PORT="${RELAY_TARGET_SRT_PORT:-8890}"
HEALTH_PORT="${RELAY_HEALTH_PORT:-8080}"
DNS_CHECK_INTERVAL="${RELAY_DNS_CHECK_INTERVAL:-30}"
# Periodically recycle srtla_rec to refresh upstream SRT connection.
# The upstream connection goes stale after long idle periods, causing
# new client connections to fail silently.
KEEPALIVE_INTERVAL="${RELAY_KEEPALIVE_INTERVAL:-300}"

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

# Start or restart srtla_rec with current resolved IP
start_srtla() {
  CURRENT_IP=$(resolve_host "$TARGET_HOST")
  srtla_rec --srtla_port "$LISTEN_PORT" \
            --srt_hostname "$CURRENT_IP" \
            --srt_port "$TARGET_SRT_PORT" \
            --log_level info &
  SRTLA_PID=$!
}

CURRENT_IP=$(resolve_host "$TARGET_HOST")
echo "srtla relay: listening on :${LISTEN_PORT}, forwarding to ${TARGET_HOST}:${TARGET_SRT_PORT} (${CURRENT_IP})"

# Start srtla_rec in background (not exec) so we can monitor DNS changes
# Pass resolved IP instead of hostname to avoid stale DNS cache in srtla_rec
start_srtla

# Forward SIGTERM/SIGINT to srtla_rec for clean container shutdown
trap 'kill "$SRTLA_PID" 2>/dev/null; wait "$SRTLA_PID" 2>/dev/null; exit 0' TERM INT

# Monitor DNS, upstream health, and restart srtla_rec as needed
ELAPSED=0
while true; do
  sleep "$DNS_CHECK_INTERVAL" &
  wait $! 2>/dev/null || true
  ELAPSED=$((ELAPSED + DNS_CHECK_INTERVAL))

  # Check if srtla_rec crashed — restart it
  if ! kill -0 "$SRTLA_PID" 2>/dev/null; then
    echo "srtla_rec exited unexpectedly, restarting"
    start_srtla
    ELAPSED=0
    continue
  fi

  # Check if DNS changed — restart srtla_rec to pick up new IP
  NEW_IP=$(resolve_host "$TARGET_HOST")
  if [ -n "$NEW_IP" ] && [ "$NEW_IP" != "$CURRENT_IP" ]; then
    echo "DNS change detected: ${CURRENT_IP} -> ${NEW_IP}, restarting srtla_rec"
    CURRENT_IP="$NEW_IP"
    kill "$SRTLA_PID" 2>/dev/null || true
    wait "$SRTLA_PID" 2>/dev/null || true
    start_srtla
    ELAPSED=0
    continue
  fi

  # Keepalive: recycle srtla_rec to refresh upstream SRT connection.
  # The upstream SRT connection can go stale after long idle periods
  # (no active streams). srtla_rec stays alive but can't forward data.
  # Restart is sub-second; SRTLA clients reconnect automatically.
  if [ "$ELAPSED" -ge "$KEEPALIVE_INTERVAL" ]; then
    echo "keepalive: recycling srtla_rec (upstream idle ${ELAPSED}s)"
    kill "$SRTLA_PID" 2>/dev/null || true
    wait "$SRTLA_PID" 2>/dev/null || true
    start_srtla
    ELAPSED=0
  fi
done
