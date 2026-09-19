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
#
# `--allow-list <path>` (consumed here, not forwarded on) swaps the squid egress
# allowlist for that one session: the given file is bind-mounted read-only and
# entrypoint.sh overwrites the image's baked-in allowed-domains.txt with it before squid
# starts. Only affects this disposable container - the image itself, and every other
# session, still use the default list. See README.md.
#
# `--mount <path>` or `--mount <host:container[:ro]>` (consumed here, not forwarded on;
# repeatable) adds one extra bind mount to this session only, on top of $PWD/the Claude
# login/run.local.sh's EXTRA_MOUNTS. A bare path with no ':' mounts read-write at that
# same path on both sides (e.g. `--mount ~/data` -> ~/data:~/data); give host:container[:ro]
# explicitly to mount elsewhere or read-only. Use it for a one-off session that needs a
# path run.local.sh doesn't already cover; for anything needed on every session on this
# machine, put it in run.local.sh instead.
#
# `--allow-internet` (consumed here, not forwarded on) drops squid's domain allowlist for this
# one session: entrypoint.sh patches the running config so `http_access allow
# allowed_dst` becomes `http_access allow all`, while leaving the Safe_ports/SSL_ports
# checks in place (still only plain HTTP on 80 and CONNECT to 443 through the proxy).
# Traffic is still proxied and logged, just no longer domain-filtered. Only affects this
# disposable container - the image, allowed-domains.txt, and every other session are
# untouched. Mutually exclusive with --allow-list (one drops the list, the other swaps
# it - combining them is almost certainly not what you meant).
#
# `--allow-container` (consumed here, not forwarded on) bind-mounts the HOST's own Docker
# socket (/var/run/docker.sock) into the container, instead of the nested dockerd
# entrypoint.sh otherwise starts inside the container. Containers started this way are
# siblings on the host's real Docker daemon, not nested inside the sandbox - they see the
# host's other containers/images/networks and are not cleaned up when this container
# exits. Off by default: a container's root-equivalent access to the host's Docker socket
# is effectively root on the host (bind-mount any host path in, run as any UID). Only pass
# this for a workflow that specifically needs the host daemon (e.g. driving host
# `docker compose` services) and that you trust to run inside this sandbox.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

host_network=0
show_help=0
allow_list=""
allow_internet=0
allow_container=0
cli_mounts=()
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-network) host_network=1; shift ;;
    -h|--help) show_help=1; shift ;;
    --allow-internet) allow_internet=1; shift ;;
    --allow-container) allow_container=1; shift ;;
    --allow-list)
      if [[ $# -lt 2 ]]; then
        echo "run.sh: --allow-list requires a path argument" >&2
        exit 1
      fi
      allow_list="$2"
      shift 2
      ;;
    --mount)
      if [[ $# -lt 2 ]]; then
        echo "run.sh: --mount requires a host path, or host:container[:ro], argument" >&2
        exit 1
      fi
      # No ':' -> mount at the same path on both sides, read-write (matches $PWD's own
      # same-path-both-sides default above). Give container:ro explicitly to differ.
      if [[ "$2" == *:* ]]; then
        cli_mounts+=("$2")
      else
        cli_mounts+=("$2:$2")
      fi
      shift 2
      ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"

if [[ -n "$allow_list" && "$allow_internet" -eq 1 ]]; then
  echo "run.sh: --allow-list and --allow-internet are mutually exclusive" >&2
  exit 1
fi

if [[ -n "$allow_list" ]]; then
  if [[ ! -f "$allow_list" ]]; then
    echo "run.sh: --allow-list file not found: $allow_list" >&2
    exit 1
  fi
  allow_list="$(cd "$(dirname "$allow_list")" && pwd)/$(basename "$allow_list")"
fi

if [[ "$allow_container" -eq 1 && ! -S /var/run/docker.sock ]]; then
  echo "run.sh: --allow-container passed but /var/run/docker.sock not found on this host" >&2
  exit 1
fi

# Personal, per-machine mounts beyond $PWD - see run.local.sh.example. Gitignored and
# entirely optional: nothing breaks if it's missing, EXTRA_MOUNTS just stays empty.
EXTRA_MOUNTS=()
if [[ -f "$script_dir/run.local.sh" ]]; then
  . "$script_dir/run.local.sh"
fi

if [[ "$show_help" -eq 1 ]]; then
  cat <<EOF
Usage: run.sh [--host-network] [--allow-list <path> | --allow-internet] [--allow-container]
              [--mount <path|host:container[:ro]>]... [-h|--help] [claude-args... | command...]

Launches a fresh, disposable claudecontainer scoped to \$PWD. Only \$PWD and your
Claude Code login are mounted in; the container is removed on exit (--rm).

  -h, --help        Show this help (reflects this machine's actual config below) and exit.
  --host-network    Share the host's network namespace instead of Docker's default
                    bridge network. Only needed if the host's network (e.g. a
                    corporate VPN) blocks the bridge network from reaching the
                    internet. Consumed here, never forwarded to docker/claude.
  --allow-list PATH Replace the squid egress allowlist for this session only, with
                    PATH (one domain per line, same format as allowed-domains.txt).
                    Doesn't touch the image or other sessions. Consumed here, never
                    forwarded to docker/claude.
  --allow-internet  Drop squid's domain allowlist for this session only - any host is
                    reachable, still only over plain HTTP (80) or CONNECT to 443,
                    still proxied and logged. Mutually exclusive with --allow-list.
                    Consumed here, never forwarded to docker/claude.
  --mount SPEC      Add one extra bind mount for this session only. A bare PATH mounts
                    read-write at that same path on both sides; use host:container[:ro]
                    to mount elsewhere or read-only. Repeatable. On top of run.local.sh's
                    EXTRA_MOUNTS, not a replacement for it. Consumed here, never
                    forwarded to docker/claude.
  --allow-container Bind-mount the HOST's own Docker socket in, instead of the sandbox's
                    nested dockerd. Containers started this way run on the host daemon as
                    siblings, not nested inside the sandbox - host-visible, not cleaned up
                    when this container exits. OFF by default: this is root-equivalent
                    access to the host. Consumed here, never forwarded to docker/claude.

Anything else starting with '-' is forwarded to \`claude\` itself (e.g. --continue).
A bare command (e.g. \`run.sh bash\`) overrides the default \`claude\` invocation
entirely. Full details: README.md.

Effective config on this machine:
  Image:          claudecontainer:latest
  Network:        $([[ "$host_network" -eq 1 ]] && echo "host (--host-network passed)" || echo "bridge (default; pass --host-network to change)")
  Privileged:     yes (required for Docker-in-Docker)
  Allowlist:      $([[ "$allow_internet" -eq 1 ]] && echo "DISABLED (--allow-internet passed - any host reachable via the proxy)" || { [[ -n "$allow_list" ]] && echo "$allow_list (--allow-list passed, overrides image default)" || echo "image default (allowed-domains.txt baked in at build; pass --allow-list to override)"; })
  Docker socket:  $([[ "$allow_container" -eq 1 ]] && echo "HOST /var/run/docker.sock (--allow-container passed - root-equivalent host access)" || echo "sandboxed nested dockerd only (default; pass --allow-container to use the host daemon)")
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
  if [[ ${#cli_mounts[@]} -gt 0 ]]; then
    for mount in "${cli_mounts[@]}"; do
      echo "    $mount (from --mount)"
    done
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

# entrypoint.sh overwrites the image's baked-in allowed-domains.txt with this file
# (if mounted) before starting squid - see entrypoint.sh.
if [[ -n "$allow_list" ]]; then
  docker_args+=(-v "$allow_list:/etc/squid/allowed-domains.override.txt:ro")
fi

# entrypoint.sh patches squid.conf to drop the domain allowlist check when this is set -
# see entrypoint.sh.
if [[ "$allow_internet" -eq 1 ]]; then
  docker_args+=(-e "SQUID_ALLOW_INTERNET=1")
fi

# entrypoint.sh skips starting its own nested dockerd when this is set, since the host
# socket is mounted at the same path and would conflict with it - see entrypoint.sh.
# Root-equivalent access to the host: off by default, opt-in per session only.
if [[ "$allow_container" -eq 1 ]]; then
  docker_args+=(-v /var/run/docker.sock:/var/run/docker.sock -e "ALLOW_CONTAINER=1")
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

# --mount, one or more times - session-scoped extra mounts on top of run.local.sh's
# EXTRA_MOUNTS, without needing to edit that (personal, per-machine) file.
if [[ ${#cli_mounts[@]} -gt 0 ]]; then
  for mount in "${cli_mounts[@]}"; do
    docker_args+=(-v "$mount")
  done
fi

exec docker run "${docker_args[@]}" claudecontainer:latest "$@"
