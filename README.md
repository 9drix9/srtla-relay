# srtla-relay

Lightweight SRTLA relay server for IRL streaming. Deploy close to your streamers to reduce latency and improve cellular bonding reliability.

```
Phone (IRL Pro / Moblin) → SRTLA → Relay → SRT → Ingest Server
```

## Features

- **DNS change monitoring** — Automatically detects when the ingest server IP changes (e.g., from auto-scaling) and restarts the relay with the new IP. No manual intervention needed.
- **Health check endpoint** — Built-in HTTP health check on port 8080 for uptime monitoring (UptimeRobot, etc.).
- **Crash recovery** — Monitors srtla_rec and auto-restarts if it exits unexpectedly.
- **Multi-port** — Run multiple instances on different ports for concurrent streams.

## Patches

This builds [irlserver/srtla](https://github.com/irlserver/srtla) with 6 patches for production cellular streaming:

| # | Patch | Problem |
|---|-------|---------|
| 1 | GCC 12 fix | Missing `#include <cstddef>` breaks compilation on modern distros |
| 2 | Cellular timeouts | Default 4s timeouts too aggressive for cellular handovers (→ 30s group, 15s conn) |
| 3 | 32-byte UDP padding | T-Mobile and other carrier NATs drop 2-byte UDP packets. SRTLA registration responses (REG3/REG_NGP/REG_ERR) are only 2 bytes — padding to 32 bytes fixes connection failures. |
| 4 | Disable ACK throttling | Load balancing causes bitrate oscillation on bonded connections |
| 5 | NAK broadcast fix | Only broadcast ACKs to all connections, not NAKs (matches BELABOX behavior) |
| 6 | Handshake broadcast | Broadcast SRT handshake responses to all bonded connections. Without this, handshake goes to whichever connection sent a packet last — a race condition that causes Moblin to never complete the SRT handshake. |

## Quick Start

```bash
git clone https://github.com/9drix9/srtla-relay.git
cd srtla-relay

# Point at your ingest server
RELAY_TARGET_HOST=ingest.example.com docker compose up -d
```

Then configure your streaming app to connect to `srtla://relay-ip:5000`.

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RELAY_TARGET_HOST` | Yes | — | Hostname or IP of your ingest/SRT server |
| `RELAY_TARGET_SRT_PORT` | No | `8890` | SRT port on the ingest server |
| `RELAY_LISTEN_PORT` | No | `5000` | SRTLA listen port on this relay |
| `RELAY_HEALTH_PORT` | No | `8080` | HTTP health check port (set to `0` to disable) |
| `RELAY_DNS_CHECK_INTERVAL` | No | `30` | Seconds between DNS change checks |

## How It Works

The relay runs `srtla_rec` which:
1. Listens for SRTLA connections from streaming apps (IRL Pro, Moblin, BELABOX)
2. Reassembles bonded cellular connections into a single SRT stream
3. Forwards the SRT stream to your ingest server

The wrapper script (`start.sh`) adds:
- **DNS monitoring**: Every 30s, resolves the target hostname. If the IP changed, restarts srtla_rec with the new IP. This prevents stale connections when your ingest server's IP changes.
- **Crash recovery**: If srtla_rec exits unexpectedly, it's restarted automatically.
- **Health checks**: HTTP endpoint returns 200 OK for uptime monitoring.

## Multiple Ports

Each srtla_rec instance handles one concurrent stream per port. The included `docker-compose.yml` runs 5 instances on ports 5000-5004. Add more services for additional capacity:

```yaml
  srtla6:
    build: .
    network_mode: host
    environment:
      - RELAY_TARGET_HOST=${RELAY_TARGET_HOST}
      - RELAY_TARGET_SRT_PORT=${RELAY_TARGET_SRT_PORT:-8890}
      - RELAY_LISTEN_PORT=5005
      - RELAY_HEALTH_PORT=0
    restart: unless-stopped
```

## Streamer Setup

In your streaming app, replace the ingest server address with the relay:

```
srtla://relay-ip:5000
```

Stream keys and authentication pass through transparently — no configuration needed on the relay.

## Compatible Apps

- [IRL Pro](https://apps.apple.com/app/irl-pro/id1539620252) (iOS)
- [Moblin](https://github.com/niclasberg/moblin) (iOS)
- [BELABOX](https://belabox.net/)
- Any SRTLA-compatible encoder

## License

MIT
