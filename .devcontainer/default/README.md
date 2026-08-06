# Dev Container (PyCharm)

This is a [Dev Container](https://containers.dev/) definition for working on this repo *inside* PyCharm, with
Claude Code and its usual dependencies preinstalled. It's independent of `claude-code-server/`: that directory is
a separate, always-on Docker Compose service meant for running Claude Code unattended on a server (see
`claude-code-server/README.md`); this `.devcontainer/` is for interactive, IDE-driven development.

## What's in the container

Ubuntu 24.04 image with Python, Node.js, git, GitHub CLI (`gh`), ripgrep, jq, fzf, zsh, Docker CLI + Compose,
and the `claude` CLI (`npm install -g @anthropic-ai/claude-code`), plus a non-root `vscode` user (UID/GID 1000)
so files created in the container stay writable on the host.

Everything is installed by hand in `Dockerfile` rather than via the official devcontainer "features" (`node`,
`github-cli`, `docker-in-docker`, `common-utils`), for parity with the rest of this setup (squid, manual
docker-in-docker, proxy env) — not because the features wouldn't work here. They would; Ubuntu is what they
assume. See "Base image" below for why this isn't Alpine.

## Base image: Ubuntu, not Alpine

This started out on `python:3.12-alpine`, which is smaller and was otherwise working fine — `claude` in the
integrated terminal worked, builds worked. It broke specifically on PyCharm's Dev Containers *backend*: connecting
failed with

```
Error: dl failure on line 578
Error: failed .../jbr/lib/server/libjvm.so, because Error relocating .../libjvm.so: fcntl64: symbol not found
```

`fcntl64` is a glibc-only symbol. JetBrains' Remote Development backend (the JVM/JetBrains Runtime that PyCharm
runs *inside* the dev container to drive the IDE) ships as a glibc binary, and Alpine uses musl libc instead of
glibc — so the backend's JVM can never start there. This isn't a config issue; it's a confirmed, still-open
JetBrains limitation: [JBR-7349](https://youtrack.jetbrains.com/issue/JBR-7349/RD-cant-work-on-Alpine) and
[IJPL-170288](https://youtrack.jetbrains.com/projects/IJPL/issues/IJPL-170288/RD-cant-work-on-Alpine). Alpine
last worked before Alpine 3.19 / musl's glibc-2.28+ symbol changes; there's no reliable compatibility-shim fix for
a full JVM (the `gcompat` package covers simpler binaries, not this). JetBrains' own docs list only glibc-based
distros (Ubuntu 16.04+, RHEL/CentOS 7+, etc.) as supported for Remote Development.

Alpine works fine if you only ever use `claude` from the plain integrated terminal (no PyCharm backend needed for
that) — but since the whole point here is PyCharm's Dev Containers integration, the base image has to be
glibc-based. `Dockerfile` uses Ubuntu 24.04.

## Opening it in PyCharm

Dev Containers support requires a **Professional** JetBrains IDE (PyCharm Community doesn't include Docker
integration). With Docker running locally:

1. Build the image first — see "Building the image" below. PyCharm does not build it for you.
2. `Settings/Preferences | Build, Execution, Deployment | Dev Containers` (or right-click
   `.devcontainer/devcontainer.json` in the project tree) and choose to create/attach a dev container from this
   file.
3. PyCharm starts a container from the already-built `claude-code-devcontainer:latest` image and connects — the
   backend IDE runs inside the container while you keep the regular PyCharm UI.

You can also connect via [JetBrains Gateway](https://www.jetbrains.com/remote-development/gateway/) if you'd
rather keep a lightweight client and run the full IDE backend remotely/in-container.

## Building the image

Run this yourself before opening the dev container, and again after any change to `Dockerfile`, `squid.conf`, or
`allowed-domains.txt`:

```bash
.devcontainer/build.sh
```

This is deliberate, not a missing feature: PyCharm's own dev container builder can't build this image itself.
Its internal `docker` invocation mishandles `build.options` from `devcontainer.json` — flags meant for
`docker build` end up inserted *before* the `docker` subcommand instead of after it, so `--network=host` fails
with `unknown flag: --network` and PyCharm's root `docker --help` usage banner (reproducible directly: compare
`docker build --network=host .` (works) with `docker --network=host build .` (fails identically) — the latter is
what PyCharm's builder effectively runs). This is a confirmed, still-open JetBrains bug as of PyCharm 2026.2
(`PY-262.8665.369`); see [IJPL-155682](https://youtrack.jetbrains.com/issue/IJPL-155682),
[PY-75295](https://youtrack.jetbrains.com/issue/PY-75295), and
[IJPL-188130](https://youtrack.jetbrains.com/issue/IJPL-188130) for related `build.options`/`--network=host`
handling bugs in the same feature. Since our build needs `--network=host` (see below) and can't get it through
PyCharm, `devcontainer.json` points at a pre-built `"image"` instead of a `"build"` block, and `build.sh` does the
actual build via a plain `docker build --network=host` CLI call. Runtime `--network=host` in `runArgs` is a
separate, working code path — only the *build*-time option passing is affected.

## Reusing your host's Claude Code login

`devcontainer.json` bind-mounts `~/.claude` and `~/.claude.json` from the host into the container, so you don't
have to log in again inside it. If those paths don't exist on your host yet, either run `claude` once locally
first, or just let Docker create empty mounts and log in fresh inside the container.

## `--network=host` and `--privileged`

Both the image build and the running container use `--network=host`. This repo's corporate network setup blocks
Docker's default bridge network from reaching DNS/the internet at all — only host networking works, so without
this, `apt-get`, `npm install`, `claude`, `git`, `pip`, and `gh` all lose network access.

**This is written for a Linux Docker host.** Host networking is a native Linux feature; on macOS or Windows
(Docker Desktop), `--network=host` has more limited and version-dependent support and may not behave the same
way. If you're building/running this on Docker Desktop and see network failures during the build or inside the
container, this mismatch is the first thing to check — you may need to drop `--network=host` and use the default
bridge network instead (assuming your own network doesn't have the same DNS restriction the comments in
`devcontainer.json` describe).

`--privileged` is needed for the manual Docker-in-Docker setup below; it's what lets `dockerd` run at all inside
the container.

## Egress allowlist (squid)

`--network=host` means the container shares the host's network namespace outright, so without anything else,
every process in the container has the same unrestricted egress the host itself has. Since the host constraint
above rules out Docker's usual isolated bridge network, we can't just drop in Anthropic's [reference firewall
script](https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh): that script manages
iptables rules scoped to the *container's own* network namespace, and under `--network=host` there is no separate
namespace — the same rules would land on the host's actual firewall and could affect the host machine itself, not
just this container. That's too invasive to do from a Dockerfile/postStartCommand.

Instead, `postStartCommand` starts a loopback-only [squid](http://www.squid-cache.org/) proxy
(`squid.conf`, config baked into the image) bound to `127.0.0.1:3128`, allowlisting only the domains in
`allowed-domains.txt` (Anthropic/Claude Code, npm, GitHub, PyPI, the Ubuntu mirrors, Docker Hub). `containerEnv`
points `HTTP_PROXY`/`HTTPS_PROXY` at it, so any tool that honors those variables — `claude`, `git` (over HTTPS),
`npm`, `pip`, `gh`, `curl`, `apt` — is restricted to that allowlist. The inner `dockerd` is started with the same
proxy variables passed explicitly (`sudo` drops `containerEnv`, so they're set inline in that command) so its own
image pulls are covered too.

**What this doesn't cover:** this is a default-egress reduction for proxy-aware tools, not a hard network
boundary. Because the rules live in an opt-in proxy rather than the kernel firewall, anything that ignores
`HTTP_PROXY`/`HTTPS_PROXY` — a raw `git@github.com` SSH remote, a binary making direct socket connections — still
has the same unrestricted host-network access as before. If you hit a blocked domain (e.g. Claude's `WebFetch`
tool erroring on an arbitrary site, or a new package registry), add it to `allowed-domains.txt` and rebuild.

## SSH public-key auth for git

`git@github.com`-style SSH remotes need a private key, but this container never gets one copied into
it — instead `devcontainer.json`'s `mounts` forward the *host's* running `ssh-agent`, and
`ssh-agent-setup.sh` (invoked from `postStartCommand`) figures out which of two possible sockets is
real and points `SSH_AUTH_SOCK` at it:

- **macOS (Docker Desktop):** Docker Desktop always exposes the host's ssh-agent at the fixed path
  `/run/host-services/ssh-auth.sock` inside any container that bind-mounts it, regardless of which app
  (PyCharm, a terminal, ...) launched the container — no reliance on that app's own environment.
- **Linux:** there's no such fixed path, so `devcontainer.json` bind-mounts the *launching shell's own*
  `$SSH_AUTH_SOCK` directly, which only works if that shell actually has a running `ssh-agent`
  (`ssh-add -l` should list a key) at the time PyCharm/`docker` starts the container.

Only one of these sockets will be real on a given host; the other mount is a harmless empty directory
(Docker auto-creates missing bind-mount sources). `ssh-agent-setup.sh` runs on every container start,
picks whichever path is an actual socket, and writes `export SSH_AUTH_SOCK=...` to
`/etc/zsh/zshenv.local` — sourced by every zsh invocation via the include hook added in `Dockerfile`
(plain `/etc/profile.d` isn't read by non-login zsh shells, which is what PyCharm's integrated terminal
opens). It also seeds `~/.ssh/known_hosts` for GitHub/GitLab/Bitbucket via `ssh-keyscan`, so the first
`git` SSH connection doesn't hang on an interactive host-key prompt.

If `git@github.com` still asks for a password/key after rebuilding, check `ssh-add -l` on whichever
host actually ran `docker` for this container — an empty agent is the most common cause.

## Docker-in-Docker

There's no Docker socket bind-mounted from the host and no `docker-in-docker` devcontainer feature in use.
Instead, `postStartCommand` manually launches a second, *inner* `dockerd` inside the container itself:

```bash
sudo sh -c 'nohup dockerd --host=unix:///var/run/docker.sock > /tmp/dockerd.log 2>&1 &'
```

So `docker`/`docker compose` commands run from inside this dev container talk to that inner daemon, completely
separate from any Docker daemon running on the host. Containers you start from inside the dev container are not
visible via `docker ps` on the host, and vice versa.
