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
#
# `--sysbox` (consumed here, not forwarded on) swaps `--privileged` for
# `--runtime=sysbox-runc` (https://github.com/nestybox/sysbox), which must already be
# installed and registered with the host's Docker daemon - this script only selects it,
# it doesn't install it. Sysbox gives the nested dockerd entrypoint.sh starts real
# user-namespace isolation instead of `--privileged`'s "may as well be root on the host"
# access, at the cost of a host-side dependency beyond plain Docker. Irrelevant if
# combined with --allow-container, since that path skips the nested dockerd entirely -
# there's nothing left for sysbox's isolation to apply to.
#
# `--allow-config` (consumed here, not forwarded on) lets this session write to your
# Claude Code *configuration*. By default it can't: ~/.claude itself stays read-write
# (transcripts, history, todos, OAuth token refreshes in .credentials.json - Claude Code
# breaks without them), but the config entries listed in CLAUDE_CONFIG_RO_PATHS below are
# bind-mounted read-only on top of it, and ~/.claude.json is mounted read-only at a
# staging path that entrypoint.sh copies into the container's own $HOME (Claude Code
# rewrites that file on every start, so it must stay writable - edits just never reach
# the host). The point: settings.json hooks, MCP servers, plugins, agents, commands and
# skills all run with full access on the HOST the next time you run `claude` natively,
# so a session that gets talked into editing them could escape the sandbox.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

host_network=0
show_help=0
allow_list=""
allow_internet=0
allow_container=0
allow_config=0
sysbox=0
cli_mounts=()
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-network) host_network=1; shift ;;
    -h|--help) show_help=1; shift ;;
    --allow-internet) allow_internet=1; shift ;;
    --allow-container) allow_container=1; shift ;;
    --allow-config) allow_config=1; shift ;;
    --sysbox) sysbox=1; shift ;;
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
# ${args[@]+...} guard: macOS's bash 3.2 treats an empty array as unbound under set -u.
set -- ${args[@]+"${args[@]}"}

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

if [[ "$sysbox" -eq 1 ]] && ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q sysbox-runc; then
  echo "run.sh: --sysbox passed but the sysbox-runc runtime isn't registered with this" >&2
  echo "host's Docker daemon. Install sysbox first: https://github.com/nestybox/sysbox" >&2
  exit 1
fi

# Entries under ~/.claude mounted read-only unless --allow-config is passed - everything
# here can make the HOST's own `claude` run something or behave differently. Missing
# entries are skipped (docker would otherwise create them as empty dirs on the host).
# Extend it from run.local.sh for anything else your settings point at, e.g. a
# statusline script: CLAUDE_CONFIG_RO_PATHS+=(statusline.sh)
CLAUDE_CONFIG_RO_PATHS=(
  settings.json settings.local.json CLAUDE.md keybindings.json
  agents commands skills hooks plugins output-styles
)

# Personal, per-machine mounts beyond $PWD - see run.local.sh.example. Gitignored and
# entirely optional: nothing breaks if it's missing, EXTRA_MOUNTS just stays empty.
EXTRA_MOUNTS=()
if [[ -f "$script_dir/run.local.sh" ]]; then
  . "$script_dir/run.local.sh"
fi

if [[ "$show_help" -eq 1 ]]; then
  cat <<EOF
Usage: run.sh [--host-network] [--allow-list <path> | --allow-internet] [--allow-container]
              [--allow-config] [--sysbox] [--mount <path|host:container[:ro]>]... [-h|--help] [claude-args... | command...]

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
  --allow-config    Let this session change your Claude Code config on the host
                    (~/.claude.json and settings/hooks/plugins/agents/commands/skills
                    under ~/.claude). OFF by default: those are read-only, and in-session
                    edits to ~/.claude.json are discarded on exit. Session state
                    (transcripts, history, login) stays writable either way. Consumed
                    here, never forwarded to docker/claude.
  --sysbox          Use the sysbox-runc OCI runtime instead of --privileged, for real
                    user-namespace isolation around the nested dockerd. Must already be
                    installed and registered with this host's Docker daemon - see
                    https://github.com/nestybox/sysbox. Consumed here, never forwarded
                    to docker/claude.

Anything else starting with '-' is forwarded to \`claude\` itself (e.g. --continue).
A bare command (e.g. \`run.sh bash\`) overrides the default \`claude\` invocation
entirely. Full details: README.md.

Effective config on this machine:
  Image:          claudecontainer:latest
  Network:        $([[ "$host_network" -eq 1 ]] && echo "host (--host-network passed)" || echo "bridge (default; pass --host-network to change)")
  Runtime:        $([[ "$sysbox" -eq 1 ]] && echo "sysbox-runc (--sysbox passed; no --privileged)" || echo "--privileged (default; pass --sysbox to use sysbox-runc instead, if installed)")
  Allowlist:      $([[ "$allow_internet" -eq 1 ]] && echo "DISABLED (--allow-internet passed - any host reachable via the proxy)" || { [[ -n "$allow_list" ]] && echo "$allow_list (--allow-list passed, overrides image default)" || echo "image default (allowed-domains.txt baked in at build; pass --allow-list to override)"; })
  Docker socket:  $([[ "$allow_container" -eq 1 ]] && echo "HOST /var/run/docker.sock (--allow-container passed - root-equivalent host access)" || echo "sandboxed nested dockerd only (default; pass --allow-container to use the host daemon)")
  Claude config:  $([[ "$allow_config" -eq 1 ]] && echo "WRITABLE (--allow-config passed - edits persist on the host)" || echo "read-only (default; pass --allow-config to let claude change it)")
  Mounts:
    $PWD -> $PWD
    $HOME/.claude -> $HOME/.claude (dev's \$HOME is set to match, see README.md)
EOF
  if [[ "$allow_config" -eq 1 ]]; then
    echo "    $HOME/.claude.json -> $HOME/.claude.json"
  else
    for entry in "${CLAUDE_CONFIG_RO_PATHS[@]}"; do
      if [[ -e "$HOME/.claude/$entry" ]]; then
        echo "    $HOME/.claude/$entry -> $HOME/.claude/$entry (ro)"
      fi
    done
    echo "    $HOME/.claude.json -> copied in from a ro mount (edits discarded on exit)"
  fi
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
  -v "$PWD:$PWD"
  -w "$PWD"
  -v "$HOME/.claude:$HOME/.claude"
  -e "HOST_HOME=$HOME"
)

# entrypoint.sh remaps dev's UID/GID (1000 in the image) to these, so files written to
# the bind mounts stay owned by the invoking host user whatever their UID. Skipped for
# root (dev would become UID 0) and for rootless Docker, where container UID 0 already
# is the host user and the host UID would land on an unrelated subordinate UID instead.
host_uid="$(id -u)"
if [[ "$host_uid" -ne 0 ]] && ! docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
  docker_args+=(-e "HOST_UID=$host_uid" -e "HOST_GID=$(id -g)")
fi

# Config is read-only unless --allow-config - see the header comment. The per-entry ro
# mounts nest inside the rw ~/.claude mount above (docker mounts parents first).
# ~/.claude.json can't just be :ro since Claude Code rewrites it on every start, so it's
# staged read-only and entrypoint.sh copies it into the container's writable layer.
if [[ "$allow_config" -eq 1 ]]; then
  docker_args+=(-v "$HOME/.claude.json:$HOME/.claude.json")
else
  for entry in "${CLAUDE_CONFIG_RO_PATHS[@]}"; do
    if [[ -e "$HOME/.claude/$entry" ]]; then
      docker_args+=(-v "$HOME/.claude/$entry:$HOME/.claude/$entry:ro")
    fi
  done
  docker_args+=(-v "$HOME/.claude.json:/etc/claudecontainer/claude.json.host:ro")
fi

# --privileged is the default, needed for the inner dockerd (Docker-in-Docker). --sysbox
# swaps it for the sysbox-runc runtime instead, which gives that same nested dockerd real
# user-namespace isolation rather than near-root host access - see the header comment.
if [[ "$sysbox" -eq 1 ]]; then
  docker_args+=(--runtime=sysbox-runc)
else
  docker_args+=(--privileged)
fi

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
