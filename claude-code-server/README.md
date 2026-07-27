# Claude Code server container

A persistent Docker Compose service for running [Claude Code](https://docs.claude.com/en/docs/claude-code) on a
server: the container stays running in the background and you attach to it with `docker compose exec` whenever you
want a session, rather than it being tied to any one interactive `docker run`.

Alpine-based image with Python, Node.js, git, GitHub CLI (`gh`), ripgrep, jq, and fzf alongside the `claude` CLI.

## First-time setup

```bash
cp .env.example .env
```

Edit `.env`:

- `WORKSPACE_DIR` — host path (absolute, or relative to this directory) containing the project code Claude Code
  should work on. It's bind-mounted to `/workspace` inside the container. Defaults to `./workspace`.
- `DOCKER_GID` — only matters if you enable Docker socket access (see below).
- `TELEGRAM_BOT_TOKEN` — bot token for the Telegram bot plugin. Set it here and it's available inside the
  container as an environment variable, so the plugin can use it without extra setup. Leave unset if you're not
  using that plugin.
- `USER_UID` / `USER_GID` — shared by the `claude-code` and `pcloud` containers' non-root users (see below).
- `PCLOUD_SYNC_DIR`, `PCLOUD_USERNAME`, `PCLOUD_PASSWORD` — only matter if you use the `pcloud` service (see
  below).

Build and start:

```bash
docker compose up -d --build
```

## Using it

Attach an interactive shell:

```bash
docker compose exec claude-code zsh
```

From there, run `claude` as usual. On first run it'll print a login URL — open it in any browser (doesn't need to
be on the server), authorize, and paste the code back into the terminal.

Login state persists in the `claude-home` named volume (mounted at `/home/claude`), so you only need to log in once
— it survives container restarts and rebuilds. It's only lost if you explicitly remove the volume
(`docker compose down -v`).

To stop/start without losing anything:

```bash
docker compose stop
docker compose start
```

## Giving it access to the host's Docker daemon

By default the container has the `docker` CLI installed but nothing to talk to. If you want Claude Code to be able
to build/run containers on the server itself, uncomment this line in `docker-compose.yml`:

```yaml
      - /var/run/docker.sock:/var/run/docker.sock
```

Then set `DOCKER_GID` in `.env` to the host's docker group GID:

```bash
stat -c '%g' /var/run/docker.sock
```

...and rebuild (`docker compose up -d --build`) so the `claude` user is created with matching group membership.

**Security note:** anything with access to `/var/run/docker.sock` has root-equivalent control over the *host*
machine — it can mount the host filesystem into a new container trivially. Only enable this if you trust everything
that will run inside this container (including whatever Claude Code itself executes), and be aware it can also
see/stop/start any other containers already running on the server.

## Syncing pCloud into the workspace

The `pcloud` service builds [lneely/pcloudcc-lneely](https://github.com/lneely/pcloudcc-lneely) from source and
runs it as a second container, so files synced from pCloud are available to Claude Code without giving the
`claude-code` container itself any pCloud credentials or extra privileges.

> **This service's Dockerfile and entrypoint were written without being able to verify the upstream project's
> actual build system or CLI flags** (the environment that generated them had no network access). Treat it as a
> starting point: build it, check the logs, and adjust `pcloud/Dockerfile` / `pcloud/entrypoint.sh` against
> `lneely/pcloudcc-lneely`'s own README and `pcloudcc --help` output if it doesn't come up cleanly.

Setup:

1. Set `PCLOUD_USERNAME` and `PCLOUD_PASSWORD` in `.env`.
2. Leave `USER_UID` / `USER_GID` at their defaults (both default to `1000`) unless that UID/GID is already taken
   on the host — both containers must use the *same* values, since they both read/write
   `PCLOUD_SYNC_DIR`/`/workspace/pcloud`, and mismatched ownership is exactly the filesystem-conflict problem this
   is meant to avoid.
3. `docker compose up -d --build` — this now also builds and starts the `pcloud` container.

The pCloud filesystem is mounted at `/pcloud` inside the `pcloud` container, bind-mounted from
`PCLOUD_SYNC_DIR` on the host (`./pcloud_sync` by default). That same host directory is also bind-mounted into
`claude-code` at `/workspace/pcloud`, so Claude Code can read and write the synced files directly.

**FUSE caveat:** `pcloudcc` mounts pCloud as a virtual FUSE filesystem rather than writing a plain local copy. A
FUSE mount created *inside* a container is local to that container's mount namespace — it does not automatically
appear in another container or on the host just because they share a bind-mounted directory. If files placed
under `/pcloud` in the `pcloud` container don't show up under `/workspace/pcloud` in `claude-code`, you likely
need `bind-propagation: rshared` on both containers' volume entries (Compose long syntax) and the host source
directory mounted `shared`/`rshared` (`mount --make-rshared <PCLOUD_SYNC_DIR>`) — or, more simply, check whether
`pcloudcc` has a plain-sync (non-FUSE) mode instead, which would sidestep this entirely.

The `pcloud` container needs `/dev/fuse` and `CAP_SYS_ADMIN` to create the FUSE mount, which is why it isn't
locked down as tightly as `claude-code` — only run it with credentials for a pCloud account you're comfortable
this container having full access to.

## Updating Claude Code

The CLI version is baked into the image at build time. To pick up a new release:

```bash
docker compose build --no-cache
docker compose up -d
```

(`--no-cache` is needed because the `npm install -g` layer would otherwise be reused from cache.)

## Files

| File                  | Purpose                                                              |
|-----------------------|-----------------------------------------------------------------------|
| `Dockerfile`           | Image definition: Alpine + Python + Node + dev tools + Claude Code   |
| `docker-compose.yml`   | Service definitions for both `claude-code` and `pcloud`, volumes, bind mounts |
| `.env.example`         | Template for local config — copy to `.env` (git-ignored)            |
| `workspace/`           | Default bind-mount target if you don't override `WORKSPACE_DIR`     |
| `pcloud/Dockerfile`    | Image definition for the `pcloud` sync container (builds pcloudcc-lneely from source) |
| `pcloud/entrypoint.sh` | Runs the pcloudcc daemon and mounts pCloud at `/pcloud`              |
| `pcloud_sync/`         | Default bind-mount target if you don't override `PCLOUD_SYNC_DIR`   |
