# Claude Backup

Back up your entire Claude Code environment — locally or to a private GitHub repo.

## Quick Start

```bash
npx claude-backup
```

Interactive setup checks requirements, creates a private repo, backs up your config and sessions, and schedules daily automatic backups.

## What It Does

Claude Backup provides two-tier protection for your Claude Code environment:

- **Config profile** — settings, CLAUDE.md, agents, hooks, skills, rules. Lightweight (< 100 KB), fast to backup, portable between machines, safe to share with teammates.
- **Sessions archive** — all chat history compressed with gzip. Large (hundreds of MB to GB), private, pushed to a private GitHub repo.

## Requirements

- **macOS** (Linux coming soon)
- **git**
- **gzip** (built-in on macOS)
- **gh** ([GitHub CLI](https://cli.github.com)) — *optional*. Enables remote backup to GitHub. Without it, backups are local-only.

## Commands

| Command | Description |
| --- | --- |
| `claude-backup` | Interactive first-time setup |
| `claude-backup sync` | Backup config + sessions |
| `claude-backup sync --config-only` | Backup config only (fast, < 1 sec) |
| `claude-backup sync --sessions-only` | Backup sessions only |
| `claude-backup status` | Show backup status |
| `claude-backup export-config` | Export config as portable tarball |
| `claude-backup import-config <file>` | Import config from tarball |
| `claude-backup import-config <file> --force` | Import config, overwriting existing files |
| `claude-backup peek <uuid>` | Preview a session's contents |
| `claude-backup restore --list` | List all backed-up sessions |
| `claude-backup restore --last N` | List last N sessions |
| `claude-backup restore --date YYYY-MM-DD` | Filter by UTC date |
| `claude-backup restore --project NAME` | Filter by project name |
| `claude-backup restore <uuid>` | Restore a specific session |
| `claude-backup restore <uuid> --force` | Overwrite existing session |
| `claude-backup uninstall` | Remove scheduler and optionally delete data |
| `claude-backup <any> --json` | Structured JSON output (for scripts/agents) |
| `claude-backup init --local` | Force local-only mode (no GitHub) |

## Machine Migration

Export your config on one machine, import it on another.

```bash
# Old machine
claude-backup export-config
# => ~/claude-config-2026-02-25.tar.gz (47 KB)

# Transfer via AirDrop, USB, email, etc.

# New machine
npx claude-backup import-config claude-config-2026-02-25.tar.gz
```

Plugins are not included in the export (they are re-downloaded on first launch). Only the plugin manifest in `settings.json` is backed up.

## Session Restore

Browse and restore individual sessions from your backups.

```bash
# List all backed-up sessions
claude-backup restore --list

# Show only the last 5 sessions
claude-backup restore --last 5

# Filter by date (UTC)
claude-backup restore --date 2026-02-27

# Filter by project name (partial match)
claude-backup restore --project myproject

# Restore a specific session
claude-backup restore <uuid>

# Overwrite if session already exists locally
claude-backup restore <uuid> --force
```

The session index (`session-index.json`) is auto-generated on every sync. It is gitignored and rebuilt from the `*.jsonl.gz` files each time — you never need to manage it manually. Dates in the index and `--date` filter use UTC.

## Local-Only Mode

Backup without GitHub — no account, no remote, no network needed.

```bash
# Automatic: if gh is not installed, local mode is used
npx claude-backup

# Explicit: force local mode even if gh is available
npx claude-backup --local
```

In local mode, backups are committed to a local git repo at `~/.claude-backup/` but never pushed. Everything else works identically — sync, restore, peek, export/import.

## Claude Code Plugin

Install the plugin to let Claude operate backups on your behalf:

```bash
/plugin marketplace add tombelieber/claude-backup
/plugin install claude-backup
```

The plugin provides a skill that teaches Claude the CLI commands. The agent always uses `--json` for structured output.

## What's Backed Up

| Item | Source | Notes |
| --- | --- | --- |
| Settings | `settings.json` | Plugins, preferences |
| Local settings | `settings.local.json` | Permission overrides |
| User instructions | `CLAUDE.md` | User-level system prompt |
| Custom agents | `agents/` | Agent definitions |
| Custom hooks | `hooks/` | Automation scripts |
| Custom skills | `skills/` | User-authored skills |
| Custom rules | `rules/` | Custom rules |
| Session files | `projects/**/*.jsonl` | Chat history (gzipped) |
| Session indexes | `projects/**/sessions-index.json` | Session metadata |
| Command history | `history.jsonl` | CLI command history (gzipped) |

All source paths are relative to `~/.claude/`.

## What's Excluded

| Item | Why |
| --- | --- |
| `.credentials.json` | Auth tokens -- security risk |
| `.encryption_key` | Encryption key -- security risk |
| `plugins/` | Re-downloadable from registry |
| `debug/`, `file-history/` | Transient logs and edit history |
| `cache/`, `.search_cache/`, `.tmp/`, `paste-cache/` | Caches, rebuilt automatically |
| `session-env/`, `shell-snapshots/` | Runtime state |
| `statsig/`, `telemetry/`, `usage-data/` | Analytics, not user data |
| `todos/`, `teams/`, `plans/`, `ide/` | Ephemeral per-session data |

## Security

- **Credentials are never backed up.** `.credentials.json` and `.encryption_key` are hardcoded exclusions.
- **GitHub repo is private** by default.
- **`export-config` warns** if any file appears to contain sensitive content (tokens, secrets, passwords).
- **`import-config` does not overwrite** existing credentials.

## Storage

```text
~/.claude-backup/                   # Git repo -> private GitHub repo
├── manifest.json                   # Backup metadata (version, timestamp, machine)
├── config/                         # Config profile
│   ├── settings.json
│   ├── settings.local.json
│   ├── CLAUDE.md
│   ├── agents/
│   ├── hooks/
│   ├── skills/
│   └── rules/
├── session-index.json              # Auto-generated, gitignored
├── projects/                       # Sessions (gzipped)
│   ├── -Users-foo-myproject/
│   │   ├── session-abc.jsonl.gz
│   │   └── sessions-index.json
│   └── ...
└── history.jsonl.gz                # Command history (gzipped)
```

| Location | Contents |
| --- | --- |
| `~/.claude-backup/` | Local compressed backups + git repo |
| `github.com/<you>/claude-backup-data` | Remote private repo |
| `~/Library/LaunchAgents/com.claude-backup.plist` | macOS scheduler (daily 3:00 AM) |

## Uninstall

```bash
claude-backup uninstall
```

This removes the daily scheduler and optionally deletes local backup data. Delete the GitHub repo separately:

```bash
gh repo delete claude-backup-data
```

## Future Plans

- Linux support (systemd timer)
- Session encryption (age)

## Related

- **[claude-view](https://github.com/tombelieber/claude-view)** — Mission Control for all your Claude Code sessions. `npx claude-view`

## License

[MIT](LICENSE)
