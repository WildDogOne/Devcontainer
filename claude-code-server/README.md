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
| `docker-compose.yml`   | Service definition, volumes, bind mounts                            |
| `.env.example`         | Template for local config — copy to `.env` (git-ignored)            |
| `workspace/`           | Default bind-mount target if you don't override `WORKSPACE_DIR`     |
