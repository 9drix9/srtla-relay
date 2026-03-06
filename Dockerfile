# SRTLA relay using irlserver/srtla (C++ receiver)
# Clean SRTLA proxy — compatible with IRL Pro, Moblin, and BELABOX.
#
# Upstream (irlserver/srtla) already includes:
#   - GCC 12 cstddef fix
#   - Cellular timeouts (GROUP_TIMEOUT=30s, CONN_TIMEOUT=15s)
#   - 32-byte UDP padding (pad_sendto)
#   - Handshake broadcast (Moblin fix)
#
# Patches still needed:
# PATCH 1: GCC 12 cstddef fix for nak_dedup.cpp
# PATCH 2: Disable ACK throttling — prevents bitrate oscillation
# PATCH 3: NAK broadcast fix — only broadcast ACKs+handshakes, not NAKs

FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential cmake libssl-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/irlserver/srtla.git /src

WORKDIR /src
RUN git submodule update --init --depth 1

# PATCH 1: GCC 12 fix — nak_dedup.cpp uses size_t but doesn't include <cstddef>
RUN sed -i '1i #include <cstddef>' src/utils/nak_dedup.cpp

# PATCH 2: Disable ACK throttling (load balancing)
RUN sed -i 's/load_balancing_enabled_ = true/load_balancing_enabled_ = false/' src/connection/connection_group.h
RUN grep -q 'load_balancing_enabled_ = false' src/connection/connection_group.h \
    || (echo 'ERROR: load balancing patch not applied!' && exit 1)

# PATCH 3: Only broadcast SRT ACKs + handshakes (not NAKs) — match BELABOX behavior
# Upstream broadcasts ACKs, NAKs, and handshakes. We remove NAKs from the broadcast.
RUN sed -i 's/is_srt_ack(buf, n) || is_srt_nak(buf, n) || is_srt_handshake(buf, n)/is_srt_ack(buf, n) || is_srt_handshake(buf, n)/' src/protocol/srt_handler.cpp
RUN ! grep -q 'is_srt_nak(buf, n)' src/protocol/srt_handler.cpp \
    || (echo 'ERROR: is_srt_nak still in broadcast condition!' && exit 1)

# Verify upstream patches are present
RUN grep -q 'pad_sendto' src/protocol/srtla_handler.cpp \
    || (echo 'ERROR: pad_sendto not found in srtla_handler — upstream changed?' && exit 1)
RUN grep -q 'is_srt_handshake' src/protocol/srt_handler.cpp \
    || (echo 'ERROR: is_srt_handshake not found — upstream changed?' && exit 1)
RUN grep -q 'GROUP_TIMEOUT = 30' src/receiver_config.h \
    || (echo 'ERROR: GROUP_TIMEOUT not 30 — upstream changed?' && exit 1)

# Build with CMake
RUN mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j$(nproc)

# Verify binary exists
RUN test -f build/srtla_rec

# --- Runtime ---
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates ncat && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/build/srtla_rec /usr/local/bin/srtla_rec
COPY start.sh /usr/local/bin/start.sh
RUN sed -i 's/\r$//' /usr/local/bin/start.sh && chmod +x /usr/local/bin/start.sh

ENTRYPOINT ["start.sh"]
