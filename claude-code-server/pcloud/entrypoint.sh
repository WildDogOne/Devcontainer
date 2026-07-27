#!/bin/sh
# Verified against `pcloudcc -h`, main.cpp, pclsync_lib.cpp and pclsync/pdiff.c
# in lneely/pcloudcc-lneely:
# - `-p` is a boolean flag that prompts on stdin for the password; it does not
#   take a value. A container started with `docker compose up -d` has no TTY,
#   so we never pass -p here.
# - `-o` means "keep parent process alive and process commands", not
#   mountpoint. Mountpoint is `-m`.
# - `-d` daemonizes via double-fork: the process we launch prints "Daemon
#   process created. Process id is: <pid>" and immediately exits, while the
#   real daemon runs on as a detached grandchild (reparented to tini, since
#   docker-compose sets `init: true`). We can't just `wait` on the process we
#   launched - it's already gone. Instead we scrape the real daemon's pid out
#   of that startup line and poll it, so this script (the container's
#   supervised process) stays alive for as long as the real daemon does, and
#   so `cleanup` below signals the right process. pcloudcc registers its own
#   SIGINT/SIGTERM/SIGHUP handlers for a graceful unmount.
# - After a login saved with `-s`, the sync thread reads the session straight
#   out of ~/.pcloud/data.db (table `setting`, ids `auth`/`user`/`pass`)
#   before ever calling back into our code for a password - so a headless
#   restart with a saved session needs no PCLOUD_PASSWORD and never touches
#   stdin. That db only survives restarts because docker-compose.yml mounts
#   /home/pcloud as a volume.
# - Without a saved session, login (and any 2FA prompt) needs a real TTY, so
#   it can't happen from this non-interactive entrypoint - see README for the
#   one-time `docker compose run -it` login step.
set -eu

MOUNTPOINT="${PCLOUD_MOUNTPOINT:-/pcloud}"
mkdir -p "$MOUNTPOINT"

if [ -z "${PCLOUD_USERNAME:-}" ]; then
    echo "entrypoint: PCLOUD_USERNAME must be set" >&2
    exit 1
fi

DB="$HOME/.pcloud/data.db"
saved_auth=""
if [ -f "$DB" ]; then
    saved_auth=$(sqlite3 "$DB" \
        "SELECT value FROM setting WHERE id IN ('auth','pass') AND value <> '' LIMIT 1;" \
        2>/dev/null || true)
fi

if [ -z "$saved_auth" ] && [ -z "${PCLOUD_PASSWORD:-}" ]; then
    cat >&2 <<'EOF'
entrypoint: no saved pCloud session found in ~/.pcloud/data.db, and
PCLOUD_PASSWORD is not set.

Run the one-time interactive login first (needed to enter the password and,
if your account has 2FA, the one-time code):

    docker compose run --rm -it --entrypoint pcloudcc pcloud \
        -u "$PCLOUD_USERNAME" -p -s -m /pcloud

Once that succeeds, the saved session in the pcloud_home volume lets
`docker compose up -d` start headlessly without PCLOUD_PASSWORD.
EOF
    exit 1
fi

if [ -n "${PCLOUD_PASSWORD:-}" ]; then
    export PCLOUD_ACCOUNT_PASSWORD="$PCLOUD_PASSWORD"
    unset PCLOUD_PASSWORD
fi

startup_log="$(mktemp)"
pcloudcc -u "$PCLOUD_USERNAME" -m "$MOUNTPOINT" -d >"$startup_log" 2>&1
cat "$startup_log"
daemon_pid=$(sed -n 's/^Daemon process created\. Process id is: //p' "$startup_log" | tail -1)
rm -f "$startup_log"

if [ -z "$daemon_pid" ] || ! kill -0 "$daemon_pid" 2>/dev/null; then
    echo "entrypoint: pcloudcc daemon failed to start" >&2
    exit 1
fi

# `docker stop` only signals this script (PID 1), not the detached daemon, so
# forward the signal explicitly. pcloudcc registers its own SIGTERM/SIGINT
# handler for a graceful unmount (see doc/USAGE.md in the upstream repo:
# "do NOT use kill -9 ... can cause filesystem corruption"). Force-unmount
# only as a fallback if it doesn't exit on its own in time.
cleanup() {
    kill -TERM "$daemon_pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$daemon_pid" 2>/dev/null || return 0
        sleep 0.5
    done
    fusermount3 -u "$MOUNTPOINT" 2>/dev/null || fusermount -u "$MOUNTPOINT" 2>/dev/null || true
}
trap cleanup TERM INT

while kill -0 "$daemon_pid" 2>/dev/null; do
    sleep 5
done
