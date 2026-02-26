---
name: backup
description: >
  Manage Claude Code backups — sync config and sessions, list/restore
  sessions, check status. Use when the user asks about backups, restoring
  sessions, or migrating their Claude environment.
---

# Claude Backup

You operate the `claude-backup` CLI on behalf of the user.
Always pass `--json` to get structured output. Never parse human-readable output.

## Commands

| Intent | Command |
|--------|---------|
| Initialize backup | `claude-backup init --json` |
| Initialize (local only) | `claude-backup init --local --json` |
| Run a backup | `claude-backup sync --json` |
| Backup config only | `claude-backup sync --config-only --json` |
| Backup sessions only | `claude-backup sync --sessions-only --json` |
| Check backup status | `claude-backup status --json` |
| List all sessions | `claude-backup restore --list --json` |
| List recent N sessions | `claude-backup restore --last N --json` |
| Find sessions by project | `claude-backup restore --project NAME --json` |
| Find sessions by date | `claude-backup restore --date YYYY-MM-DD --json` |
| Preview a session | `claude-backup peek UUID --json` |
| Restore a session | `claude-backup restore UUID --json` |
| Restore (overwrite) | `claude-backup restore UUID --force --json` |
| Export config tarball | `claude-backup export-config --json` |
| Import config tarball | `claude-backup import-config FILE --json` |
| Switch backend mode | `claude-backup backend set <github\|git\|local> --json` |
| Switch to custom remote | `claude-backup backend set git --remote URL --json` |
| Set backup schedule | `claude-backup schedule <off\|daily\|6h\|hourly> --json` |
| Restore all sessions | `claude-backup restore --all --json` |
| Restore from machine | `claude-backup restore --all --machine SLUG --json` |
| Uninstall scheduler | `claude-backup uninstall` |

## Reading responses

- Success: `{"ok": true, …}` with exit code 0
- Error: `{"error": "message"}` on stderr with exit code 1
- `status` response includes `"mode": "github"`, `"mode": "git"`, or `"mode": "local"`, plus `"machine"` and `"machineSlug"` fields
- Summarize results conversationally for the user. Don't dump raw JSON.
- Pass `--local` during `init` to force local-only mode (no GitHub required)

## Helping users find sessions

Use `peek --json` before restoring to confirm the right session. Summarize
the preview naturally: "This session from Feb 27 was about debugging auth
middleware — 47 messages. Want me to restore it?"

## When to suggest backups

- User mentions migrating machines -> suggest `export-config`
- User asks about old conversations -> `restore --list`, then `peek` to confirm
- User hasn't backed up recently (check `status`) -> gentle nudge
