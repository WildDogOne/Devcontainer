#!/bin/sh
# Builds and tags the dev container image directly via the Docker CLI, bypassing
# PyCharm's own devcontainer builder (which mishandles --network=host - see
# README.md "Building the image" section). Run this after any change to
# Dockerfile, squid.conf, or allowed-domains.txt, then reopen/rebuild in PyCharm.
set -e
cd "$(dirname "$0")"
docker build --network=host -t claude-code-devcontainer:latest -f Dockerfile .
