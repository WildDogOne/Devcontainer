#!/bin/sh
# ASSUMPTIONS (unverified against the actual `pcloudcc --help` output — see
# the note in ../Dockerfile): flags below follow the upstream
# pcloudcom/console-client convention (-u user, -p password, -o mountpoint,
# foreground/no-daemonize so container process supervision works). Confirm
# against the real binary and adjust.
set -eu

MOUNTPOINT="${PCLOUD_MOUNTPOINT:-/pcloud}"
mkdir -p "$MOUNTPOINT"

if [ -z "${PCLOUD_USERNAME:-}" ] || [ -z "${PCLOUD_PASSWORD:-}" ]; then
    echo "entrypoint: PCLOUD_USERNAME and PCLOUD_PASSWORD must be set" >&2
    exit 1
fi

cleanup() {
    fusermount3 -u "$MOUNTPOINT" 2>/dev/null || fusermount -u "$MOUNTPOINT" 2>/dev/null || true
}
trap cleanup TERM INT

pcloudcc -u "$PCLOUD_USERNAME" -p "$PCLOUD_PASSWORD" -o "$MOUNTPOINT" &
pid=$!
wait "$pid"
