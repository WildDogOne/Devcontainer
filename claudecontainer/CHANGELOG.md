# Changelog

Notable changes to claudecontainer. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Entries marked **rebuild**
touch a file baked into the image - run `./build.sh` before the change takes effect.

## Unreleased

### Added

- `run.sh --allow-config`: lets a session write Claude Code's configuration back to the
  host. Without it, config is now read-only (see Changed).

### Changed

- **Claude Code config is read-only by default.** `settings.json`,
  `settings.local.json`, `CLAUDE.md`, `keybindings.json`, `agents/`, `commands/`,
  `skills/`, `hooks/`, `plugins/` and `output-styles/` under `~/.claude` are mounted
  `:ro` (where they exist); `~/.claude.json` is copied into the container from a
  read-only mount, so in-session edits to it are discarded on exit. Session state
  (transcripts, history, `.credentials.json`) stays writable. Extend the list from
  `run.local.sh` via `CLAUDE_CONFIG_RO_PATHS+=(...)`. **rebuild**
- **Claude starts in auto permission mode** (`--permission-mode auto`) inside the
  container. Override per session with `run.sh --permission-mode manual`. **rebuild**