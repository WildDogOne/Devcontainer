#!/bin/sh
# Container entrypoint. Runs as root (needed to start dockerd/squid below), then drops
# to dev and execs the command docker run was given (default: an interactive `claude`
# session) - no persistent daemon, no listening port; the container exits when that
# command does. Meant to be started fresh per session via run.sh, not left running.
set -eu

# Egress allowlist proxy first, so dockerd's own image pulls go through it too. /etc/
# environment (see Dockerfile) covers the `sudo` session below via PAM but not this
# script's own process tree, hence the explicit export here for dockerd's benefit. Both
# casings matter: curl, git, wget, and Go's net/http (dockerd's own client) deliberately
# only honor lowercase http_proxy for plain http:// requests - the standard httpoxy-CVE
# mitigation - so uppercase-only silently bypassed the proxy for anything not using
# https. HTTPS_PROXY itself is read case-insensitively by all of the above, so that half
# was already fine.
export HTTP_PROXY=http://127.0.0.1:3128
export HTTPS_PROXY=http://127.0.0.1:3128
export NO_PROXY=localhost,127.0.0.1
export http_proxy=$HTTP_PROXY
export https_proxy=$HTTPS_PROXY
export no_proxy=$NO_PROXY
nohup squid -f /etc/squid/squid.conf -N > /tmp/squid.log 2>&1 &
sleep 1
nohup dockerd --host=unix:///var/run/docker.sock > /tmp/dockerd.log 2>&1 &
sleep 1

# apt doesn't reliably pick up *_proxy env vars for Acquire (varies by version/method),
# and git's http transport can be configured to skip its own env lookup - pin both
# explicitly rather than relying on env alone. Written here (not baked into the image)
# since squid isn't running yet at `docker build` time.
cat <<EOF > /etc/apt/apt.conf.d/95proxy
Acquire::http::Proxy "http://127.0.0.1:3128";
Acquire::https::Proxy "http://127.0.0.1:3128";
EOF
git config --system http.proxy "http://127.0.0.1:3128"
git config --system https.proxy "http://127.0.0.1:3128"

# run.sh mounts ~/.claude/~/.claude.json at the host's own $HOME path (see run.sh for
# why) and passes that path through as HOST_HOME. dev's own passwd-registered home
# stays /home/dev, but dev's *session* HOME needs to point at HOST_HOME instead so
# Claude Code's own $HOME-derived paths (e.g. the plugin marketplace's recorded
# "installLocation") match what was recorded when `claude` last ran natively on the
# host. Falls back to /home/dev if run without run.sh (e.g. a bare `docker run`).
# HOST_HOME itself is mostly other bind mounts' auto-created parent scaffolding
# (Docker creates missing mount-point parents in the container's own writable layer,
# not on the host), owned by root by default - chown just the top level so dev can
# still write new dotfiles/caches directly under it; the mounts underneath already
# have host-matching ownership (UID 1000) and don't need touching.
export HOME="${HOST_HOME:-/home/dev}"
mkdir -p "$HOME"
chown dev:dev "$HOME"

if [ "$#" -eq 0 ]; then
  set -- zsh -lc claude
elif [ "${1#-}" != "$1" ]; then
  # First arg is a flag (e.g. --continue, --resume) rather than a full command
  # override - forward it to `claude` instead of trying to exec a flag as a program.
  # `zsh -lc 'script' zsh "$@"` forwards the remaining args as the script's own $@
  # (same positional-forwarding trick as the sudo call below would use for su).
  set -- zsh -lc 'exec claude "$@"' zsh "$@"
fi

# sudo (not `su -l`): su's login-session setup cd's to the target user's home as part
# of establishing the session, and that happens before a `-c` script gets a chance to
# `cd` back - landed every session in /home/dev regardless of run.sh's mount. sudo
# never chdir's on its own, so the cwd docker run -w set (run.sh's project mount)
# just passes through untouched. No `-H` here (deliberately, unlike a plain dev-user
# sudo): that would force HOME back to dev's passwd-registered /home/dev, undoing the
# HOST_HOME alignment above. --preserve-env=HOME instead carries this script's own
# $HOME (just set above) through to the dev session.
exec sudo -u dev --preserve-env=HOME,HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy -- "$@"
