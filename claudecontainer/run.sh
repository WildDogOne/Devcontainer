#!/usr/bin/env bash
# Launches a fresh, disposable claudecontainer scoped to the current directory - run
# this from whatever project you want Claude Code (or anything else in the image) to
# have access to. Only $PWD and your Claude Code login get mounted in; nothing else on
# the host is reachable from inside, and the container is removed on exit (--rm) so
# there's no persistent state or mount to go stale. Extra arguments override the
# default `claude` command, e.g. `run.sh bash` for a plain shell.
set -euo pipefail

docker_args=(
  --rm -it
  --privileged
  --network host
  -v "$PWD:$PWD"
  -w "$PWD"
  -v "$HOME/.claude:/home/dev/.claude"
  -v "$HOME/.claude.json:/home/dev/.claude.json"
)

# Forwards the host's ssh-agent for outbound git SSH auth (no private keys copied in).
# No-op if SSH_AUTH_SOCK isn't set - git-over-SSH just won't have agent-forwarded keys.
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
  docker_args+=(-v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" -e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
fi

exec docker run "${docker_args[@]}" claudecontainer:latest "$@"
