<div align="center">

# claude-backup

**Claude Code deletes your sessions after 30 days.**

<p>
  <a href="https://www.npmjs.com/package/claude-backup"><img src="https://img.shields.io/npm/v/claude-backup.svg" alt="npm version"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/Platform-macOS-lightgrey.svg" alt="macOS">
  <a href="https://github.com/tombelieber/claude-backup/stargazers"><img src="https://img.shields.io/github/stars/tombelieber/claude-backup?style=social" alt="GitHub stars"></a>
</p>

</div>

Every debugging session. Every architecture decision. Every prompt you spent an hour crafting. Gone.

WhatsApp keeps your messages forever. Telegram keeps them forever. Discord keeps them forever. Claude Code — the tool you pay $20–200/mo for — gives you 30 days.

<div align="center">

```bash
npx claude-backup
```

**One command. Your sessions are safe. Auto-syncs daily.**

</div>

---

## What You're Losing

Claude Code stores everything in `~/.claude/` — your settings, custom agents, hooks, skills, and **every conversation you've ever had**. Sessions older than 30 days? Silently deleted.

Each session is:

- A **debugging journal** — the exact steps that fixed that impossible bug
- An **architecture record** — why you chose that pattern, with the AI's reasoning
- A **prompt library** — the carefully worded instructions that actually worked
- A **learning log** — mistakes, corrections, breakthroughs, all timestamped

You can't Google your own Claude sessions. Once they're gone, they're gone.

---

## How It Works

```bash
npx claude-backup
```

Interactive setup:

1. Checks requirements (git, gzip, python3)
2. Creates a private GitHub repo (or local-only if you prefer)
3. Backs up your config and all sessions (gzipped)
4. Schedules daily automatic backups (3:00 AM)

That's it. Run it once, forget about it.

---

## Get Your Sessions Back

Browse and restore any session from your backups:

```bash
# List all backed-up sessions
claude-backup restore --list

# Show the last 5 sessions
claude-backup restore --last 5

# Filter by date
claude-backup restore --date 2026-02-27

# Filter by project
claude-backup restore --project myproject

# Restore a specific session
claude-backup restore <uuid>
```

The session index is auto-generated on every sync and rebuilt from the `*.jsonl.gz` files — you never need to manage it manually.

---

## What Gets Saved

**Config profile** — settings, CLAUDE.md, agents, hooks, skills, rules. Lightweight (< 100 KB), portable between machines.

**Sessions archive** — all chat history, compressed with gzip. Your entire conversation history, safe in a private repo.

<details>
<summary><strong>Full backup manifest</strong></summary>
<br>

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

</details>

---

## Machine Migration

Your config took hours to perfect. Move it in seconds.

```bash
# Old machine
claude-backup export-config
# => ~/claude-config-2026-02-25.tar.gz (47 KB)

# Transfer via AirDrop, USB, email, etc.

# New machine
npx claude-backup import-config claude-config-2026-02-25.tar.gz
```

Plugins are not included in the export (they are re-downloaded on first launch). Only the plugin manifest in `settings.json` is backed up.

---

## Local-Only Mode

No GitHub account? No problem. Backups stay on your machine.

```bash
# Automatic: if gh is not installed, local mode is used
npx claude-backup

# Explicit: force local mode even if gh is available
npx claude-backup --local
```

Backups go to `~/.claude-backup/` as a local git repo. Everything works the same — sync, restore, peek, export/import.

---

## Claude Code Plugin

Let Claude manage backups for you:

```bash
/plugin marketplace add tombelieber/claude-backup
/plugin install claude-backup
```

The plugin teaches Claude the CLI commands. The agent always uses `--json` for structured output.

---

<details>
<summary><strong>All Commands</strong></summary>
<br>

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

</details>

<details>
<summary><strong>Security</strong></summary>
<br>

- **Credentials are never backed up.** `.credentials.json` and `.encryption_key` are hardcoded exclusions.
- **GitHub repo is private** by default.
- **`export-config` warns** if any file appears to contain sensitive content (tokens, secrets, passwords).
- **`import-config` does not overwrite** existing credentials.

</details>

<details>
<summary><strong>What's Excluded</strong></summary>
<br>

| Item | Why |
| --- | --- |
| `.credentials.json` | Auth tokens — security risk |
| `.encryption_key` | Encryption key — security risk |
| `plugins/` | Re-downloadable from registry |
| `debug/`, `file-history/` | Transient logs and edit history |
| `cache/`, `.search_cache/`, `.tmp/`, `paste-cache/` | Caches, rebuilt automatically |
| `session-env/`, `shell-snapshots/` | Runtime state |
| `statsig/`, `telemetry/`, `usage-data/` | Analytics, not user data |
| `todos/`, `teams/`, `plans/`, `ide/` | Ephemeral per-session data |

</details>

<details>
<summary><strong>Storage Layout</strong></summary>
<br>

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

</details>

<details>
<summary><strong>Requirements</strong></summary>
<br>

- **macOS** (Linux coming soon)
- **git**
- **gzip** (built-in on macOS)
- **python3** (built-in on macOS since Catalina)
- **gh** ([GitHub CLI](https://cli.github.com)) — *optional*. Enables remote backup. Without it, backups are local-only.

</details>

<details>
<summary><strong>Uninstall</strong></summary>
<br>

```bash
claude-backup uninstall
```

Removes the daily scheduler and optionally deletes local backup data. Delete the GitHub repo separately:

```bash
gh repo delete claude-backup-data
```

</details>

---

## Related

- **[claude-view](https://github.com/tombelieber/claude-view)** — 10 Claude sessions running. What are they doing? `npx claude-view`

---

<div align="center">

If **claude-backup** saves your sessions, consider giving it a star. It helps others discover this tool.

<a href="https://github.com/tombelieber/claude-backup/stargazers">
  <img src="https://img.shields.io/github/stars/tombelieber/claude-backup?style=for-the-badge&logo=github" alt="Star on GitHub">
</a>

<br><br>

[MIT](LICENSE)

</div>
