#!/usr/bin/env bash
# Launches a fresh, disposable claudecontainer scoped to the current directory - run
# this from whatever project you want Claude Code (or anything else in the image) to
# have access to. Only $PWD and your Claude Code login get mounted in; nothing else on
# the host is reachable from inside, and the container is removed on exit (--rm) so
# there's no persistent state or mount to go stale. Extra arguments starting with `-`
# are forwarded to `claude` itself (e.g. `run.sh --continue`); anything else overrides
# the default `claude` command entirely (e.g. `run.sh bash` for a plain shell).
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

# Personal, per-machine mounts beyond $PWD - see run.local.sh.example. Gitignored and
# entirely optional: nothing breaks if it's missing, EXTRA_MOUNTS just stays empty.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRA_MOUNTS=()
if [[ -f "$script_dir/run.local.sh" ]]; then
  . "$script_dir/run.local.sh"
fi
if [[ ${#EXTRA_MOUNTS[@]} -gt 0 ]]; then
  for mount in "${EXTRA_MOUNTS[@]}"; do
    docker_args+=(-v "$mount")
  done
fi

exec docker run "${docker_args[@]}" claudecontainer:latest "$@"
