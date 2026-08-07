#!/bin/sh
# Builds the claudecontainer image. --network host: this host's Docker bridge network
# can't reach DNS/the internet at all (corporate firewall), so the build itself needs
# to run directly on the host network, same as the container does at runtime
# (see entrypoint.sh/run.sh).
set -eu
cd "$(dirname "$0")"
docker build --network host -t claudecontainer:latest .
