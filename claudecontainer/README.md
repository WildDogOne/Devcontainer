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

**Windows (PowerShell + Docker Desktop)** - `build.ps1`/`run.ps1` are drop-in
counterparts of `build.sh`/`run.sh`, same flags, same defaults:

```powershell
.\build.ps1
cd C:\path\to\some-project
C:\path\to\Devcontainer\claudecontainer\run.ps1   # drops you into `claude`
```

See [Windows notes](#windows-powershell--docker-desktop) below for the handful of
places Windows genuinely can't do the same thing as Linux/macOS (path handling, SSH
agent forwarding).

Run `./build.sh`/`.\build.ps1` again after any change to `Dockerfile`, `entrypoint.sh`,
`squid.conf`, or `allowed-domains.txt` - all four are baked into the image at build time
(`entrypoint.sh` via `COPY`), so a stale image keeps running the old version until
rebuilt.

Extra arguments starting with `-` are forwarded to `claude` itself, e.g.
`run.sh --continue` (`run.ps1 --continue` on Windows) resumes your last session in the
current directory. Anything else overrides the default `claude` command entirely, e.g.
`run.sh bash` for a plain shell.

This means the leading `--` matters even for flags that take a value, e.g. Claude Code's
`--remote-control [name]` - `run.sh --remote-control` works (forwarded to `claude`), but
`run.sh remote-control` (no dashes) does not: `run.sh` has no way to tell that apart from
a full command override like `run.sh bash`, so it tries to exec `remote-control` itself
as the container's command and fails with a cryptic `sudo: remote-control: command not
found`. If you see that error, check you didn't drop the leading dashes off a claude flag.

Run `run.sh --help` / `run.ps1 --help` any time for a summary of the script's own flags
plus this machine's resolved config (mounts, network mode, whether
`run.local.sh`/`run.local.ps1` is picked up) - handy as a quick sanity check without
having to read this file.

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

**PowerShell**: `Set-Alias` can't forward arguments the way a shell alias can, so use a
function instead - add this to your PowerShell profile (`$PROFILE`; run
`notepad $PROFILE` to edit it, creating it first with
`New-Item -ItemType File -Force -Path $PROFILE` if it doesn't exist yet):

```powershell
function claudecli { & "C:\path\to\Devcontainer\claudecontainer\run.ps1" @args }
```

Reload the profile (`. $PROFILE`, or open a new PowerShell window) and run `claudecli`
from any project directory, same as the bash/zsh/fish alias - `@args` forwards
everything through untouched, including `-`-prefixed flags like `--continue`.

## What gets mounted, and why only that

By default, `run.sh` mounts exactly three things into the container, all read-write
except where noted:

- `$PWD` → same path inside the container (so absolute paths, git, and anything
  project-relative behave the same as running directly on the host). This is the
  *only* part of your filesystem the container can see - not `$HOME`, not anything
  above or beside the current directory.
- `~/.claude` and `~/.claude.json` → reuses your host's Claude Code login instead of
  logging in again inside the container. If these don't exist yet on the host, `run.sh`
  still works - Docker creates empty mounts and you log in fresh inside. Mounted at the
  *same absolute path* inside the container as on the host, not at the container's
  own `dev` user's home (`/home/dev`) - `entrypoint.sh` points `dev`'s session `$HOME`
  at that same host path to match (see its comments). This isn't just cosmetic:
  Claude Code's plugin/marketplace metadata (`~/.claude/plugins/known_marketplaces.json`)
  records absolute `installLocation` paths derived from `$HOME` at the time a
  marketplace was registered. If the container's `$HOME` didn't match the host's,
  anything registered while running `claude` natively on the host would resolve to a
  path that doesn't exist inside the container, surfacing as a `cache-miss` error on
  `/reload-plugins` even though the actual files are right there via the mount.
- Your host's `$SSH_AUTH_SOCK` (if set) → outbound git-over-SSH auth via agent
  forwarding. No private keys are ever copied into the image. (Windows: see
  [Windows notes](#windows-powershell--docker-desktop) - there's no `$SSH_AUTH_SOCK` to
  forward, so `run.ps1` uses Docker Desktop's own agent-bridging instead.)

`run.sh` also sources a `run.local.sh` next to itself, if present, for optional
per-machine extra mounts beyond those three (see `run.local.sh.example`). It's
gitignored - personal host paths don't belong in a shared repo - and entirely
opt-in: nothing breaks if it's missing. Every extra mount here widens the sandbox
past "just `$PWD`", so treat additions deliberately, not as a default place to bolt
things on. (`run.ps1` does the same via `run.local.ps1` / `run.local.ps1.example`.)

For a mount you only need for one session rather than every session on this machine,
pass `run.sh --mount <path>` instead (repeatable) - it's additive on top of `$PWD`, the
Claude Code login, and `run.local.sh`'s `EXTRA_MOUNTS`, without editing that file. A bare
path with no `:` mounts read-write at that same path on both sides, same as `$PWD`
itself; give `host:container[:ro]` explicitly to mount somewhere else or read-only.

```sh
# One extra directory, read-write, same path on both sides:
run.sh --mount ~/data

# Different container path, and/or read-only:
run.sh --mount ~/reference-docs:/reference-docs:ro --continue

# Repeat the flag for more than one extra mount:
run.sh --mount ~/data --mount ~/models:/models:ro
```

```powershell
# Windows: bare path -> read-write, translated to a POSIX-style path in the container
# (C:\data -> /c/data; see Windows notes):
run.ps1 --mount C:\data

# Different container path, and/or read-only:
run.ps1 --mount C:\reference-docs:/reference-docs:ro --continue

# Repeat the flag for more than one extra mount:
run.ps1 --mount C:\data --mount C:\models:/models:ro
```

Earlier versions of this setup used `docker compose` with a static volume mount
defaulting to your entire `$HOME`, plus a persistent SSH listener for JetBrains
Gateway. Both are gone: the whole-home mount defeated the point of a "restricted"
container, and a fresh `docker run` per session is a better fit than a long-lived
container with a fixed mount anyway - you can't add mounts to a container after it's
already up, so anything meant to be scoped per-session has to be decided at `docker
run` time, not baked into a compose file.

## Networking, `--privileged`, and the egress allowlist

By default `run.sh` runs the container on Docker's normal bridge network - isolated
from the host's network namespace, same as any other `docker run` without `--network`.
`--privileged` is on by default, for Docker-in-Docker (anything run via the inner
`dockerd`, e.g. `docker compose` inside a project) - see
[below](#privileged-vs---sysbox) for the `--sysbox` alternative.

Pass `--host-network` (`run.sh --host-network`, or `--host-network --continue`, etc. -
order relative to other args doesn't matter, it's stripped out before anything is
forwarded to `docker` or `claude`) when the host's own network setup can't reach
DNS/the internet over the bridge network - e.g. behind a corporate VPN that only
routes traffic for the host's own network namespace. This shares the host's real
network namespace outright (same reasoning as `../.devcontainer/README.md`'s
"`--network=host` and `--privileged`" section), so treat it as an opt-in trade of
isolation for connectivity, not a default. Same flag, same effect via `run.ps1
--host-network` on Windows, though `--network host` support in Docker Desktop is
comparatively recent - update Docker Desktop if it's rejected.

Either way, outbound traffic from the container is restricted to `allowed-domains.txt`
via the loopback-only squid proxy started in `entrypoint.sh` - extend that file when a
workflow needs a new host, or pass `run.sh --allow-list <path>` to replace the list for
just one session (e.g. a one-off task that needs a host you don't want in the image's
permanent default). `<path>` is a host file in the same one-domain-per-line format as
`allowed-domains.txt`; it's bind-mounted read-only and swapped in by `entrypoint.sh`
before squid starts. Since the container is disposable (`--rm`), this never touches the
image or any other session - rebuild-free, and self-cleaning.

```sh
# ./extra-domains.txt, one domain per line, e.g.:
#   .pypi.org
#   .example-internal-registry.com
run.sh --allow-list ./extra-domains.txt

# Combined with a forwarded claude flag:
run.sh --allow-list ./extra-domains.txt --continue
```

For a session where the domain allowlist itself is the obstacle rather than any specific
missing domain, pass `--allow-internet` instead to drop the check entirely for that session -
`entrypoint.sh` patches `squid.conf` so `http_access allow allowed_dst` becomes
`http_access allow all`, leaving the `Safe_ports`/`SSL_ports` rules in place (still only
plain HTTP on port 80, and `CONNECT` only to port 443). Traffic still goes through squid
and still gets logged, it's just no longer domain-filtered. Same disposability as
`--allow-list`: session-scoped only, mutually exclusive with `--allow-list`, nothing to
rebuild or clean up.

```sh
run.sh --allow-internet
```

This relies on tools inside the container actually using
that proxy - there's no network-level enforcement (an iptables redirect was considered,
but under `--host-network` the container shares the host's real network namespace, so a
redirect rule can't be safely scoped to just the container's own traffic without risking
the host's own sessions too; the default bridge network doesn't have that problem, but
nothing here currently sets up an iptables-enforced boundary for it either). Instead
`entrypoint.sh` sets both `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` and their lowercase
mirrors (curl, git, wget, and Go's `net/http` deliberately only honor lowercase
`http_proxy` for plain `http://` requests - the httpoxy-CVE mitigation), plus explicit
`apt` (`/etc/apt/apt.conf.d/95proxy`) and `git` (`--system http.proxy`) config, since
both are inconsistent about reading proxy env vars on their own. A tool that ignores all
of that can still reach the network directly - the allowlist is a guard against
accidents, not a hard sandbox boundary.

## Docker socket access: nested by default, `--allow-container` for the host daemon

By default, `--privileged` plus a nested `dockerd` (started in `entrypoint.sh`) give the
container its own private Docker-in-Docker daemon - `docker`/`docker compose` run inside
the sandbox work, but the containers/images/networks they create are entirely inside this
disposable container and vanish with it (`--rm`). The host's own Docker daemon is not
reachable.

Pass `run.sh --allow-container` to bind-mount the **host's** `/var/run/docker.sock` into
the container instead (`entrypoint.sh` then skips starting its own nested `dockerd`, since
it would just fail to bind the same path). Containers started this way run as siblings on
the host's real daemon - visible to `docker ps` on the host, not cleaned up when this
container exits, and able to see/affect the host's other containers, images, volumes, and
networks.

**This is off by default and should be treated as root-equivalent access to the host.**
Anyone who can talk to a Docker socket can trivially get a root shell on whatever machine
owns it (e.g. `docker run -v /:/host -it alpine chroot /host`), so mounting the host's
socket into this sandbox punches straight through the "restricted, disposable container"
model this repo otherwise provides. Only pass it for a session that specifically needs to
drive the host daemon (e.g. managing host-level `docker compose` services), and only when
you trust everything that will run inside this container.

```sh
run.sh --allow-container
```

## `--privileged` vs `--sysbox`

`--privileged` (the default) is a blunt instrument: it disables essentially every
container security boundary Docker offers, not just the ones the nested `dockerd`
actually needs. A process that escapes the nested `dockerd` inside a `--privileged`
container has a well-trodden path to full root on the host.

Pass `run.sh --sysbox` to use the
[sysbox-runc](https://github.com/nestybox/sysbox) OCI runtime instead of `--privileged`.
Sysbox gives the container real user-namespace isolation - root inside the container maps
to an unprivileged UID on the host - while still letting the nested `dockerd` (and other
things that normally demand `--privileged`, like systemd) run unmodified. `run.sh` only
*selects* the runtime (`--runtime=sysbox-runc`); it doesn't install it, and refuses to
start with a clear error if the host's Docker daemon doesn't have `sysbox-runc`
registered (`docker info` doesn't list it).

```sh
run.sh --sysbox
```

Orthogonal to `--allow-container`: sysbox's isolation improves the nested `dockerd`
`--allow-container` bypasses, so combining the two flags is harmless but pointless -
there is no nested `dockerd` left for sysbox to isolate.

### Installing sysbox on the host

This is a one-time, per-host setup - `run.sh` never installs or configures sysbox itself,
it only passes `--runtime=sysbox-runc` once it's there. Docker must already be a native
install (not the `docker` snap) with systemd as the host's process manager.

**Ubuntu / Debian** - sysbox publishes an official `.deb`:

```sh
# Check https://github.com/nestybox/sysbox/releases for the current version/checksum first.
wget https://github.com/nestybox/sysbox/releases/download/v0.7.1/sysbox-ce_0.7.1.linux_amd64.deb
sha256sum sysbox-ce_0.7.1.linux_amd64.deb   # compare against the checksum on the release page

docker rm -f $(docker ps -aq)   # recommended: the installer may restart Docker
sudo apt-get install jq         # used by the installer
sudo apt-get install ./sysbox-ce_0.7.1.linux_amd64.deb

systemctl status sysbox         # confirm sysbox-mgr/sysbox-fs/sysbox-runc are up
```

The package registers `sysbox-runc` in `/etc/docker/daemon.json` and enables/starts the
`sysbox` systemd unit for you. Kernel >= 5.19 needs nothing extra; on older kernels the
installer may also need `shiftfs` - see sysbox's
[install guide](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md)
if it complains.

**Arch Linux** - no official package (Arch isn't in sysbox's supported-distro list), but
a community AUR package tracks upstream releases:

```sh
yay -S sysbox-ce-bin   # or: paru -S sysbox-ce-bin
```

The AUR package only installs the binaries and systemd units; you still have to wire it
up to Docker yourself. Add the runtime to `/etc/docker/daemon.json` (merge with any
existing content rather than overwriting it), then restart both services:

```json
{
  "runtimes": {
    "sysbox-runc": {
      "path": "/usr/bin/sysbox-runc",
      "runtimeArgs": ["--no-kernel-check"]
    }
  }
}
```

```sh
sudo systemctl enable --now sysbox
sudo systemctl restart docker
```

`--no-kernel-check` is there because Arch's rolling kernel isn't one sysbox recognizes as
pre-validated - functionally it behaves the same as the officially-supported distros as
long as the kernel is reasonably recent (>= 5.19 needs no `shiftfs`, matching the Ubuntu
requirement above). Since Arch isn't officially supported, treat `--sysbox` there as
best-effort: verify it with `run.sh --sysbox bash` before relying on it for anything.

## Windows (PowerShell + Docker Desktop)

`build.ps1` and `run.ps1` mirror `build.sh`/`run.sh` flag-for-flag - same defaults, same
`--host-network`/`--allow-list`/`--allow-internet`/`--mount` flags, same arg-forwarding
to `claude`. A few things genuinely work differently because Windows isn't POSIX:

- **Path translation.** The container image is Linux, so Windows paths
  (`C:\Users\me\project`) can't be mounted "at the same absolute path" the way `run.sh`
  does on Linux/macOS - there's no such path inside a Linux filesystem. `run.ps1`
  instead translates each Windows path to a POSIX look-alike (`C:\Users\me\project` ->
  `/c/Users/me/project`, lowercased drive letter) and mounts `$PWD`, `~/.claude`,
  `~/.claude.json`, and the container's `$HOME` all at that translated path - so
  everything stays internally consistent from one session to the next. The one place
  this is only an *approximation* rather than an exact match: `~/.claude.json`'s plugin
  marketplace metadata records absolute paths from whatever `claude` last ran on the
  host directly used. If that was `claude` installed natively on Windows, those are real
  Windows paths, which have no equivalent inside a Linux container at all (translated or
  not) - you may hit the same `cache-miss`-on-`/reload-plugins` symptom described above
  for a mismatched `$HOME`. Running `claude` exclusively through `run.ps1` avoids this
  since every session uses the same translation consistently.
- **SSH agent forwarding.** There's no Unix-socket `$SSH_AUTH_SOCK` on native Windows to
  bind-mount the way `run.sh` does. `run.ps1` instead checks whether the Windows
  `ssh-agent` service is running and, if so, uses Docker Desktop's own agent bridge
  (`/run/host-services/ssh-auth.sock`, exposed the same way on Docker Desktop for Mac) -
  no private keys are copied in, same as the Linux/macOS path. Start the service first
  (`Start-Service ssh-agent`, and `ssh-add` your key) if git-over-SSH inside the
  container comes back unauthenticated.
- **Virtual/cloud-sync drives.** Docker Desktop's bind mounts only work for paths it can
  actually see through its VM (WSL2 or Hyper-V backend) - ordinary local drives are
  fine, but a drive backed by a third-party virtual filesystem driver (a cloud-sync
  client's virtual drive, a `subst` mapping that doesn't resolve to a real volume, etc.)
  may not be. When that happens, Docker doesn't error - it silently mounts an *empty*
  directory, which shows up as "my project directory is empty inside the container".
  If you hit this, move the project (or at least run `run.ps1` from a project) on a real
  local drive.
- **`--host-network`** needs a Docker Desktop version new enough to support
  `--network host` (added comparatively recently for Windows/Mac); older versions reject
  the flag outright.

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
