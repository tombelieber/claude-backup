# Claude Backup

Back up your entire Claude Code environment to a private GitHub repo.

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
- **gh** ([GitHub CLI](https://cli.github.com), authenticated via `gh auth login`)
- **gzip** (built-in on macOS)

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
| `claude-backup restore <UUID>` | Restore a session |
| `claude-backup uninstall` | Remove scheduler and optionally delete data |

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
- Cloud backup backends
- Session browser and search

## License

[MIT](LICENSE)
