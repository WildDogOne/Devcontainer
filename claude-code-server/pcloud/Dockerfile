# pCloud sync container, building lneely's fork of the pCloud console client:
# https://github.com/lneely/pcloudcc-lneely
#
# ASSUMPTIONS (unverified — this build could not reach the network to confirm
# the upstream README): the project builds via a top-level `build.sh` like the
# upstream pcloudcom/console-client it's forked from, falling back to a plain
# cmake build if that script isn't present. Adjust the RUN block below against
# the actual repo instructions if the build fails.
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    git \
    ca-certificates \
    zlib1g-dev \
    libssl-dev \
    libfuse3-dev \
    && rm -rf /var/lib/apt/lists/*

ARG PCLOUDCC_REPO=https://github.com/lneely/pcloudcc-lneely.git
ARG PCLOUDCC_REF=master

RUN git clone --recurse-submodules --depth 1 --branch "$PCLOUDCC_REF" "$PCLOUDCC_REPO" /usr/src/pcloudcc

WORKDIR /usr/src/pcloudcc
RUN if [ -x ./build.sh ]; then \
        ./build.sh; \
    else \
        cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(nproc)"; \
    fi \
    && find . -maxdepth 3 -type f -name 'pcloudcc*' -perm -u+x -exec install -Dm755 {} /usr/local/bin/pcloudcc \;

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    fuse3 \
    ca-certificates \
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
