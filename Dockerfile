# SRTLA relay using irlserver/srtla (C++ receiver)
# Clean SRTLA proxy — compatible with IRL Pro, Moblin, and BELABOX.
#
# PATCH 1: GCC 12 fix — add missing #include <cstddef>
# PATCH 2: Cellular timeouts — GROUP_TIMEOUT 4→30s, CONN_TIMEOUT 4→15s
# PATCH 3: 32-byte padding — carrier NAT fix for all small sendto() calls
# PATCH 4: Disable ACK throttling — prevents bitrate oscillation
# PATCH 5: NAK broadcast fix — only broadcast ACKs, not NAKs (match BELABOX)
# PATCH 6: Handshake broadcast — broadcast SRT handshake to all connections (Moblin fix)

FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential cmake libssl-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/irlserver/srtla.git /src

WORKDIR /src
RUN git submodule update --init --depth 1

# PATCH 1: GCC 12 fix
RUN sed -i '1i #include <cstddef>' src/utils/nak_dedup.cpp
RUN head -1 src/utils/nak_dedup.cpp | grep -q 'cstddef' \
    || (echo 'ERROR: cstddef patch not applied!' && exit 1)

# PATCH 2: Increase timeouts for cellular resilience
RUN sed -i 's/GROUP_TIMEOUT = 4/GROUP_TIMEOUT = 30/' src/receiver_config.h && \
    sed -i 's/CONN_TIMEOUT = 4/CONN_TIMEOUT = 15/' src/receiver_config.h
RUN grep -q 'GROUP_TIMEOUT = 30' src/receiver_config.h \
    || (echo 'ERROR: GROUP_TIMEOUT patch not applied!' && exit 1)
RUN grep -q 'CONN_TIMEOUT = 15' src/receiver_config.h \
    || (echo 'ERROR: CONN_TIMEOUT patch not applied!' && exit 1)

# PATCH 3: Pad all small SRTLA response sendto() calls to minimum 32 bytes.
RUN cat > src/protocol/pad_sendto.h << 'ENDOFPATCH'
#pragma once
#include <cstring>
#include <sys/socket.h>
/* Pad small sendto() to 32 bytes to avoid carrier NAT drops on 2-byte packets */
static inline int pad_sendto(int sock, const void *buf, size_t len,
                             int flags, const struct sockaddr *addr, socklen_t alen) {
  unsigned char padded[32];
  if (len >= 32) return sendto(sock, buf, len, flags, addr, alen);
  memset(padded, 0, 32);
  memcpy(padded, buf, len);
  int ret = sendto(sock, padded, 32, flags, addr, alen);
  return (ret == 32) ? (int)len : ret;
}
ENDOFPATCH

# PATCH 4: Disable ACK throttling (load balancing)
RUN sed -i 's/load_balancing_enabled_ = true/load_balancing_enabled_ = false/' src/connection/connection_group.h
RUN grep -q 'load_balancing_enabled_ = false' src/connection/connection_group.h \
    || (echo 'ERROR: load balancing patch not applied!' && exit 1)

# PATCH 5: Only broadcast SRT ACKs (not NAKs) — match BELABOX srtla_rec behavior
RUN sed -i 's/is_srt_ack(buf, n) || is_srt_nak(buf, n)/is_srt_ack(buf, n)/' src/protocol/srt_handler.cpp
RUN grep -q 'is_srt_ack(buf, n)' src/protocol/srt_handler.cpp \
    || (echo 'ERROR: PATCH 5 NAK broadcast fix not applied!' && exit 1)
RUN ! grep -q 'is_srt_nak(buf, n)' src/protocol/srt_handler.cpp \
    || (echo 'ERROR: is_srt_nak still in broadcast condition!' && exit 1)

RUN sed -i '/#include "srtla_handler.h"/a #include "pad_sendto.h"' src/protocol/srtla_handler.cpp && \
    sed -i '/#include "srt_handler.h"/a #include "pad_sendto.h"' src/protocol/srt_handler.cpp && \
    sed -i 's/sendto(srtla_socket_,/pad_sendto(srtla_socket_,/g' src/protocol/srtla_handler.cpp && \
    sed -i 's/sendto(srtla_socket_,/pad_sendto(srtla_socket_,/g' src/protocol/srt_handler.cpp

# PATCH 6: Broadcast SRT handshake packets to all connections (Moblin fix)
# Without this, handshake responses go to last_address only, which is a race —
# whichever bonded connection sent a packet most recently wins. If the response
# goes to the wrong connection (stale NAT, reconnecting), the SRT handshake
# never completes on the client side and no media data flows.
# SRT Handshake = control bit (0x80) + type 0x00 = first 2 bytes are 0x80 0x00.
RUN sed -i '/#include "pad_sendto.h"/a \
static inline int is_srt_handshake(const void *pkt, int n) { \
    if (n < 16) return 0; \
    const unsigned char *p = (const unsigned char *)pkt; \
    return (p[0] == 0x80) && (p[1] == 0x00); \
}' src/protocol/srt_handler.cpp && \
    sed -i 's/is_srt_ack(buf, n)/is_srt_ack(buf, n) || is_srt_handshake(buf, n)/' src/protocol/srt_handler.cpp
RUN grep -q 'is_srt_handshake' src/protocol/srt_handler.cpp \
    || (echo 'ERROR: PATCH 6 handshake broadcast not applied!' && exit 1)

# Verify patches
RUN grep -q 'pad_sendto' src/protocol/srtla_handler.cpp \
    || (echo 'ERROR: pad_sendto not found in srtla_handler!' && exit 1)
RUN ! grep -Pn '(?<!pad_)sendto\(srtla_socket_,' src/protocol/srtla_handler.cpp \
    || (echo 'ERROR: unpatched sendto in srtla_handler!' && exit 1)

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
