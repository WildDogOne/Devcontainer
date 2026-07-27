# pCloud sync container, building lneely's fork of the pCloud console client:
# https://github.com/lneely/pcloudcc-lneely
#
# The project builds with a plain `make` (no cmake/build.sh — see doc/BUILD.md
# in that repo) and requires mbedtls 3.x, which Debian bookworm doesn't ship
# (only 2.28). Debian trixie carries mbedtls 3.6, so both build and runtime
# stages use trixie-slim instead of pulling mbedtls from source.
FROM debian:trixie-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    git \
    ca-certificates \
    zlib1g-dev \
    libfuse3-dev \
    libmbedtls-dev \
    libsqlite3-dev \
    libreadline-dev \
    libudev-dev \
    && rm -rf /var/lib/apt/lists/*

ARG PCLOUDCC_REPO=https://github.com/lneely/pcloudcc-lneely.git
ARG PCLOUDCC_REF=main

RUN git clone --recurse-submodules --depth 1 --branch "$PCLOUDCC_REF" "$PCLOUDCC_REPO" /usr/src/pcloudcc

WORKDIR /usr/src/pcloudcc
RUN make -j"$(nproc)" && install -Dm755 pcloudcc /usr/local/bin/pcloudcc

FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    fuse3 \
    ca-certificates \
    libmbedtls21 \
    libmbedcrypto16 \
    libmbedx509-7 \
    libsqlite3-0 \
    libreadline8t64 \
    libudev1 \
    zlib1g \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/* \
    && echo "user_allow_other" >> /etc/fuse.conf

# Must match the claude-code container's USER_UID/USER_GID (see ../Dockerfile
# and docker-compose.yml) so files synced here and files created by Claude
# Code share ownership on any bind-mounted directory both containers touch.
ARG USERNAME=pcloud
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd -g "$USER_GID" "$USERNAME" \
    && useradd -m -u "$USER_UID" -g "$USER_GID" -s /bin/sh "$USERNAME"

COPY --from=build /usr/local/bin/pcloudcc /usr/local/bin/pcloudcc
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# FUSE mounting needs /dev/fuse (passed through via the `devices:` key in
# docker-compose.yml) plus CAP_SYS_ADMIN at the container level.
RUN mkdir -p /pcloud && chown "$USERNAME:$USERNAME" /pcloud
USER $USERNAME
WORKDIR /home/$USERNAME

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
