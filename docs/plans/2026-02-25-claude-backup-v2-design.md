# claude-backup v2 — Full Environment Backup

**Date:** 2026-02-25
**Status:** Approved
**Supersedes:** claude-view session-backup-design (2026-02-24 draft)

## Problem

Claude Code retains session history for only 30 days, then purges. Uninstalling Claude Code may wipe `~/.claude/` entirely. Power users lose:

- **Session history** — every coding decision, debug session, architectural choice
- **Configuration** — settings, custom agents, hooks, skills, CLAUDE.md instructions
- **Setup investment** — the hours spent customizing Claude Code to work the way you want

There is no way to backup, restore, port, or share a Claude Code environment.

## Goal

`claude-backup` becomes the complete environment backup tool for Claude Code:

- **Backup** everything that matters
- **Restore** on a new machine in seconds
- **Port** your setup between machines
- **Share** your config with teammates

## Architecture: Two-Tier Backup

### Tier 1: Config Profile (lightweight, portable, shareable)

Everything that defines your Claude Code setup. Small (< 100 KB typically), fast to backup, safe to share.

| What | Source Path | Rationale |
|------|-------------|-----------|
| Settings | `settings.json` | Enabled plugins, preferences |
| Local settings | `settings.local.json` | Permission overrides |
| User instructions | `CLAUDE.md` | User-level system instructions |
| Custom agents | `agents/` | User-authored agent definitions |
| Custom hooks | `hooks/` | Automation scripts |
| Custom skills | `skills/` | User-authored skills |
| Custom rules | `rules/` | Custom rules |

All paths relative to `~/.claude/`.

**What is NOT included in config backup:**

| Excluded | Why |
|----------|-----|
| `.credentials.json` | Auth tokens — security risk |
| `.encryption_key` | Encryption key — security risk |
| `plugins/` (108 MB) | Re-downloadable from registry. Only the manifest in `settings.json` matters. |
| `debug/` (906 MB) | Transient debug logs |
| `file-history/` (77 MB) | Transient edit history |
| `cache/`, `.search_cache/`, `.tmp/` | Caches, rebuilt automatically |
| `paste-cache/` | Ephemeral clipboard data |
| `session-env/`, `shell-snapshots/` | Runtime state |
| `statsig/`, `telemetry/`, `usage-data/` | Analytics, not user data |
| `security_warnings_state_*.json` | Per-session security state |
| `todos/`, `teams/`, `plans/` | Ephemeral per-session data |
| `ide/` | IDE integration state, rebuilt on connect |
| `claude-view.db`, `vibe-recall.db` | Other apps' data |
| `live-monitor-pids.json`, `stats-cache.json` | Runtime state |
| `migration_v2_complete` | One-time migration marker |
| `package.json`, `count_tokens.js`, `statusline-command.sh` | Claude Code internals |

### Tier 2: Sessions Archive (heavy, personal, private)

All session history. Large (500 MB - 3 GB), compressed with gzip, pushed to private GitHub repo.

| What | Source Path | Rationale |
|------|-------------|-----------|
| Session files | `projects/**/*.jsonl` | Chat history (the core data) |
| Session indexes | `projects/**/sessions-index.json` | Session metadata |
| Command history | `history.jsonl` | CLI command history |

## CLI Interface

### Existing commands (unchanged, backward compatible)

```
claude-backup              # Interactive first-time setup
claude-backup init         # Same as above
claude-backup sync         # Backup everything (config + sessions)
claude-backup status       # Show backup status
claude-backup restore ID   # Restore a session by UUID
claude-backup uninstall    # Remove scheduler and optionally data
claude-backup --help       # Show help
claude-backup --version    # Show version
```

### New commands

```
claude-backup sync --config-only    # Backup config tier only (fast, < 1 sec)
claude-backup sync --sessions-only  # Backup sessions tier only

claude-backup export-config              # Export config as portable tarball
claude-backup export-config -o setup.tar.gz  # Export to specific file

claude-backup import-config <file>       # Import config from tarball
claude-backup import-config setup.tar.gz # Restore config on new machine
```

### UX flow for new user

```
$ npx claude-backup

  Claude Backup v2.0.0

  Checking requirements...
    git ✓
    gh ✓ (logged in as tombelieber)
    gzip ✓

  Found 2847 sessions across 38 projects

  Creating private repo...
    github.com/tombelieber/claude-backup-data ✓

  Backing up config profile...
    settings.json ✓
    CLAUDE.md ✓
    1 agent, 1 hook, 12 skills ✓

  Backing up sessions (2.7 GB → compressed)...
    Compressed: 2847, copied: 38
    Committing 2885 files (780M total)... ✓
    Pushing to GitHub... ✓

  Scheduling daily backup at 3:00 AM... ✓

  All set! Your Claude Code environment is backed up.

  Commands:
    claude-backup sync            Run backup now
    claude-backup status          Check last backup
    claude-backup export-config   Export config for sharing/migration
    claude-backup restore ID      Restore a session
```

### UX flow for machine migration

```
# On old machine:
$ claude-backup export-config
  Exported to ~/claude-config-2026-02-25.tar.gz (47 KB)

# Transfer file to new machine (AirDrop, USB, email, whatever)

# On new machine:
$ npx claude-backup import-config claude-config-2026-02-25.tar.gz
  Importing config profile...
    settings.json ✓ (23 plugins configured)
    CLAUDE.md ✓
    1 agent ✓
    1 hook ✓
    12 skills ✓

  Done! Restart Claude Code to apply settings.
  Note: Plugins will be downloaded on first launch.
```

## Storage Layout

```
~/.claude-backup/                   # Git repo → private GitHub repo
├── .gitignore
├── manifest.json                   # Backup metadata (version, timestamp, machine)
├── config/                         # Tier 1: Config profile
│   ├── settings.json
│   ├── settings.local.json
│   ├── CLAUDE.md
│   ├── agents/
│   │   └── full-codebase-docs-sync-scanner.md
│   ├── hooks/
│   │   └── notify-mission-control.sh
│   ├── skills/
│   │   ├── agent-browser/
│   │   ├── skill-creator/
│   │   └── ... (user-authored skills)
│   └── rules/
├── projects/                       # Tier 2: Sessions (gzipped)
│   ├── -Users-foo-myproject/
│   │   ├── session-abc.jsonl.gz
│   │   └── sessions-index.json
│   └── ...
└── history.jsonl.gz                # Command history (gzipped)
```

### manifest.json

```json
{
  "version": "2.0.0",
  "machine": "Toms-MacBook-Pro.local",
  "user": "tombelieber",
  "lastSync": "2026-02-25T03:00:00Z",
  "config": {
    "files": 17,
    "sizeBytes": 47200
  },
  "sessions": {
    "files": 2847,
    "projects": 38,
    "sizeBytes": 817889280,
    "uncompressedBytes": 2899102720
  }
}
```

## Design Decisions

### Why bash (not Rust)?

- Zero dependencies: git, gh, gzip are pre-installed or trivial to install
- `npx claude-backup` just works — no compile step, no Rust toolchain
- Claude Code users already have Node.js
- Bash is sufficient for file copy + git operations
- Proven at scale: Time Machine's `tmutil`, Homebrew's `brew bundle` are shell tools

### Why gzip (not zstd) for sessions?

- gzip is built into macOS/Linux (zero install)
- 70% compression is good enough for GitHub push
- zstd would require bundling a binary or a dependency
- Config tier is not compressed (too small to matter, and keeps files readable in GitHub)

### Why raw copy for config (not compressed)?

- Config files are < 100 KB total
- Raw files are readable directly on GitHub (you can browse your settings in the web UI)
- No decompression needed for `import-config`

### Why GitHub (not S3/R2/Supabase)?

- Claude Code users already have `gh` authenticated
- Private repo = encrypted at rest, access-controlled
- Free (unlimited private repos, generous storage)
- Git provides versioning for free (see config change history)
- Can be swapped for other backends later (the local archive is the source of truth)

### Relationship to claude-view

```
claude-backup = Time Machine CLI     (backs up, restores, schedules)
claude-view   = Finder Time Machine  (browses, searches backed-up data)
```

Independent tools, same data source (`~/.claude/projects/`). claude-view may optionally read from `~/.claude-backup/` to show archived sessions, but there is no dependency.

## Security

- **Credentials are NEVER backed up** (`.credentials.json`, `.encryption_key`)
- **Encryption key exclusion is hardcoded**, not configurable
- **GitHub repo is private** by default
- **export-config warns** if any file looks sensitive (contains "token", "secret", "password")
- **import-config does not overwrite** existing credentials

## Migration from v1

v2 is backward compatible with v1:

- Existing `~/.claude-backup/projects/` directory is preserved
- `claude-backup sync` continues to work as before (now also backs up config)
- No data migration needed
- `manifest.json` is created on first v2 sync

## Future (not in scope for v2)

- Linux support (systemd timer) — next release
- Windows support — after Linux
- Cloud backup to Supabase/R2 (for cross-device, potentially via claude-view mobile)
- Session browser and search (via claude-view integration)
- Selective restore (restore only specific projects)
- Config diff (show what changed between machines)
