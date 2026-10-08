# Changelog

Notable changes to claudecontainer. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Entries marked **rebuild**
touch a file baked into the image - run `./build.sh` before the change takes effect.

## Unreleased

### Added

- Windows support through Docker Desktop (WSL2 backend), untested so far:
  `setup.ps1` installs WSL2, Docker Desktop and Git for Windows; `build.ps1` checks
  WSL2 and Docker (and starts Docker Desktop) before building; `run.ps1` is `run.sh`
  with the same flags, except `--sysbox`. Per-machine config goes in `run.local.ps1`.
  See `docs/windows.md`.
- CRLF line endings are stripped from `entrypoint.sh`, `squid.conf`,
  `allowed-domains.txt` and `extra-setup.sh` at build time, and from `--allow-list`
  files at startup. `.gitattributes` keeps tracked files LF. **rebuild**

- `run.sh --allow-config`: lets a session write Claude Code's configuration back to the
  host. Without it, config is now read-only (see Changed).
- `dev` inside the container now takes the invoking host user's UID/GID at startup
  (`run.sh` passes `HOST_UID`/`HOST_GID`, `entrypoint.sh` remaps), so mounted files
  stay owned by the host user even when their UID isn't 1000. Skipped for host root,
  rootless Docker and Podman. Override with `CONTAINER_UID`/`CONTAINER_GID` in
  `run.local.sh` (or the environment), or `CONTAINER_UID=off`; `run.sh --help` shows
  the result. **rebuild**
- README: first-run instructions for hosts without Claude Code installed (pre-create
  `~/.claude`/`~/.claude.json`, log in once with `--allow-config`).

### Changed

- **Claude Code config is read-only by default.** `settings.json`,
  `settings.local.json`, `CLAUDE.md`, `keybindings.json`, `agents/`, `commands/`,
  `skills/`, `hooks/`, `plugins/` and `output-styles/` under `~/.claude` are mounted
  `:ro` (where they exist); `~/.claude.json` is copied into the container from a
  read-only mount, so in-session edits to it are discarded on exit. Session state (transcripts, history,
  `.credentials.json`) stays writable. Extend the list from
  `run.local.sh` via `CLAUDE_CONFIG_RO_PATHS+=(...)`. **rebuild**
- **Claude starts in auto permission mode** (`--permission-mode auto`) inside the
  container. Override per session with `run.sh --permission-mode manual`. **rebuild**

## 2026-10-01

### Fixed

- `run.sh` works with macOS's bash 3.2: an empty argument list no longer trips
  `set -u` ("unbound variable").

## 2026-09-30

### Changed

- README restructured and trimmed. Sysbox install instructions (Ubuntu/Debian and Arch)
  moved to `docs/sysbox.md`.

## 2026-09-28

### Added

- `extra-setup.sh`: optional, gitignored per-machine build hook for extra apt/npm/uv
  packages or custom MCP server dependencies. Runs as root late in the build.
  `build.sh` seeds a no-op copy from `extra-setup.sh.example` if missing. **rebuild**

## 2026-09-20

### Added

- `run.sh --sysbox`: run with the `sysbox-runc` runtime instead of `--privileged`, for
  user-namespace isolation around the nested `dockerd`. Sysbox must already be
  installed; `run.sh` refuses to start if the runtime isn't registered.
- README note that Claude flags need their leading dashes (`run.sh --remote-control`,
  not `run.sh remote-control`, which fails with `sudo: remote-control: command not found`).

## 2026-09-19

### Added

- `run.sh --allow-container`: mounts the **host's** Docker socket instead of starting a
  nested `dockerd`. Containers started this way are siblings on the host daemon.
  Root-equivalent host access, off by default. **rebuild**

## 2026-09-16

### Added

- `run.sh --allow-internet`: drops squid's domain allowlist for one session. Port
  restrictions (HTTP on 80, CONNECT to 443) and proxy logging stay in place. Mutually
  exclusive with `--allow-list`. **rebuild**

## 2026-09-01

### Added

- `run.sh --mount <path|host:container[:ro]>`: one-off extra bind mounts for a single
  session, on top of `EXTRA_MOUNTS`. Repeatable; a bare path mounts read-write at the
  same path.

## 2026-08-31

### Added

- `run.sh --allow-list <path>`: replaces the egress allowlist for one session without
  touching the image. **rebuild**

## 2026-08-18

### Changed

- `build.sh` always builds with `--no-cache` and prunes the dangling images it leaves
  behind (scoped by a `project=claudecontainer` image label). **rebuild**
- `build.sh` no longer builds with `--network host`.

## 2026-08-08

### Added

- `run.sh --host-network`: opt-in host networking for VPNs that block the bridge network.
- `run.sh --help`: lists flags plus this machine's resolved mounts and network mode.
- Bun in the image (needed by the official Telegram plugin). **rebuild**

### Changed

- **Containers use Docker's bridge network by default** instead of `--network host`.
- `~/.claude` and `~/.claude.json` are mounted at the host's `$HOME` path, and `dev`'s
  `$HOME` is set to match. Fixes `cache-miss` errors for plugins installed on the host. **rebuild**

## 2026-08-07

Initial release.

### Added

- Disposable Ubuntu 24.04 image with Claude Code, Node 22, Python 3.14, uv, `gh`,
  Docker-in-Docker and zsh. Projects' `.venv` is activated automatically.
- `run.sh`: starts a `--rm` container scoped to `$PWD`, mounts the Claude Code login and
  forwards the host's ssh-agent. Args starting with `-` go to `claude`; anything else
  replaces the command.
- `run.local.sh` (gitignored, from `run.local.sh.example`): standing per-machine
  `EXTRA_MOUNTS`.
- Squid egress proxy with a domain allowlist. Proxy settings are applied to env (both
  casings), apt and git. The allowlist lives in `allowed-domains.txt` (gitignored, from
  `allowed-domains.txt.example`).
