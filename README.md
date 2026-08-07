# Devcontainer

A collection of sandboxed container setups for running [Claude Code](https://docs.claude.com/en/docs/claude-code)
and general dev tooling, each shaped for a different way of working. They're independent of each other - pick the
one that matches your workflow, not all four at once.

| Directory | Use case | How you reach it |
|---|---|---|
| [`claudecontainer/`](claudecontainer/) | Disposable, per-project sandbox for running `claude` (or anything else) from the terminal. No persistent container, no inbound network listener, only the current directory is mounted in. | `run.sh` from any project directory |
| [`.devcontainer/`](.devcontainer/) | PyCharm's built-in [Dev Containers](https://containers.dev/) integration - open this repo in PyCharm with Claude Code and the usual dependencies preinstalled. | PyCharm's Dev Containers feature |
| [`pycharm-gateway/`](pycharm-gateway/) | Same kind of environment as `.devcontainer/`, but reached over plain SSH via [JetBrains Gateway](https://www.jetbrains.com/remote-development/gateway/) instead - a workaround for a few PyCharm Dev Containers gaps (see its README). | JetBrains Gateway over SSH |
| [`claude-code-server/`](claude-code-server/) | A persistent Docker Compose service for running Claude Code unattended on a server, with an optional Telegram bot plugin and pCloud sync. | `docker compose exec` |

Each directory has its own README with setup instructions, the reasoning behind its design choices, and known
caveats.

## Common threads

All four setups share the same general shape:

- **Claude Code preinstalled**, reusing your host's `~/.claude` / `~/.claude.json` login so you don't have to
  re-authenticate inside the container.
- **Egress allowlisting** via a loopback-only [squid](http://www.squid-cache.org/) proxy (`squid.conf`,
  `allowed-domains.txt`) rather than relying on Docker's default bridge network - most of these were built against
  a host where the bridge network can't reach the internet at all, so `--network=host` plus an explicit allowlist
  is the working pattern here. This is a default-egress reduction for proxy-aware tools, not a hard sandbox
  boundary - see the individual READMEs for what it does and doesn't cover.
- **No copied-in private keys** - outbound git-over-SSH auth forwards the host's own `ssh-agent` instead.

## License

No license file is included - all rights reserved by default. Open an issue if you'd like to use this under
different terms.
