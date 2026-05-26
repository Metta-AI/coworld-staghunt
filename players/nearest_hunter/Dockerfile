# Build Docker.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/cogame-staghunt
COPY nimby.lock .
RUN nimby sync nimby.lock && \
  nimby install https://github.com/Metta-AI/bitworld.git

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
ARG NimCommand="c"
ARG NimMain="players/nearest_hunter/nearest_hunter.nim"
RUN nim $NimCommand \
  $NimFlags \
  --path:src \
  --nimcache:/tmp/cogame-nimcache \
  --out:/bin/nearest_hunter \
  $NimMain

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 && \
  rm -rf /var/lib/apt/lists/*

COPY --from=build /bin/nearest_hunter /bin/nearest_hunter

CMD ["/bin/nearest_hunter", "--address:host.docker.internal", "--port:8080"]
