# claudecontainer

A restricted sandbox for running Claude Code (or any other tool in the image). Built
once, then launched fresh per session via `run.sh` - each run is a disposable
container that only ever sees the directory you launched it from, plus your Claude
Code login. No persistent container, no inbound network listener, no whole-home mount.

## Quick start

```sh
./build.sh              # docker build -t claudecontainer:latest .
cd ~/path/to/some-project
~/path/to/Devcontainer/claudecontainer/run.sh   # drops you into `claude`
```

Run `./build.sh` again after any change to `Dockerfile`, `entrypoint.sh`, `squid.conf`,
or `allowed-domains.txt` - all four are baked into the image at build time (`entrypoint.sh`
via `COPY`), so a stale image keeps running the old version until rebuilt.

Extra arguments starting with `-` are forwarded to `claude` itself, e.g.
`run.sh --continue` resumes your last session in the current directory. Anything else
overrides the default `claude` command entirely, e.g. `run.sh bash` for a plain shell.

## Shell alias

`run.sh` resolves its own location rather than relying on cwd, so an alias to its
absolute path works from any project directory - the container still only ever sees
wherever you ran `claudecli` from, not this repo. Add one of these to your shell's
config on the host (not inside the container):

**bash** (`~/.bashrc`):
```sh
alias claudecli="/path/to/Devcontainer/claudecontainer/run.sh"
```

**zsh** (`~/.zshrc`):
```sh
alias claudecli="/path/to/Devcontainer/claudecontainer/run.sh"
```

**fish** (`~/.config/fish/config.fish`):
```fish
alias claudecli="/path/to/Devcontainer/claudecontainer/run.sh"
```

Then reload the config (`source ~/.zshrc`, etc., or open a new terminal) and run
`claudecli` from any project.

## What gets mounted, and why only that

By default, `run.sh` mounts exactly three things into the container, all read-write
except where noted:

- `$PWD` → same path inside the container (so absolute paths, git, and anything
  project-relative behave the same as running directly on the host). This is the
  *only* part of your filesystem the container can see - not `$HOME`, not anything
  above or beside the current directory.
- `~/.claude` and `~/.claude.json` → reuses your host's Claude Code login instead of
  logging in again inside the container. If these don't exist yet on the host, `run.sh`
  still works - Docker creates empty mounts and you log in fresh inside.
- Your host's `$SSH_AUTH_SOCK` (if set) → outbound git-over-SSH auth via agent
  forwarding. No private keys are ever copied into the image.

`run.sh` also sources a `run.local.sh` next to itself, if present, for optional
per-machine extra mounts beyond those three (see `run.local.sh.example`). It's
gitignored - personal host paths don't belong in a shared repo - and entirely
opt-in: nothing breaks if it's missing. Every extra mount here widens the sandbox
past "just `$PWD`", so treat additions deliberately, not as a default place to bolt
things on.

Earlier versions of this setup used `docker compose` with a static volume mount
defaulting to your entire `$HOME`, plus a persistent SSH listener for JetBrains
Gateway. Both are gone: the whole-home mount defeated the point of a "restricted"
container, and a fresh `docker run` per session is a better fit than a long-lived
container with a fixed mount anyway - you can't add mounts to a container after it's
already up, so anything meant to be scoped per-session has to be decided at `docker
run` time, not baked into a compose file.

## Networking, `--privileged`, and the egress allowlist

Same reasoning as `../.devcontainer/README.md`'s "`--network=host` and `--privileged`"
and "Egress allowlist (squid)" sections: this host's Docker bridge network can't reach
the internet at all, and Docker-in-Docker (for anything run via the inner `dockerd`,
e.g. `docker compose` inside a project) needs `--privileged`. Outbound traffic from the
container is still restricted to `allowed-domains.txt` via the loopback-only squid
proxy started in `entrypoint.sh` - extend that file when a workflow needs a new host.

This relies on tools inside the container actually using that proxy - there's no
network-level enforcement (an iptables redirect was considered, but `--network host`
means the container shares the host's real network namespace, so a redirect rule can't
be safely scoped to just the container's own traffic without risking the host's own
sessions too). Instead `entrypoint.sh` sets both `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`
and their lowercase mirrors (curl, git, wget, and Go's `net/http` deliberately only
honor lowercase `http_proxy` for plain `http://` requests - the httpoxy-CVE mitigation),
plus explicit `apt` (`/etc/apt/apt.conf.d/95proxy`) and `git` (`--system http.proxy`)
config, since both are inconsistent about reading proxy env vars on their own. A tool
that ignores all of that can still reach the network directly - the allowlist is a
guard against accidents, not a hard sandbox boundary.

## Python 3.14 and `.venv`

Python 3.14 is installed via the deadsnakes PPA and made the default `python3`/
`python` (see Dockerfile). Every zsh session walks up from its current directory
looking for a `.venv/bin/activate` and sources it automatically
(`/etc/zsh/zshenv.venv`, wired in via `/etc/zsh/zshenv`). Nothing here creates a
`.venv` for you - create one yourself (`python3.14 -m venv .venv`) if a project doesn't
already have one.

## No inbound SSH / no JetBrains Gateway

This container no longer runs sshd - it has no listening port and nothing reaches it
from outside `docker run`/`docker exec`. If you need JetBrains Gateway-style remote
development again, that needs a separate, persistent container setup (a stable target
to connect to isn't compatible with "fresh container scoped to the current directory
per session").
