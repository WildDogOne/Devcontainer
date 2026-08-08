#!/usr/bin/env bash
# Launches a fresh, disposable claudecontainer scoped to the current directory - run
# this from whatever project you want Claude Code (or anything else in the image) to
# have access to. Only $PWD and your Claude Code login get mounted in; nothing else on
# the host is reachable from inside, and the container is removed on exit (--rm) so
# there's no persistent state or mount to go stale. Extra arguments starting with `-`
# are forwarded to `claude` itself (e.g. `run.sh --continue`); anything else overrides
# the default `claude` command entirely (e.g. `run.sh bash` for a plain shell).
#
# Runs on Docker's default bridge network unless `--host-network` is passed (consumed
# here, not forwarded on). Only needed when the host's own network setup - e.g. a
# corporate VPN - blocks the bridge network from reaching DNS/the internet; see
# README.md. `--host-network` shares the host's network namespace outright, so treat it
# as an opt-in trade of isolation for connectivity, not a default. Run `run.sh --help`
# for a summary of flags and this machine's resolved config (mounts, network mode).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

host_network=0
show_help=0
args=()
for arg in "$@"; do
  case "$arg" in
    --host-network) host_network=1 ;;
    -h|--help) show_help=1 ;;
    *) args+=("$arg") ;;
  esac
done
set -- "${args[@]}"

# Personal, per-machine mounts beyond $PWD - see run.local.sh.example. Gitignored and
# entirely optional: nothing breaks if it's missing, EXTRA_MOUNTS just stays empty.
EXTRA_MOUNTS=()
if [[ -f "$script_dir/run.local.sh" ]]; then
  . "$script_dir/run.local.sh"
fi

if [[ "$show_help" -eq 1 ]]; then
  cat <<EOF
Usage: run.sh [--host-network] [-h|--help] [claude-args... | command...]

Launches a fresh, disposable claudecontainer scoped to \$PWD. Only \$PWD and your
Claude Code login are mounted in; the container is removed on exit (--rm).

  -h, --help       Show this help (reflects this machine's actual config below) and exit.
  --host-network   Share the host's network namespace instead of Docker's default
                   bridge network. Only needed if the host's network (e.g. a
                   corporate VPN) blocks the bridge network from reaching the
                   internet. Consumed here, never forwarded to docker/claude.

Anything else starting with '-' is forwarded to \`claude\` itself (e.g. --continue).
A bare command (e.g. \`run.sh bash\`) overrides the default \`claude\` invocation
entirely. Full details: README.md.

Effective config on this machine:
  Image:          claudecontainer:latest
  Network:        $([[ "$host_network" -eq 1 ]] && echo "host (--host-network passed)" || echo "bridge (default; pass --host-network to change)")
  Privileged:     yes (required for Docker-in-Docker)
  Mounts:
    $PWD -> $PWD
    $HOME/.claude -> $HOME/.claude (dev's \$HOME is set to match, see README.md)
    $HOME/.claude.json -> $HOME/.claude.json
EOF
  if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
    echo "    $SSH_AUTH_SOCK -> $SSH_AUTH_SOCK (SSH_AUTH_SOCK, agent forwarding)"
  else
    echo "    (no SSH_AUTH_SOCK on host - no agent forwarding)"
  fi
  if [[ ${#EXTRA_MOUNTS[@]} -gt 0 ]]; then
    for mount in "${EXTRA_MOUNTS[@]}"; do
      echo "    $mount (from run.local.sh)"
    done
  else
    echo "    (no run.local.sh - no extra mounts)"
  fi
  exit 0
fi

# ~/.claude and ~/.claude.json are mounted at the SAME absolute path inside the
# container as on the host (not /home/dev/...) - same reasoning as $PWD above, but it
# matters more here: Claude Code's plugin/marketplace metadata records absolute
# "installLocation" paths computed from $HOME at the time a marketplace was registered.
# If the container's $HOME (dev's, /home/dev) didn't match the host's, anything
# registered while running `claude` natively on the host would mismatch inside the
# container - Claude Code would still find the files via $HOME/.claude, but the
# recorded absolute path wouldn't resolve, surfacing as a "cache-miss" error on
# whatever it registered last. HOST_HOME carries the host's $HOME into the container so
# entrypoint.sh can point dev's own $HOME at the same path (see entrypoint.sh).
docker_args=(
  --rm -it
  --privileged
  -v "$PWD:$PWD"
  -w "$PWD"
  -v "$HOME/.claude:$HOME/.claude"
  -v "$HOME/.claude.json:$HOME/.claude.json"
  -e "HOST_HOME=$HOME"
)

if [[ "$host_network" -eq 1 ]]; then
  docker_args+=(--network host)
fi

# Forwards the host's ssh-agent for outbound git SSH auth (no private keys copied in).
# No-op if SSH_AUTH_SOCK isn't set - git-over-SSH just won't have agent-forwarded keys.
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
  docker_args+=(-v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" -e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
fi

if [[ ${#EXTRA_MOUNTS[@]} -gt 0 ]]; then
  for mount in "${EXTRA_MOUNTS[@]}"; do
    docker_args+=(-v "$mount")
  done
fi

exec docker run "${docker_args[@]}" claudecontainer:latest "$@"
