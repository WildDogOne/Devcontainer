# Devcontainer

A sandboxed container setup for running [Claude Code](https://docs.claude.com/en/docs/claude-code) and general dev
tooling against one project directory at a time.

| Directory | Use case | How you reach it |
|---|---|---|
| [`claudecontainer/`](claudecontainer/) | Disposable, per-project sandbox for running `claude` (or anything else) from the terminal. No persistent container, no inbound network listener, only the current directory is mounted in. Runs on Linux, and on Windows via Docker Desktop on WSL2. | `run.sh` (or `run.ps1`) from any project directory |

See [`claudecontainer/README.md`](claudecontainer/README.md) for setup instructions, the reasoning behind its design
choices, and known caveats.

## At a glance

- **Claude Code preinstalled**, reusing your host's `~/.claude` / `~/.claude.json` login so you don't have to
  re-authenticate inside the container.
- **Egress allowlisting** via a loopback-only [squid](http://www.squid-cache.org/) proxy (`squid.conf`,
  `allowed-domains.txt`) rather than relying on Docker's default bridge network. This is a default-egress reduction
  for proxy-aware tools, not a hard sandbox boundary - see the
  [Network egress](claudecontainer/README.md#network-egress) section for what it does and doesn't cover.
- **No copied-in private keys** - outbound git-over-SSH auth forwards the host's own `ssh-agent` instead.

## License

No license file is included - all rights reserved by default. Open an issue if you'd like to use this under
different terms.
