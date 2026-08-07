# PyCharm Gateway container

Runs the same kind of container as `../.devcontainer` (Ubuntu, Python 3.14, Node, `claude`
CLI, egress-allowlisted via squid, Docker-in-Docker), but reached through
[JetBrains Gateway](https://www.jetbrains.com/remote-development/gateway/) over plain SSH
instead of PyCharm's built-in **Dev Containers** integration. `../.devcontainer` is left
alone in case it's useful again later - this is a separate, independent setup.

## Why not Dev Containers

`../.devcontainer/devcontainer.json` drives PyCharm's Dev Containers feature, and it
mostly worked until three PyCharm-specific gaps showed up:

- `customizations.jetbrains` Python-interpreter configuration is
  [documented as "not yet implemented"](https://www.jetbrains.com/help/pycharm/customizing-devcontainer-json-file.html)
  - there's no supported way to tell PyCharm which interpreter/venv to pick.
- `remoteEnv` never reached the actual terminal session - confirmed with `docker inspect`
  on the running container; the env vars just weren't there.
- PyCharm builds its own derived image on top of the one `docker build`/`docker compose
  build` produces, and caches it independently - a rebuilt base image doesn't
  automatically invalidate it, so you can "rebuild" and still be running stale code
  unless you explicitly rebuild the *container* in PyCharm's Dev Containers settings too.

None of that is a devcontainer.json bug on our end; it's the current state of PyCharm's
implementation of the spec (VS Code's is the mature one). Gateway's plain-SSH remote
development path doesn't go through any of that translation layer, so it doesn't hit
these gaps - venv activation and everything else here is just normal shell/SSH config
you control directly.

## Quick start

```sh
cp .env.example .env   # then edit if your projects/keys don't live at the defaults
docker compose build   # network: host is set in docker-compose.yml, so this needs no
                        # workaround, unlike ../.devcontainer/build.sh
docker compose up -d
```

Then in PyCharm: **Remote Development | Gateway**, connect via SSH to `localhost:2222`
(or the container host's address) as user `dev`, using the private key matching
whichever public key(s) `GATEWAY_AUTHORIZED_KEYS_DIR` points at (defaults to everything
in `~/.ssh`). Once connected, open whatever project directory under `PROJECTS_DIR`
(defaults to your whole `$HOME`) you want to work on.

Run `docker compose build && docker compose up -d` again after any change to
`Dockerfile`, `squid.conf`, or `allowed-domains.txt`.

## Python 3.14 and `.venv`

Python 3.14 is installed via the deadsnakes PPA and made the default `python3`/`python`
(see Dockerfile). Every zsh session - Gateway's terminal, `docker exec`, anything -
walks up from its current directory looking for a `.venv/bin/activate` and sources it
automatically (`/etc/zsh/zshenv.venv`, wired in via `/etc/zsh/zshenv`). There's nothing
project-specific baked in: this works for whichever project you happen to open, since
the image is meant to be reused across all of them. Nothing here creates a `.venv` for
you - create one yourself (`python3.14 -m venv .venv`) if a project doesn't already have
one.

## Two different SSH connections, don't confuse them

- **Inbound** (Gateway → container, port 2222, key-only, `AllowUsers dev` in
  `sshd_config`): how you reach this container's IDE backend at all. Trusted keys come
  from `GATEWAY_AUTHORIZED_KEYS_DIR`.
- **Outbound** (container → GitHub/GitLab/etc. for `git`): forwards the *host's*
  ssh-agent instead of copying private keys into the image, same as
  `../.devcontainer` - see `ssh-agent-setup.sh` for the Mac/Linux socket detection.

## Networking, `--privileged`, and the egress allowlist

Same reasoning as `../.devcontainer/README.md`'s "`--network=host` and `--privileged`"
and "Egress allowlist (squid)" sections: this host's Docker bridge network can't reach
the internet at all, and Docker-in-Docker needs `--privileged`. `network_mode: host` is
also why `sshd_config` uses port 2222 instead of 22 - it's listening directly on the
host's network, so it needs a port that isn't already taken by a real sshd there.

## Host key stability

SSH host keys are generated once at image build time (`Dockerfile`), not on every
container start, so Gateway's cached fingerprint for `localhost:2222` stays valid across
restarts. Rebuilding the image *does* generate new host keys - if Gateway complains
about a changed host key afterwards, that's expected; run
`ssh-keygen -R "[localhost]:2222"` on the client and reconnect.

## Reusing your Claude Code login

`docker-compose.yml` bind-mounts your host's `~/.claude` and `~/.claude.json` into the
container, same as `../.devcontainer`, so you don't need to log in again inside it. If
those don't exist on the host yet, run `claude` once locally first, or just let Docker
create empty mounts and log in fresh in here.
