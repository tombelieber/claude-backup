# Backup Experience Design: iCloud/WhatsApp Model

**Date:** 2026-02-27
**Status:** Draft
**Target Version:** 3.2.0
**Scope:** Cross-product — covers claude-backup CLI, claude-view dashboard, relay server, mobile app
**Depends on:** v3.1 (JSON output, local mode, peek — shipped in v3.1.0)

---

## Core Insight

Users don't want to manage backups. They want to feel safe.

WhatsApp, iCloud, and Telegram all converge on the same UX: one screen, one button, one backend choice. The user glances at it, sees "Last backup: Today, 3:00 AM," and moves on. They never think about individual files. They never browse backups unless something went wrong.

Apply this to Claude Code.

---

## Design Principles

1. **One screen, one glance.** Backup health visible in 2 seconds. No navigation required.
2. **One button.** "Back Up Now" is always available. Auto-backup handles the rest.
3. **One choice.** Where backups go — picked once during setup, then forgotten.
4. **Restore is primarily a setup event.** Full restore happens on a new machine. Session browsing (`restore --list/--last/--date/--project`) and single-session recovery (`restore <uuid>`) are available anytime for mid-work recovery (v3.0).
5. **Your server never touches session data.** Metadata only. User owns their data. (Session data = `.jsonl.gz` files. Metadata = manifest.json, session-index.json, counts/timestamps/machine name. The relay receives only the metadata fields defined in the relay schema below.)

---

## Architecture: Who Owns What

```text
User's Mac              Your Server            User's GitHub
───────────             ───────────            ─────────────
claude-backup ──data──────────────────────────> private repo
              ──metadata──> relay DB
                              │
claude-view  <──status──── relay DB
                              │
Mobile app   <──status──── relay DB
```

| Component                       | Owns                          | Stores                                                     |
| ------------------------------- | ----------------------------- | ---------------------------------------------------------- |
| **claude-backup** (this repo)   | Backup engine                 | Sessions + config in git repo or local                     |
| **claude-view**                 | Backup settings UI            | Nothing — reads from CLI / filesystem                      |
| **Relay server**                | Orchestration + mobile bridge | Metadata only: last sync, session count, machine name      |
| **Mobile app**                  | Status display                | Nothing — reads from relay                                 |

The relay server is the bridge to mobile. It never stores session data. It stores: last backup timestamp, session count, project count, backup size, machine hostname, backend mode. Enough to show "Last backup: Today, 3:00 AM — 247 sessions" on a phone.

---

## Backend Options

| Backend                    | Default?        | Who it's for                            | Mode enum  | Requirements                |
| -------------------------- | --------------- | --------------------------------------- | ---------- | --------------------------- |
| **Local only**             | Yes (no `gh`)   | Privacy-first users, first-time setup   | `local`    | None                        |
| **GitHub (private repo)**  | Yes (has `gh`)  | Power users who want cloud backup       | `github`   | `gh` CLI, authenticated     |
| **Custom git remote**      | No              | Enterprise — GitLab, Bitbucket, etc.    | `git`      | Git URL + credentials       |

The `mode` value is stored in `manifest.json` and exposed via `status --json`. All three values (`local`, `github`, `git`) must be handled by any code that branches on mode. **Implementation note:** Today, cli.sh only branches on `local` vs `github`. Every `if [ "$mode" = "github" ]` guard must be updated to also handle `git` mode (both `github` and `git` have a remote, both push — the only difference is how the remote URL is configured).

**Decision tree during init (v3.2 target — not yet implemented):**

> **Current behavior (v3.0):** `cmd_init` takes no arguments, requires `gh` CLI, GitHub-only.
> **v3.1 adds:** `--local` flag on init, auto-detection when `gh` is absent.
> **v3.2 replaces** `--local` with the `--backend` flag family below.

1. `--backend local` flag → local mode, skip everything
2. `--backend github` flag → GitHub mode, require `gh`
3. `--backend git --remote <url>` flag → custom remote
4. No flag + `gh` available → default to GitHub (current behavior)
5. No flag + no `gh` → default to local

> **Note:** v3.1 uses `--local` on init. v3.2 supersedes this with `--backend local`. The v3.1 `--local` flag should be kept as an alias for backwards compatibility.

**Upgrade path:** A local user who later installs `gh` can upgrade:

```bash
claude-backup backend set github
```

This adds the remote, pushes existing history, flips mode. (v3.2 — new subcommand, does not exist in v3.0 or v3.1. Replaces v3.1's deferred `claude-backup remote github` concept.)

**`backend set` pre-flight validation (v3.2):** Before flipping the mode, the command must verify the target backend is usable:

- `backend set github` → (1) verify `gh` CLI is installed, (2) verify `gh auth status` succeeds, (3) create/verify private repo via `gh repo create`, (4) add or update git remote (`git remote set-url origin <url>` if remote exists, `git remote add origin <url>` if not), (5) test push current HEAD, (6) only then flip `mode` in manifest.json
- `backend set git --remote <url>` → (1) verify `git ls-remote <url>` succeeds, (2) add or update git remote (same idempotent pattern), (3) test push, (4) flip mode
- `backend set local` → (1) remove git remote if present, (2) flip mode (no validation needed)

---

## The Backup Settings Screen (claude-view)

This is the primary user-facing surface. Lives in claude-view as a Settings page.

### Main View

```text
┌──────────────────────────────────────────────────┐
│  Backup                                          │
│                                                  │
│  ┌──────────────────────────────────────────┐    │
│  │  ✅  Last backup: Today, 3:00 AM         │    │
│  │  247 sessions · 15 projects · 380 MB     │    │
│  │                                          │    │
│  │            [ Back Up Now ]               │    │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  Auto-backup           Daily at 3:00 AM      >  │
│  Backend               GitHub (private)      >  │
│  Encryption            Off                   >  │
│                                                  │
│  ────────────────────────────────────────────    │
│                                                  │
│  Include                                         │
│  ☑ Sessions             247 files · 380 MB      │
│  ☑ Config & Settings     12 files · 48 KB       │
│                                                  │
│  ────────────────────────────────────────────    │
│                                                  │
│  Backup Size            382 MB                  │
│  Oldest Session         Jan 15, 2026            │
│  Machine                MacBook Pro (Tom's)     │
└──────────────────────────────────────────────────┘
```

**Data source:** Two options depending on what's shipped:

- **Before v3.0:** claude-view reads `manifest.json` directly from `~/.claude-backup/` (legacy fallback)
- **v3.0+ (current):** `claude-backup status --json` provides all fields as structured JSON

> **Gap (live in v3.1.0):** `status --json` is missing a `machine` field. The manifest's `machine` field (hostname) exists today but `cmd_status_json()` doesn't expose it. **v3.2 must add this field** to `cmd_status_json()` output before the backup screen or relay can display the machine name.
>
> **Cross-doc dependency (ACTION REQUIRED):** The v3.1 design doc (`2026-02-27-claude-backup-v3.1-design.md`) must be updated to include `"machine"` and `"machineSlug"` fields in the `status --json` output contract. Without this, v3.2's relay integration and claude-view backup screen will silently lack machine information. Since v3.1 is already shipped (v3.1.0), the `machine` field must be added to `cmd_status_json()` as part of v3.2 implementation.

### Backend Picker (drill-down from "Backend" row)

```text
┌──────────────────────────────────────────────────┐
│  Where to back up                                │
│                                                  │
│  ● Local only                                    │
│    Stays on this machine. No cloud.              │
│                                                  │
│  ○ GitHub (private repo)                         │
│    Requires GitHub CLI · ✓ @tombelieber          │
│                                                  │
│  ○ Custom git remote                             │
│    Any git URL — GitLab, Bitbucket, self-hosted  │
│                                                  │
└──────────────────────────────────────────────────┘
```

**Action:** Selecting a backend calls `claude-backup backend set <mode>` (v3.2 CLI command).

### Auto-backup Picker

```text
┌──────────────────────────────────────────────────┐
│  Auto-backup frequency                           │
│                                                  │
│  ○ Off                                           │
│  ○ Daily             at 3:00 AM                  │
│  ● Every 6 hours                                 │
│  ○ Hourly                                        │
│                                                  │
└──────────────────────────────────────────────────┘
```

**Implementation (v3.2 — not yet built):** Requires a new `claude-backup schedule <frequency>` command. Today, `schedule_launchd()` in cli.sh hardcodes daily at 3:00 AM with no frequency parameter.

**Current state (v3.0):** `schedule_launchd()` uses `launchctl unload/load` (the older API). Errors from `unload` are silently suppressed (`2>/dev/null || true`). No plist validation before `load`. Plist path: `~/Library/LaunchAgents/com.claude-backup.plist`.

**v3.2 `schedule` command spec:**

```bash
claude-backup schedule <frequency>
# frequency: off | daily | 6h | hourly
```

The command must:

1. **Map frequency to plist interval:**
   - `off` → remove plist, bootout the agent
   - `daily` → `StartCalendarInterval` with `Hour=3, Minute=0`
   - `6h` → `StartInterval` with `<integer>21600</integer>` (6 * 3600)
   - `hourly` → `StartInterval` with `<integer>3600</integer>`

2. **Standardize the launchd service label.** Today, `PLIST_NAME="com.claude-backup.plist"` is used as both the filename AND the `<Label>` key inside the plist. The `.plist` suffix in the label is non-standard — launchd labels should not include file extensions. v3.2 must split these:
   - `SERVICE_LABEL="com.claude-backup"` — the launchd label (used in bootout/bootstrap/print)
   - `PLIST_PATH="$HOME/Library/LaunchAgents/com.claude-backup.plist"` — the file path
   - Update all three consumers of `PLIST_NAME` to use `SERVICE_LABEL`: `cmd_status()`, `cmd_status_json()`, and `cmd_uninstall()` (which also needs `bootout` instead of the deprecated `unload`)

3. **Follow the full launchctl lifecycle** (critical — plist changes are NOT picked up automatically):

   ```bash
   SERVICE_LABEL="com.claude-backup"
   DOMAIN="gui/$(id -u)"
   SERVICE_TARGET="$DOMAIN/$SERVICE_LABEL"

   # Handle "off" — stop and remove, then return early
   if [ "$frequency" = "off" ]; then
     launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true
     rm -f "$PLIST_PATH"
     info "Automatic backups disabled."
     return
   fi

   # 1. Stop old schedule (bootout replaces deprecated 'unload')
   launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true

   # 2. Rewrite plist with new frequency.
   # generate_plist() is extracted from the existing schedule_launchd() heredoc
   # in cli.sh. It takes a frequency arg and outputs plist XML to stdout.
   # Branches on frequency:
   #   "daily"  → <key>StartCalendarInterval</key><dict>Hour=3,Minute=0</dict>
   #   "6h"     → <key>StartInterval</key><integer>21600</integer>
   #   "hourly" → <key>StartInterval</key><integer>3600</integer>
   generate_plist "$frequency" > "$PLIST_PATH"

   # 3. Validate plist XML before loading (plutil ships with macOS, always available)
   if ! plutil -lint "$PLIST_PATH" >/dev/null 2>&1; then
     fail "Generated plist is invalid XML. Aborting."
   fi

   # 4. Register new schedule (bootstrap replaces deprecated 'load')
   launchctl bootstrap "$DOMAIN" "$PLIST_PATH"

   # 5. Verify the agent is running
   if ! launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
     warn "Schedule registered but agent not running. Check: launchctl print $SERVICE_TARGET"
   fi
   ```

   > **Note:** `generate_plist()` does not exist today — it must be extracted from the inline heredoc in `schedule_launchd()` in cli.sh and parameterized to accept a frequency argument.

4. **Store frequency in manifest.json** so `status --json` can report it.

5. **Update existing `schedule_launchd()`** to use `bootout/bootstrap` instead of `unload/load` (the old API still works on macOS 14+ but is deprecated since macOS 10.10).

> **Precedent:** Homebrew's `brew services` uses `bootout/bootstrap` for launchd management. The `load/unload` API is deprecated but not removed. v3.2 should migrate to `bootout/bootstrap` for forward compatibility.

(Future: systemd for Linux.)

---

## The Restore Flow

Restore has two modes: **full restore** (setup-time, new machine) and **single-session recovery** (anytime, mid-work).

### Full Restore (New Machine)

#### Trigger

User runs `claude-backup init` on a new machine. The CLI detects an existing backup (via GitHub remote or relay metadata) and offers restore.

Alternatively, in claude-view: a "Restore from Backup" entry point in Settings.

### New Machine Flow

```text
┌──────────────────────────────────────────────────┐
│                                                  │
│  📦 Backup found                                 │
│                                                  │
│  From: MacBook Pro (Tom's)                       │
│  Date: Feb 27, 2026 at 3:00 AM                  │
│  Size: 247 sessions · 15 projects · 380 MB      │
│                                                  │
│  ┌──────────────────────────────────────────┐    │
│  │        [ Restore Everything ]            │    │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  [ Choose What to Restore ]                      │
│                                                  │
│  [ Start Fresh ]                                 │
│                                                  │
└──────────────────────────────────────────────────┘
```

### "Choose What to Restore" (drill-down)

```text
┌──────────────────────────────────────────────────┐
│  What to restore                                 │
│                                                  │
│  ☑ Config & Settings        12 files · 48 KB    │
│    CLAUDE.md, settings, agents, hooks, skills    │
│                                                  │
│  ☑ Sessions                 247 files · 380 MB  │
│    All backed-up conversations                   │
│                                                  │
│              [ Restore Selected ]                │
│                                                  │
└──────────────────────────────────────────────────┘
```

### CLI equivalent

```bash
# Restore everything (v3.2 — new flag, does not exist in v3.0 or v3.1)
claude-backup restore --all --json

# Restore config only (v3.0 — exists today, --json added in v3.0)
claude-backup import-config <backup-path> --json

# Restore specific sessions (v3.0 — exists today, --json added in v3.0)
claude-backup restore <uuid> --json
```

> **Note:** `restore --all` is a new v3.2 flag that restores all sessions at once. v3.0/v3.1 only support restoring by individual UUID. This means the "Restore Everything" button in claude-view is blocked on v3.2, not v3.1.

**`restore --all` implementation spec (v3.2):**

**Dispatch wiring:** `restore --all` is parsed inside the existing `cmd_restore()` function as a new mode branch. When `cmd_restore()` encounters `--all` in its argument parsing loop, it sets `mode="all"` and delegates to `cmd_restore_all()`. This mirrors the existing `--list` → `mode="list"` pattern already in `cmd_restore()`.

```bash
# Inside cmd_restore(), add to the argument parser (uses array-based index loop, NOT shift):
#   --all) mode="all" ;;

# The DEST_DIR guard ([ ! -d "$DEST_DIR" ]) must be bypassed for mode=all:
#   if [ "$mode" != "all" ] && [ ! -d "$DEST_DIR" ]; then fail "No backups found."; fi

# Three-way dispatch (replaces the existing two-way if/else):
#   if [ "$mode" = "all" ]; then
#     cmd_restore_all "$@"        # ← NEW: restore everything across machines
#   elif [ "$mode" != "uuid" ]; then
#     # Existing listing-mode block (list, last, date, project)
#     ...existing case "$mode" for query modes...
#   else
#     # Existing UUID-mode block (single session restore)
#     ...existing find + gzip -dkc logic...
#   fi

cmd_restore_all() {
  local force=false
  local source_machine=""  # optional: restore from specific machine only

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=true; shift ;;
      --machine) source_machine="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Scan all machine namespaces for .gz files
  # Path: machines/<slug>/projects/<project-hash>/<uuid>.jsonl.gz
  local search_path="$BACKUP_DIR/machines"
  if [ -n "$source_machine" ]; then
    search_path="$BACKUP_DIR/machines/$source_machine"
  fi

  local restored=0 skipped=0 failed=0
  while IFS= read -r -d '' gz_file; do
    local filename project_dir
    filename=$(basename "$gz_file" .gz)
    # dirname chain: .../machines/<slug>/projects/<project>/<file>
    #   dirname 1 → .../machines/<slug>/projects/<project>
    #   basename  → <project>
    project_dir=$(basename "$(dirname "$gz_file")")

    local target_dir="$SOURCE_DIR/$project_dir"
    local target_file="$target_dir/$filename"

    # Skip if file exists and --force not set
    if [ -f "$target_file" ] && [ "$force" != true ]; then
      skipped=$((skipped + 1))
      continue
    fi

    mkdir -p "$target_dir"
    if gzip -dkc "$gz_file" > "$target_file"; then
      restored=$((restored + 1))
    else
      failed=$((failed + 1))
    fi
  done < <(find "$search_path" -name "*.jsonl.gz" -type f -print0 2>/dev/null)

  info "Restore complete: $restored restored, $skipped skipped (already exist), $failed failed"

  # JSON output (v3.0 --json flag)
  if [ "$JSON_OUTPUT" = true ]; then
    printf '{"restored":%d,"skipped":%d,"failed":%d}\n' "$restored" "$skipped" "$failed"
  fi
}
```

**Behavior:**

- Iterates all `.jsonl.gz` files across all `machines/*/projects/` directories
- Existing sessions are **skipped by default** (not overwritten) — use `--force` to overwrite
- Optional `--machine <slug>` flag to restore from a specific machine only
- Returns counts of restored/skipped/failed for both human and `--json` output

### Mid-Work Recovery (Single Session)

If a user accidentally deletes a session during daily work, they don't need a new machine — they need single-session restore. This already works in v3.0:

```bash
# Browse available backups
claude-backup restore --list              # All backed-up sessions
claude-backup restore --last 10           # Last 10 sessions
claude-backup restore --date 2026-02-27   # Sessions from a specific date
claude-backup restore --project myapp     # Filter by project name

# Restore the deleted session
claude-backup restore <uuid>              # Restore to ~/.claude/projects/<project>/
claude-backup restore <uuid> --force      # Overwrite if file already exists
```

**How it works (v3.0, `cmd_restore()` in cli.sh):** Finds the matching `.jsonl.gz` file in `~/.claude-backup/projects/`, decompresses it with `gzip -dkc`, and writes the `.jsonl` file back to `~/.claude/projects/<project-hash>/`. The session is immediately available to Claude Code.

**In claude-view:** The "Restore from Backup" entry point in Settings serves both new-machine setup AND mid-work recovery. The UI flow is identical — the user selects what to restore regardless of why they need it.

> **Design note:** This follows the WhatsApp model correctly. WhatsApp's restore UI serves both "new phone" and "reinstalled app" — the entry point is the same. We don't need a separate "recover deleted session" flow; the existing restore commands cover it. The key insight is that restore is *rare* in both cases — the user goes there only when something went wrong, whether that's a new machine or an accidental deletion.

---

## How claude-view Talks to claude-backup

**Read operations:** claude-view's Rust backend reads files directly from `~/.claude-backup/`:

- `manifest.json` — last sync, machine name, session/config counts
- `session-index.json` — session list for browsing (if ever needed)

**Write operations:** claude-view shells out to the CLI with `--json`:

| Action               | CLI command                                      | Min version |
| -------------------- | ------------------------------------------------ | ----------- |
| "Back Up Now"        | `claude-backup sync --json`                      | v3.0        |
| "Change backend"     | `claude-backup backend set <mode> --json`        | **v3.2**    |
| "Change schedule"    | `claude-backup schedule <freq> --json`           | **v3.2**    |
| "Restore Everything" | `claude-backup restore --all --json`             | **v3.2**    |
| "Restore by UUID"    | `claude-backup restore <uuid> --json`            | v3.0        |
| "Import config"      | `claude-backup import-config <path> --json`      | v3.0        |

**Why both?** Reading files is instant (no process spawn). But mutations must go through the CLI to maintain the single-writer invariant — the CLI holds the lock, manages git, and ensures consistency.

> **Implication:** The backup settings screen can ship partially on v3.0 — status display, "Back Up Now" button, single-session restore, and config import all work. The backend picker, schedule picker, and "Restore Everything" require v3.2.
>
> **Version detection:** claude-view must call `claude-backup --version --json` (v3.0+) before using `--json` flags on any command. If the installed CLI is < v3.0, claude-view falls back to reading `manifest.json` directly and disables mutation buttons that require `--json` output. This prevents silent integration failures if a user hasn't updated their CLI.

---

## Relay Metadata Schema

What the relay server stores per user (for mobile status display):

```json
{
  "userId": "user_abc123",
  "backup": {
    "lastSyncAt": "2026-02-27T03:00:00Z",
    "sessionCount": 247,
    "projectCount": 15,
    "backupSizeBytes": 399769600,
    "configFileCount": 12,
    "backendMode": "github",
    "machineName": "MacBook Pro (Tom's)",
    "version": "3.2.0"
  }
}
```

> **Field mapping from `status --json`:** The relay consumes the CLI's `status --json` response directly. Field names match: `version` (not `cliVersion`), `mode` (mapped to `backendMode`), `machine` (mapped to `machineName`). The relay performs these renames at ingestion time.

**How it gets there:** After every `claude-backup sync`, if the user is authenticated with the relay, the CLI (or claude-view) posts this metadata. The session data itself never leaves the user's machine/GitHub.

---

## Multi-Machine Strategy (Resolved)

**Problem:** If a user has two Macs (work + personal) backing up to the same GitHub repo, they collide. Today, `DEST_DIR="$BACKUP_DIR/projects"` is hardcoded with no machine namespace. Two machines with the same project path and session UUID write to the exact same file, causing overwrites on push.

**Decision: Machine-namespaced directories.**

```text
# Before (v3.0 — single machine)
~/.claude-backup/
├── manifest.json
├── projects/
│   ├── -Users-tom-myapp/
│   │   └── session-abc.jsonl.gz
│   └── -Users-tom-otherapp/
│       └── session-def.jsonl.gz

# After (v3.2 — multi-machine)
~/.claude-backup/
├── manifest.json                          # This machine's metadata
├── machines/
│   ├── macbook-pro-work/                  # hostname-derived, slugified
│   │   ├── manifest.json                  # Per-machine metadata
│   │   └── projects/
│   │       ├── -Users-tom-myapp/
│   │       │   └── session-abc.jsonl.gz
│   │       └── -Users-tom-otherapp/
│   │           └── session-def.jsonl.gz
│   └── macbook-air-personal/
│       ├── manifest.json
│       └── projects/
│           └── -Users-tom-sideproject/
│               └── session-ghi.jsonl.gz
├── session-index.json                     # Aggregated across machines (already gitignored in v3.0)
```

**Why directories over branches:**

- **Branches diverge permanently** — two machines never merge, so you get infinite branch proliferation with no way to prune. This is unproven at scale; no major backup tool uses per-machine branches.
- **Directories are conflict-free** — each machine writes to its own namespace. `git pull --rebase` before push handles concurrent updates (no merge conflicts since machines write to disjoint directories). This is how **etckeeper** handles multi-host configs and how **yadm** suggests multi-machine dotfiles. **v3.2 must add `git pull --rebase` before `git push` in `cmd_sync()`** — today, `cmd_sync()` does not pull before pushing, which means concurrent multi-machine pushes will fail with "rejected — non-fast-forward". The upstream is already configured by `git push -u origin HEAD` (called in `cmd_sync()`), so no refspec is needed.
- **Single `git clone` gets all machines** — no need to fetch multiple branches on restore.

**Machine identifier:** The slug is computed from `hostname -s` (short hostname, avoids `.local` suffix variation) and **stored in `manifest.json` at init time**. On subsequent syncs, the slug is read from manifest — never recomputed. This prevents directory orphaning if the user renames their Mac in System Preferences.

```bash
machine_slug() {
  # Compute a filesystem-safe slug from the short hostname
  hostname -s | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-64
}

get_machine_slug() {
  # Read from manifest if available (stable across hostname renames), else compute
  local stored
  stored=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('machineSlug',''))" "$BACKUP_DIR/manifest.json" 2>/dev/null)
  if [ -n "$stored" ]; then
    echo "$stored"
  else
    machine_slug
  fi
}
```

> **Hostname mutability:** If a user renames their Mac, the old slug persists (read from manifest). This is intentional — the directory name is an identifier, not a display name. The human-readable `machine` field in manifest.json (raw `hostname` output) is separate and used only for display on the relay and in claude-view. If a user truly wants to rename their machine slug, they must manually rename the directory and update `machineSlug` in manifest.json.

**DEST_DIR update:** After migration, `DEST_DIR` must point to the new location. v3.2 changes the variable to be dynamic:

```bash
# v3.0 (hardcoded):
# DEST_DIR="$BACKUP_DIR/projects"

# v3.2 (dynamic — reads machine slug):
DEST_DIR="$BACKUP_DIR/machines/$(get_machine_slug)/projects"
```

Most functions that reference `DEST_DIR` (`write_manifest()`, `cmd_restore()`, `cmd_sync()`) automatically use the new path after this change — they all read the global `DEST_DIR`.

**Exception: `build_session_index()` requires modification.** Today it scans only `$DEST_DIR` (this machine's projects). In v3.2, to populate the `machine` field per session entry and to support cross-machine `restore --all`, it must scan `$BACKUP_DIR/machines/*/projects/` instead of `$DEST_DIR`. Each session entry gains a `machine` field derived from the slug directory name (e.g., `"machine": "macbook-pro-work"`).

**Migration path (v3.0 → v3.2):** On first `sync` after upgrade, the CLI detects the old flat `projects/` structure and migrates automatically:

```bash
# Pseudocode for migrate_to_namespaced()
migrate_to_namespaced() {
  if [ -d "$BACKUP_DIR/projects" ] && [ ! -d "$BACKUP_DIR/machines" ]; then
    local slug
    # Must call machine_slug() directly — machineSlug not yet in manifest at migration time.
    # get_machine_slug() would fall through to machine_slug() anyway, but this is explicit.
    slug=$(machine_slug)

    # 1. Create machine directory
    mkdir -p "$BACKUP_DIR/machines/$slug"

    # 2. Move projects into machine namespace
    mv "$BACKUP_DIR/projects" "$BACKUP_DIR/machines/$slug/projects"

    # 3. Persist slug immediately so get_machine_slug() can read it on next sync.
    # Use python3 to patch the existing manifest.json with machineSlug field.
    python3 -c "
import json, sys
path = sys.argv[1]
slug = sys.argv[2]
m = json.load(open(path))
m['machineSlug'] = slug
json.dump(m, open(path, 'w'), indent=2)
" "$BACKUP_DIR/manifest.json" "$slug"

    # 4. Update DEST_DIR for the rest of this sync
    DEST_DIR="$BACKUP_DIR/machines/$slug/projects"

    # 5. Commit the migration
    cd "$BACKUP_DIR"
    git add -A && git commit -m "migrate: namespace projects under machines/$slug"
  fi
}
```

> **Rollback:** If migration fails partway (e.g., `mv` succeeds but manifest patch fails), the recovery steps are:
>
> ```bash
> cd ~/.claude-backup
> mv "machines/<slug>/projects" projects   # Move projects back to flat layout
> rmdir -p "machines/<slug>" 2>/dev/null   # Remove empty machine directories
> git checkout -- manifest.json            # Restore original manifest
> git clean -fd machines/                  # Remove any leftover machine dirs
> ```
>
> Since the migration commits atomically (`git add -A && git commit`), a partial failure before the commit means `git checkout -- .` restores the pre-migration state. A failure after commit means `git revert HEAD` undoes the migration cleanly.

**`write_manifest()` changes:** v3.2 adds the `machineSlug` field and changes the write target:

1. **Primary write:** `$BACKUP_DIR/machines/$slug/manifest.json` — per-machine manifest. Contains all existing fields (`version`, `machine`, `user`, `lastSync`, `config`, `sessions`) plus the new `machineSlug` field. This is the source of truth for this machine.

2. **Root manifest** at `$BACKUP_DIR/manifest.json` — **backward-compatible.** Retains all current-machine fields at the top level (so `read_backup_mode()`, `get_machine_slug()`, and `cmd_status_json()` continue to work without modification), AND adds a `machines` array for multi-machine aggregation. Schema:

   ```json
   {
     "version": "3.2.0",
     "mode": "github",
     "machine": "MacBook-Pro.local",
     "machineSlug": "macbook-pro-work",
     "user": "tombelieber",
     "lastSync": "2026-02-27T03:00:00Z",
     "config": { "files": 12, "sizeBytes": 49152 },
     "sessions": { "files": 247, "projects": 15, "sizeBytes": 399769600 },
     "machines": [
       {
         "slug": "macbook-pro-work",
         "machine": "MacBook-Pro.local",
         "lastSync": "2026-02-27T03:00:00Z",
         "sessionCount": 247,
         "backupSizeBytes": 399769600
       }
     ]
   }
   ```

   The top-level fields are this machine's data (same as v3.0 format, plus `machineSlug`). The `machines` array is built by scanning `machines/*/manifest.json` and aggregating all known machines. This dual structure follows the **kubectl config** pattern: top-level `current-context` for the active context, plus a `contexts` array listing all.

   > **Why backward-compatible:** `read_backup_mode()` reads `mode` from the root manifest. `get_machine_slug()` reads `machineSlug` from the root manifest. Both would silently break if the root manifest changed to a machines-only schema. By keeping current-machine fields at the top level, zero existing readers need modification.

3. **`status --json` reads:** `cmd_status_json()` continues to read `$BACKUP_DIR/manifest.json` (the root). This works because the root manifest retains all per-machine fields at the top level for the current machine.

**Impact on restore and peek:** `restore --all` (v3.2) must scan all `machines/*/projects/` directories. `restore <uuid>` and `cmd_peek()` must both search across machine namespaces. Today, both functions use `find "$DEST_DIR"` which only finds sessions in the current machine's namespace. v3.2 must update both:

```bash
# In cmd_restore() UUID mode — replace:
#   find "$DEST_DIR" -name "$uuid*.gz" ...
# with:
#   find "$BACKUP_DIR/machines" -name "$uuid*.gz" -type f 2>/dev/null
# This finds the session regardless of which machine backed it up.

# In cmd_peek() — same change:
#   find "$DEST_DIR" -name "$uuid*.gz" ...
# with:
#   find "$BACKUP_DIR/machines" -name "$uuid*.gz" -type f 2>/dev/null
```

The session-index.json gains a `machine` field per entry.

**Impact on relay:** The relay's `machineName` field uses the raw `hostname` value for human-readable display. The filesystem slug (`get_machine_slug()`) is a normalized form used only for directory naming and is never sent to the relay. Multi-machine users post separate metadata per machine. The mobile app shows a machine picker if multiple machines are present.

> **Limitation (v3.2):** Cross-machine session deduplication is not handled. If the same session somehow exists on two machines, both copies are kept. This is correct — machines may have different versions of the same session.

---

## Storage Ceiling & Retention (Resolved)

**GitHub's soft limit:** GitHub recommends repositories stay under **5 GB** (hard push limit is ~100 GB but triggers warnings at 5 GB). Power users with hundreds of long sessions will eventually approach this.

**Current state (v3.0):** No `git gc`, no pruning, no size warnings anywhere in the codebase. Sessions are compressed (`.jsonl.gz`) which helps — typical compression ratio is 5-10x for JSONL.

**v3.2 additions:**

1. **Size warning in `sync`:** After `git push` (inside the existing `cd "$BACKUP_DIR"` block in `cmd_sync()`), if total backup size exceeds 2 GB, emit a warning:

   ```bash
   # Insert after git push in cmd_sync(), inside the mode != "local" branch
   total_bytes=$(dir_bytes "$BACKUP_DIR")
   if [ "$total_bytes" -gt 2147483648 ]; then  # 2 GB
     total_mb=$(( total_bytes / 1048576 ))
     warn "Backup size is ${total_mb} MB. Remote repos typically have a 5 GB soft limit."
     warn "Consider pruning old sessions: claude-backup prune --older-than 6m"
   fi
   ```

   > **Placement:** This check runs only in `github` and `git` modes (after push). Local-mode users have no remote size limit, so the warning is not shown. The message avoids naming "GitHub" specifically since custom git remotes (GitLab, Bitbucket) have different limits.
   >
   > **Note:** `dir_bytes()` in cli.sh uses `stat -f %z` which is macOS-specific. When Linux support is added (v4+), this must be replaced with `stat -c %s`.

2. **`git gc` on sync:** Run `git gc --auto` after push, inside the existing `cd "$BACKUP_DIR"` block in `cmd_sync()`. Git's built-in heuristic — only packs if needed. This is a no-op most of the time, zero cost.

3. **Retention / pruning deferred to v3.3.** The `prune` command is not in scope for v3.2, but the warning message references it to set user expectations. WhatsApp doesn't prune; iCloud prunes when storage is full. Our model: warn at 2 GB, user decides.

> **Precedent:** Git's own documentation recommends periodic `git gc`. GitHub runs server-side GC automatically but client-side pack files still bloat without `gc --auto`. Homebrew runs `git gc --auto` after installs.

---

## What Ships Where and When

### This repo (claude-backup CLI)

| Version  | What | Status |
| -------- | ---- | ------ |
| **v3.0** | Selective restore (`--list`, `--last`, `--date`, `--project`) | Shipped |
| **v3.1** | `--json` on all commands, local mode, `peek`, plugin/skill | Shipped (v3.1.0) |
| **v3.2** | `backend set`, `schedule`, `restore --all`, custom git remote, upgrade path, multi-machine namespacing, `git gc --auto`, size warnings | Designed (this doc) |

### claude-view

| Feature                | Depends on                          | Status               |
| ---------------------- | ----------------------------------- | -------------------- |
| Backup settings screen | v3.0 (`--json` + `status --json`)   | Needs implementation |
| Backend picker UI      | v3.2 (`backend set` command)        | Blocked on v3.2      |
| Schedule picker UI     | v3.2 (`schedule` command)           | Blocked on v3.2      |
| Restore flow UI        | v3.2 (`restore --all`)              | Blocked on v3.2      |

### Relay server

| Feature              | Depends on                                       | Status          |
| -------------------- | ------------------------------------------------ | --------------- |
| Backup metadata sync | v3.1 + relay auth + `machineName` in status JSON | Needs design    |
| Mobile backup status | Relay metadata                                   | Needs design    |
| Multi-machine picker | v3.2 (machine-namespaced directories)            | Blocked on v3.2 |

---

## What's NOT in Scope

- Server-side backup storage — user data stays in their infrastructure
- End-to-end encryption — valuable but separate design (v4 territory)
- Session-level backup granularity in UI — WhatsApp doesn't let you pick individual chats to back up; neither do we
- iCloud Drive as a backend — not yet designed; potential future option
- Linux systemd scheduler — launchd only for now (macOS)
- `peek` in the UI — `peek` remains an agent-facing CLI tool (via the skill); the WhatsApp model doesn't expose individual session browsing in the backup screen
- Backup retention / `prune` command — deferred to v3.3. v3.2 adds size warnings only
- Cross-machine session deduplication — each machine keeps its own copy; no merge logic

---

## Open Questions

1. **Relay metadata push:** Should `claude-backup sync` post metadata directly to the relay, or should claude-view's Rust backend handle it on the next dashboard open?
2. ~~**Multi-machine:**~~ **Resolved.** Machine-namespaced directories under `machines/<slug>/projects/`. See "Multi-Machine Strategy" section above.
3. ~~**Backup retention:**~~ **Partially resolved.** v3.2 adds size warnings at 2 GB. `prune` command deferred to v3.3. See "Storage Ceiling & Retention" section above.
4. ~~**`launchctl load/unload` deprecation timeline:**~~ **Resolved.** The `bootstrap/bootout` API was introduced in macOS 10.10 (2014). Claude Code's minimum supported macOS is 12+. No fallback to `load/unload` is needed. v3.2 uses `bootout/bootstrap` exclusively.

---

## Changelog of Fixes Applied (Audit)

### Round 1

| # | Issue | Severity | Fix |
| --- | --- | --- | --- |
| 1 | `status/sync/restore --json` don't exist in v3.0 | Blocker | Every CLI command annotated with min version |
| 2 | `restore --all` flag doesn't exist in v3.0 or v3.1 | Blocker | Labeled v3.2; fixed dependency table |
| 3 | `backend set` used without version qualifier | Blocker | Added "(v3.2 CLI command)" inline |
| 4 | `init --backend` flags don't exist yet | Blocker | Labeled "v3.2 target" with current behavior noted |
| 5 | Auto-backup frequency hardcoded, no CLI support | Blocker | Added v3.2 `schedule` command requirement |
| 6 | `machineName` missing from v3.1 `status --json` | Blocker | Added gap callout; required v3.1 addition |
| 7 | v3.1 `remote github` renamed to `backend set` | Medium | Documented the rename explicitly |
| 8 | v3.1 `--local` vs v3.2 `--backend local` | Medium | Keep `--local` as alias |
| 9 | Custom git remote has no `mode` enum value | Medium | Added Mode enum column: `local`, `github`, `git` |
| 10 | No target version declared | Medium | Added `Target Version: 3.2.0` |
| 11 | Relay `cliVersion` vs v3.1 `version` key mismatch | Minor | Unified to `version`; added field mapping note |
| 12 | Restore flow UI dependency wrong (said v3.1) | Medium | Fixed: depends on v3.2 |
| 13 | `peek` command unmentioned | Minor | Added to "Not in Scope" (agent-facing only) |
| 14 | `schedule` command missing from shipping table | Minor | Added to v3.2 CLI and claude-view tables |
| 15 | Relay dependency missing `machineName` prereq | Medium | Fixed: "v3.1 + relay auth + machineName" |

### Round 2 (Prove-It Audit)

Triggered by adversarial audit against 9 claims. 4 flags found, all resolved.

| # | Claim | Issue | Severity | Fix |
| --- | --- | --- | --- | --- |
| 16 | Restore = setup only (Claim 5) | Doc says "setup-time experience on a new machine" but `restore <uuid>` already works mid-work in v3.0. No answer for accidental session deletion | Blocker | Added "Mid-work Recovery" subsection documenting `restore --list/--last/--date/--project` + `restore <uuid>`. Updated Design Principle #4 to say "primarily a setup event." Noted claude-view restore entry point serves both cases |
| 17 | launchd plist rewriting (Claim 8) | Doc says "rewrites the plist" but omits `launchctl bootout/bootstrap` lifecycle. Current code uses deprecated `load/unload` with silent error suppression | Blocker | Added full `schedule` command spec: frequency-to-plist mapping, 5-step `bootout → rewrite → plutil lint → bootstrap → verify` lifecycle, manifest.json storage. Noted Homebrew precedent for `bootout/bootstrap` |
| 18 | Multi-machine (Claim 9) | Listed as "open question" with hand-waved "branches or namespaced directories" — but `DEST_DIR` is hardcoded, two machines collide on same repo | Blocker | Resolved: machine-namespaced directories (`machines/<slug>/projects/`). Added full section with directory structure, `machine_slug()` function, migration pseudocode, impact on restore/relay. Rejected branches (permanent divergence, unproven). Added to shipping table |
| 19 | GitHub 5GB ceiling (Claim 6) | No `git gc`, no pruning, no size warnings in codebase. Power users will hit GitHub's 5GB limit | Medium | Added "Storage Ceiling & Retention" section: 2GB warning threshold in `sync`, `git gc --auto` after push, `prune` deferred to v3.3. Added to "Not in Scope" |
| 20 | `schedule_launchd()` uses deprecated `load/unload` | Current code uses deprecated launchctl API | Medium | v3.2 spec requires migration to `bootout/bootstrap`. Added open question about fallback for older macOS |
| 21 | Relay table missing multi-machine row | Relay server shipping table had no entry for multi-machine | Minor | Added "Multi-machine picker" row: depends on v3.2, blocked |
| 22 | Open Questions stale after resolutions | Questions #2 and #3 answered by new sections but still listed as open | Minor | Struck through resolved questions with links to new sections. Added question #4 (launchctl deprecation timeline) |

### Round 3 (Adversarial Review — 7 blockers, 8 warnings)

Initial adversarial score: 52/100. All issues resolved below.

| # | Issue | Severity | Fix |
| --- | --- | --- | --- |
| 23 | `human_size()` phantom function in size warning code block | Blocker | Replaced with inline `$(( total_bytes / 1048576 )) MB`. Added note that `dir_bytes()` is macOS-specific |
| 24 | launchd service label mismatch: `PLIST_NAME="com.claude-backup.plist"` used as label but bootout/bootstrap expect `com.claude-backup` | Blocker | Added step 2 to schedule spec: standardize `SERVICE_LABEL="com.claude-backup"` separate from `PLIST_PATH`. Noted `cmd_status` must also update |
| 25 | `write_plist()` phantom function in schedule spec | Blocker | Renamed to `generate_plist()` with explicit note it must be extracted from existing `schedule_launchd()` heredoc and parameterized |
| 26 | Design Principle #4 only mentions `restore <uuid>`, omits browsing capabilities | Blocker | Expanded to: "Session browsing (`restore --list/--last/--date/--project`) and single-session recovery (`restore <uuid>`) are available anytime" |
| 27 | `DEST_DIR` becomes stale after migration — `write_manifest()`, `build_session_index()`, `cmd_restore()` all break | Blocker | Added dynamic `DEST_DIR` spec: `$BACKUP_DIR/machines/$(get_machine_slug)/projects`. Added `DEST_DIR` update to migration pseudocode |
| 28 | `hostname` can change if user renames Mac — orphans old machine directory | Blocker | Store slug in manifest at init time via `get_machine_slug()`. Read from manifest on subsequent syncs, never recompute. Documented limitation explicitly |
| 29 | `restore --all` has no implementation spec — zero pseudocode, no collision handling, no JSON shape | Blocker | Added full `cmd_restore_all()` spec with: flag parsing, machine-namespace scanning, skip-by-default collision handling, `--force` and `--machine` flags, JSON output shape |
| 30 | Stale line number references (off by ~44 lines) | Warning | Removed all `cli.sh:NNN` line references from design doc — they drift on every edit |
| 31 | `git gc --auto` missing working directory context | Warning | Added "inside the existing `cd "$BACKUP_DIR"` block in `cmd_sync()`" |
| 32 | Relay `machineName` (raw hostname) vs filesystem `machine_slug()` inconsistency undocumented | Warning | Added note: relay uses raw hostname for display, slug is for directory naming only |
| 33 | `backend set` has no pre-flight validation spec | Warning | Added full pre-flight spec for each mode: github (gh auth, repo create, test push), git (ls-remote, test push), local (remove remote) |
| 34 | Mode enum `git` not handled in existing cli.sh branch guards | Warning | Added implementation note: every `if [ "$mode" = "github" ]` must add `git` arm |
| 35 | Principle #5 doesn't define "session data" vs "metadata" | Warning | Added parenthetical: "Session data = `.jsonl.gz` files. Metadata = manifest.json, session-index.json, counts/timestamps/machine name" |
| 36 | session-index.json annotated as gitignored without noting it's already in v3.0 | Minor | Changed annotation to "(already gitignored in v3.0)" |
| 37 | claude-view has no version detection before using `--json` flags | Warning | Added version detection spec: call `--version --json` first, fall back to manifest.json if < v3.0 (corrected from `< v3.1` in #63) |
| 38 | Open Question #4 (launchctl fallback) is self-contradictory and irrelevant for macOS 12+ | Warning | Resolved and struck through: bootstrap/bootout introduced in macOS 10.10, min macOS is 12+, no fallback needed |

### Round 4 (Final Adversarial Review)

Initial adversarial score: 72/100. All issues resolved below.

| # | Issue | Severity | Fix |
| --- | --- | --- | --- |
| 39 | `get_machine_slug()` shell injection: `$BACKUP_DIR` with single quotes in `python3 -c` breaks | Critical | Changed to `sys.argv[1]` pattern: `python3 -c "import json,sys; ..." "$BACKUP_DIR/manifest.json"` |
| 40 | `error()` phantom function in schedule spec — should be `fail()` | Critical | Replaced `error` with `fail` (which calls `exit 1`, matching existing cli.sh pattern) |
| 41 | `cmd_restore_all()` not wired into dispatch table — no spec for routing `--all` | Critical | Added dispatch wiring: `--all` parsed as `mode="all"` inside `cmd_restore()`, mirrors existing `--list` → `mode="list"` pattern |
| 42 | `migrate_to_namespaced()` never persists `machineSlug` — `write_manifest()` doesn't know about the field | Important | Added inline python3 patch to persist `machineSlug` immediately during migration, before `write_manifest()` runs |
| 43 | `machine_dir` extracted with wrong dirname depth — gives `projects` not machine slug | Important | Removed unused `machine_dir` variable from `cmd_restore_all()`. Only `project_dir` is needed for restore target path |
| 44 | Size warning hardcodes "GitHub" and placement is ambiguous for local/git modes | Important | Changed message to "Remote repos typically have a 5 GB soft limit." Added placement note: runs only in github/git modes, not local |
| 45 | `cmd_status_json()` and `cmd_uninstall()` also use `PLIST_NAME`/deprecated API but not mentioned in fix spec | Important | Expanded step 2: "Update all three consumers: `cmd_status()`, `cmd_status_json()`, and `cmd_uninstall()`" |
| 46 | Three `cli.sh:NNN` line references survived Round 3 (lines 190, 207, 578) | Minor | Removed all remaining line number references |
| 47 | `backend set github` "add git remote" fails if remote already exists | Minor | Changed to idempotent pattern: `git remote set-url` if exists, `git remote add` if not |
| 48 | `JSON_OUTPUT` check uses `"true"` (quoted) vs codebase convention `true` (unquoted) | Minor | Changed to unquoted `= true` to match cli.sh convention |
| 49 | `machineName` gap not tracked in v3.1 design doc — cross-doc dependency will be silently dropped | Minor | Added "Cross-doc dependency (ACTION REQUIRED)" callout with explicit instruction to update v3.1 design doc |
| 50 | `write_manifest()` dual-write spec underspecified: no schema, no `status --json` read target | Minor | Added full spec: per-machine manifest (source of truth), backward-compatible root manifest (retains current-machine fields + aggregation), `cmd_status_json()` reads root manifest (corrected in Round 5) |

### Round 5 (Final Adversarial Review)

Initial adversarial score: 74/100. Root cause: dual-write manifest schema broke existing readers.

| # | Issue | Severity | Fix |
| --- | --- | --- | --- |
| 51 | `read_backup_mode()` breaks: root manifest lost `mode` field in v3.2 schema | Critical | Redesigned root manifest to be backward-compatible: retains all current-machine fields at top level (`mode`, `machineSlug`, etc.) PLUS adds `machines` array. Follows kubectl config pattern (`current-context` + `contexts[]`). Zero existing readers need modification |
| 52 | `get_machine_slug()` reads wrong manifest: root manifest lost `machineSlug` | Critical | Same fix as #51 — root manifest retains `machineSlug` at top level. `get_machine_slug()` continues reading from `$BACKUP_DIR/manifest.json` unchanged |
| 53 | `build_session_index()` falsely excluded from "no modifications needed" list | Important | Removed from the list. Added spec: must scan `$BACKUP_DIR/machines/*/projects/` instead of `$DEST_DIR`, add `machine` field per session entry |
| 54 | `--all) mode="all"; shift` uses wrong idiom for array-based parser in `cmd_restore()` | Important | Removed `shift` — existing parser uses array index loop, not positional params |
| 55 | `DEST_DIR` guard fires before `restore --all` dispatch on new machine | Important | Added guard bypass: `if [ "$mode" != "all" ] && [ ! -d "$DEST_DIR" ]` |
| 56 | `git pull --rebase` stated as justification for directories-over-branches but never specced in `cmd_sync()` | Important | Added explicit requirement: v3.2 must add `git pull --rebase` before `git push` in `cmd_sync()` (corrected from `origin HEAD` in #66) |
| 57 | Two `cli.sh:NNN` refs survived in problem statement and changelog | Minor | Removed both: `(cli.sh:8)` from multi-machine section, `(cli.sh:183-184)` from Round 2 changelog |

### Round 6 (Final Polish)

Initial adversarial score: 93/100. Four issues remaining.

| # | Issue | Severity | Fix |
| --- | --- | --- | --- |
| 58 | Changelog entry #50 says `cmd_status_json()` reads per-machine manifest; body says root manifest — contradiction | Critical | Corrected changelog #50 to say "reads root manifest (corrected in Round 5)". Body at line 603 is authoritative |
| 59 | `cmd_peek()` missing from multi-machine impact section — same `find "$DEST_DIR"` pattern as `cmd_restore()` | Important | Added `cmd_peek()` alongside `restore <uuid>` in "Impact on restore and peek" paragraph |
| 60 | `cmd_restore_all()` `find` missing `-type f` and `2>/dev/null` — inconsistent with every other `find` in cli.sh | Minor | Added `-type f -print0 2>/dev/null` to match codebase convention |
| 61 | `migrate_to_namespaced()` calls `machine_slug()` without comment explaining why not `get_machine_slug()` | Minor | Added comment: "Must call machine_slug() directly — machineSlug not yet in manifest at migration time" |

### Round 7 (Final Review)

Initial adversarial score: 97/100. Two issues remaining.

| # | Issue | Severity | Fix |
| --- | --- | --- | --- |
| 62 | "Not in Scope" says iCloud Drive is "listed as 'coming soon' in picker" but the Backend Picker wireframe has no iCloud option | Minor | Changed to "not yet designed; potential future option" |
| 63 | claude-view table lists `sync --json`, `restore <uuid> --json`, `import-config --json` as min version v3.1, but `--json` global flag shipped in v3.0 | Important | Updated min versions to v3.0. Updated implication note: v3.0 is the minimum for status display + "Back Up Now" + single restore + config import. Updated version detection threshold to v3.0 |

### Round 8 (Adversarial Review)

Initial adversarial score: 72/100. Seven issues found; all resolved below.

| # | Issue | Severity | Fix |
| --- | --- | --- | --- |
| 64 | cli.sh VERSION is `3.1.0` but design doc says v3.1 is "Designed, not implemented" | Critical | Updated header to "shipped in v3.1.0". Updated shipping table to "Shipped (v3.1.0)" |
| 65 | `status --json` missing `machine` field framed as future v3.1 work, but v3.1 is already shipped | Critical | Reframed gap as "live in v3.1.0" — v3.2 must add the field. Removed reference to "must be added to v3.1" |
| 66 | `git pull --rebase origin HEAD` is non-standard — `HEAD` is not a valid remote refspec | Important | Changed to `git pull --rebase` (uses configured upstream from `git push -u`). Added note explaining upstream is already configured |
| 67 | `restore --all` dispatch wiring is ambiguous — unclear where `cmd_restore_all` is called relative to existing listing/UUID branches | Important | Added explicit three-way dispatch code snippet: `mode = "all"` → `cmd_restore_all`, listing modes, UUID mode |
| 68 | `restore <uuid>` and `cmd_peek()` cross-machine search stated in prose but no implementation code | Important | Added code snippets showing `find "$BACKUP_DIR/machines"` replacement for both functions |
| 69 | `migrate_to_namespaced()` has no rollback documentation | Important | Added rollback section with step-by-step recovery commands, plus note about atomic commit guaranteeing `git checkout -- .` safety |
| 70 | `schedule` lifecycle code block doesn't handle the `off` early-exit case | Minor | Added `if [ "$frequency" = "off" ]` early-exit branch before the 5-step lifecycle |
| 71 | `cmd_restore_all()` comment says "v3.1 --json flag" but `--json` shipped in v3.0 | Minor | Changed comment to "v3.0 --json flag" |
| 72 | Restore flow section says "--json requires v3.1" but it requires v3.0 | Minor | Changed to "--json added in v3.0" |

### Round 9 (Adversarial Review)

Initial adversarial score: 92/100. Five stale-text issues found; all resolved below.

| # | Issue | Severity | Fix |
| --- | --- | --- | --- |
| 73 | Config restore comment still says "--json requires v3.1" — fix from #72 missed this line | Important | Changed to "--json added in v3.0" |
| 74 | Cross-doc ACTION REQUIRED says "v3.1 is not yet implemented — fix must be applied before v3.1 ships" but v3.1 is shipped | Important | Rewritten: "Since v3.1 is already shipped (v3.1.0), the machine field must be added to cmd_status_json() as part of v3.2 implementation" |
| 75 | claude-view features table says "Depends on v3.1" for Backup settings screen, contradicting implication note that says v3.0 | Important | Changed to "v3.0 (`--json` + `status --json`)" |
| 76 | Changelog #56 retained stale `origin HEAD` after being superseded by #66 | Minor | Added "(corrected from `origin HEAD` in #66)" to entry #56 |
| 77 | Changelog #37 retained stale "< v3.1" threshold after #63 changed it to v3.0 | Minor | Added "(corrected from `< v3.1` in #63)" to entry #37 |
| 78 | Data source section says "Before v3.1" / "After v3.1" but v3.0 already has `--json` | Minor | Changed to "Before v3.0 (legacy fallback)" / "v3.0+ (current)" |
