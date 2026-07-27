# Dev Container (PyCharm)

This is a [Dev Container](https://containers.dev/) definition for working on this repo *inside* PyCharm, with
Claude Code and its usual dependencies preinstalled. It's independent of `claude-code-server/`: that directory is
a separate, always-on Docker Compose service meant for running Claude Code unattended on a server (see
`claude-code-server/README.md`); this `.devcontainer/` is for interactive, IDE-driven development.

## What's in the container

Alpine-based image (`python:3.12-alpine`) with Python, Node.js, git, GitHub CLI (`gh`), ripgrep, jq, fzf, zsh,
Docker CLI + Compose, and the `claude` CLI (`npm install -g @anthropic-ai/claude-code`), plus a non-root `vscode`
user (UID/GID 1000) so files created in the container stay writable on the host.

The official devcontainer "features" (`node`, `github-cli`, `docker-in-docker`, `common-utils`) all assume a
Debian/Ubuntu base, so on this Alpine image everything is installed by hand in `Dockerfile` instead of via
`features` in `devcontainer.json`.

## Opening it in PyCharm

Dev Containers support requires a **Professional** JetBrains IDE (PyCharm Community doesn't include Docker
integration). With Docker running locally:

1. `Settings/Preferences | Build, Execution, Deployment | Dev Containers` (or right-click
   `.devcontainer/devcontainer.json` in the project tree) and choose to create/attach a dev container from this
   file.
2. PyCharm builds the image, starts the container, and connects — the backend IDE runs inside the container while
   you keep the regular PyCharm UI.

You can also connect via [JetBrains Gateway](https://www.jetbrains.com/remote-development/gateway/) if you'd
rather keep a lightweight client and run the full IDE backend remotely/in-container.

## Reusing your host's Claude Code login

`devcontainer.json` bind-mounts `~/.claude` and `~/.claude.json` from the host into the container, so you don't
have to log in again inside it. If those paths don't exist on your host yet, either run `claude` once locally
first, or just let Docker create empty mounts and log in fresh inside the container.

## `--network=host` and `--privileged`

Both the image build and the running container use `--network=host`. This repo's corporate network setup blocks
Docker's default bridge network from reaching DNS/the internet at all — only host networking works, so without
this, `apk add`, `npm install`, `claude`, `git`, `pip`, and `gh` all lose network access.

**This is written for a Linux Docker host.** Host networking is a native Linux feature; on macOS or Windows
(Docker Desktop), `--network=host` has more limited and version-dependent support and may not behave the same
way. If you're building/running this on Docker Desktop and see network failures during the build or inside the
container, this mismatch is the first thing to check — you may need to drop `--network=host` and use the default
bridge network instead (assuming your own network doesn't have the same DNS restriction the comments in
`devcontainer.json` describe).

`--privileged` is needed for the manual Docker-in-Docker setup below; it's what lets `dockerd` run at all inside
the container.

## Docker-in-Docker

There's no Docker socket bind-mounted from the host and no `docker-in-docker` devcontainer feature in use.
Instead, `postStartCommand` manually launches a second, *inner* `dockerd` inside the container itself:

```bash
sudo sh -c 'nohup dockerd --host=unix:///var/run/docker.sock > /tmp/dockerd.log 2>&1 &'
```

So `docker`/`docker compose` commands run from inside this dev container talk to that inner daemon, completely
separate from any Docker daemon running on the host. Containers you start from inside the dev container are not
visible via `docker ps` on the host, and vice versa.
