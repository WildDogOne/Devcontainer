#!/bin/sh
# Builds the claudecontainer image. --network host: this host's Docker bridge network
# can't reach DNS/the internet at all (corporate firewall), so the build itself needs
# to run directly on the host network, same as the container does at runtime
# (see entrypoint.sh/run.sh).
set -eu
cd "$(dirname "$0")"
docker build --no-cache --network host -t  claudecontainer:latest .

# --no-cache means every rebuild produces a brand-new image and dangles whatever
# claudecontainer:latest pointed at before (docker moves the tag, not the image). Those
# pile up fast since nothing else references them. The `project=claudecontainer` label
# (see Dockerfile) scopes this prune to our own leftovers, not unrelated dangling images
# elsewhere on the host. run.sh always runs containers with --rm, so no stopped
# containers should be left to clean up here.
docker image prune -f --filter "label=project=claudecontainer" --filter "dangling=true" >/dev/null
