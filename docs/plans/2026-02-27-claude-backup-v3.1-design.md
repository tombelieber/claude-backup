# claude-backup v3.1 Design: Agent-Optimized Plugin + User Trust

**Date:** 2026-02-27
**Status:** Approved
**Depends on:** v3.0 (selective restore — in progress)

---

## Problems

Two audiences, two problems:

**For the agent (operator):** The CLI outputs ANSI-colored tables designed for human eyes. Agents waste tokens parsing text, and the interface is fragile if output format changes.

**For the human (end user):** The tool requires GitHub, blocking users who don't use it or don't want to push sensitive sessions to any remote. And once installed, backups are opaque — users can't see, browse, or verify what's been backed up. This erodes trust.

## Design Principles

> The human decides to install it. The agent operates it. Optimize for both.
>
> Users must be able to **see it, touch it, feel it** before they trust it.

## Solution

Five changes shipping together as v3.1:

1. **`--json` flag on every command** — structured output the agent can parse without regex
2. **Claude Code plugin** — bundles a skill that teaches the agent how to operate the CLI
3. **Local-only mode** — backup without GitHub, zero external requirements
4. **`peek` command** — view session contents, making backups tangible
5. **Contract test + Lefthook + CI** — enforces that the skill stays in sync with the CLI

## Approach Rationale

**Why JSON CLI + thin skill (Approach B)?**

- Proven pattern: GitHub CLI (`gh`), Docker CLI, Vercel CLI, Stripe CLI, `kubectl` — every serious developer CLI has `--json`. No one invents a custom protocol.
- The skill becomes trivial (~40 lines) once the CLI speaks JSON.
- Scripting and automation work for free — not just agents.
- MCP server (Approach C) duplicates logic or shells out anyway. Can be added later if needed, wrapping the JSON CLI.

---

## 1. Local-Only Mode (Backend Abstraction)

### Problem

The tool requires `gh` (GitHub CLI, authenticated). This blocks:
- Users who use GitLab/Bitbucket/self-hosted git
- Users who don't want sessions pushed to any remote (privacy)
- Users who just want local safety (the simplest case)

### Solution

Two modes: `github` (default when `gh` is available) and `local` (no remote).

**Setup behavior:**

```
npx claude-backup           # detects gh → GitHub mode (current behavior)
npx claude-backup           # no gh → offers local mode automatically
npx claude-backup --local   # force local mode, skip GitHub entirely
```

The decision tree during `cmd_init`:

1. If `--local` flag → local mode, skip all GitHub steps
2. Else if `gh` is installed and authenticated → GitHub mode (current behavior)
3. Else → print "GitHub CLI not found. Setting up local-only backup." → local mode

**What changes in local mode:**
- No `gh repo create`, no `git remote add`, no `git push`
- `cmd_sync` commits locally but never pushes
- `cmd_status` shows "Mode: local" instead of repo URL
- Everything else is identical — same compression, same index, same restore

**Implementation:**

A `BACKUP_MODE` variable (`github` or `local`) stored in `manifest.json`:

```json
{
  "version": "3.1.0",
  "mode": "local",
  ...
}
```

Read at startup from manifest. Functions that touch the remote (`git push`, `gh repo create`) are guarded:

```bash
if [ "$BACKUP_MODE" = "github" ]; then
  git push -u origin HEAD -q
fi
```

**Critical refactor: `check_requirements` must be split.** The current `check_requirements()` hard-exits (`fail` → `exit 1`) if `gh` is missing or unauthenticated. This makes graceful local-mode fallback impossible. Split into:

- `check_core_requirements()` — checks `git` and `gzip` only. Hard-fails if missing (these are always required).
- `detect_github_available()` — probes `gh` installation and auth. Returns 0 if available, 1 if not. **Does not exit.** Two distinct failure cases: (a) `gh` not installed, (b) `gh` installed but not authenticated — both silently fall back to local mode per the UX principle "never ask the user to make a decision about something they don't understand yet."

`cmd_init` restructured:

```bash
cmd_init() {
  check_core_requirements  # exits on failure (git/gzip missing)

  if [ "$FORCE_LOCAL" = true ]; then
    BACKUP_MODE="local"
  elif detect_github_available; then
    BACKUP_MODE="github"
  else
    info "GitHub CLI not available. Setting up local-only backup."
    BACKUP_MODE="local"
  fi
  # ... rest of init uses BACKUP_MODE to branch
}
```

`cmd_status` must also branch on mode — skip `git remote get-url origin` in local mode (it would return "unknown" since there's no remote). Instead show `Mode: local (no remote)`.

**Future extensibility:** The `mode` field in manifest is the hook for v4 backends (S3, GitLab, etc.). Each mode is a set of functions: `backend_init`, `backend_push`, `backend_pull`. For v3.1 we just inline the two modes.

### Upgrade path

A `local` user who later installs `gh` can upgrade:

```
claude-backup remote github
```

This adds the remote, pushes existing history, and flips `mode` to `github`. Not in v3.1 scope — just mentioning to show the abstraction supports it.

---

## 2. `peek` Command — Making Backups Tangible

### Problem

Users can't see what's in their backups. The data is opaque `.jsonl.gz` files. There's no way to verify "yes, that conversation I had about the auth bug is safely backed up."

### Solution

```
claude-backup peek <uuid>
```

Shows a summary of the session — first and last few messages, enough to recognize it.

**Human output:**

```
Session: abc123-def456
Project: -Users-foo-myapp
Date:    2026-02-27T01:00:00Z
Size:    12K (compressed) → 48K (uncompressed)

── First messages ──────────────────────────────────────
  [user]  Help me debug the authentication middleware
  [assistant]  I'll look at the auth middleware. Let me...

── Last messages ───────────────────────────────────────
  [assistant]  The fix is deployed. The issue was...
  [user]  Perfect, thanks!

Messages: 47 total
```

**JSON output (`--json`):**

```json
{
  "uuid": "abc123-def456",
  "projectHash": "-Users-foo-myapp",
  "backedUpAt": "2026-02-27T01:00:00Z",
  "sizeBytes": 12000,
  "uncompressedBytes": 48000,
  "messageCount": 47,
  "firstMessages": [
    {"role": "user", "preview": "Help me debug the authentication middleware"},
    {"role": "assistant", "preview": "I'll look at the auth middleware. Let me..."}
  ],
  "lastMessages": [
    {"role": "assistant", "preview": "The fix is deployed. The issue was..."},
    {"role": "user", "preview": "Perfect, thanks!"}
  ]
}
```

**Implementation:**

1. Find the `.gz` file by UUID (same logic as `cmd_restore`)
2. Use `python3` with `gzip.open()` to read directly (no temp file needed)
3. Parse JSONL, filter to message records, deduplicate, extract previews
4. Truncate message previews to ~80 chars

**Session JSONL format (verified against actual files):**

Each line is a JSON object with a `type` field. The file contains many record types:

| `type` value | Description | Relevant to peek? |
| --- | --- | --- |
| `"user"` | User message | Yes |
| `"assistant"` | Assistant message (may be streaming chunks) | Yes |
| `"queue-operation"` | Lock/unlock operations | No — filter out |
| `"file-history-snapshot"` | File edit tracking | No — filter out |
| `"progress"` | Hook events (SessionStart, PreToolUse) | No — filter out |
| `"system"` | System events | No — filter out |
| `"summary"` | Session summary (has `summary` + `leafUuid`, no `message` key) | No — filter out |

**Critical format details:**

- Type is `"user"`, NOT `"human"`. A filter for `type == "human"` matches zero lines.
- `role` and `content` are nested under `entry["message"]`, not at the top level: `entry["message"]["role"]` and `entry["message"]["content"]`.
- `content` can be a plain string (in subagent/compact contexts) or a list of typed blocks.
- Content blocks include `{"type": "thinking", ...}`, `{"type": "tool_use", ...}`, `{"type": "tool_result", ...}`, `{"type": "text", "text": "..."}`. The `peek` parser must extract the first `type == "text"` block, skipping thinking/tool_use/tool_result.
- Assistant messages emit multiple streaming chunk lines with the same `message.id`. Each chunk contains a **different content block** (e.g. chunk 1 = thinking, chunk 2 = text, chunk 3 = tool_use) — they are NOT progressive snapshots. `stop_reason` is `null` on all chunks. Must **merge all entries** sharing a `message.id` into a single combined content block list, then extract text from the merged result. "Keep last" is WRONG — it discards text when the final chunk is a tool_use.

**Reference parser skeleton:**

```python
import json, sys, gzip

gz_path = sys.argv[1]
with gzip.open(gz_path, 'rt', encoding='utf-8') as f:
    lines = f.readlines()

records = []
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        continue
    if entry.get("type") not in ("user", "assistant"):
        continue
    records.append(entry)

# Merge assistant streaming chunks (each chunk is a different content block for the same message)
from collections import OrderedDict
groups = OrderedDict()
for r in records:
    msg = r.get("message", {})
    key = msg.get("id") or r.get("uuid", id(r))
    groups.setdefault(key, []).append(r)

deduped = []
for entries in groups.values():
    merged = entries[0].copy()
    merged["message"] = dict(entries[0].get("message", {}))
    all_content = []
    for e in entries:
        content = e.get("message", {}).get("content", [])
        if isinstance(content, list):
            all_content.extend(content)
        elif isinstance(content, str) and content:
            all_content.append({"type": "text", "text": content})
    merged["message"]["content"] = all_content
    deduped.append(merged)

def extract_text(entry):
    msg = entry.get("message", {})
    role = msg.get("role", "unknown")
    content = msg.get("content", "")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = next((b.get("text", "") for b in content
                      if isinstance(b, dict) and b.get("type") == "text"), "")
    else:
        text = ""
    return role, text[:80].replace("\n", " ")

count = len(deduped)
first = [extract_text(r) for r in deduped[:2]]
last  = [extract_text(r) for r in deduped[-2:]]
# ... output JSON or human-readable
```

**For the agent:** `peek --json` lets Claude show the user what a session contains before restoring it. This is the "feel it" moment — the agent says "This session from Feb 27 was about debugging auth middleware. Want me to restore it?"

**Security:** `peek` only reads from `~/.claude-backup/` (compressed copies), never from `~/.claude/` (live sessions). No write operations.

---

## 3. `--json` Output Contract

### General Rules

- When `--json` is passed, stdout is a **single JSON object** (never mixed with human text)
- ANSI colors are suppressed
- Exit codes unchanged: 0 = success, 1 = user error, 2 = system error
- Errors go to stderr as JSON: `{"error": "message"}`
- Without `--json`, behavior is unchanged (human-readable output)

### Per-Command Responses

```
claude-backup sync --json
{"ok":true,"config":{"filesSynced":3},"sessions":{"added":2,"updated":0,"removed":0},"pushed":true}

claude-backup sync --config-only --json
{"ok":true,"config":{"filesSynced":3},"sessions":null,"pushed":true}

claude-backup status --json
{"version":"3.0.0","repo":"https://github.com/user/claude-backup-data.git","lastBackup":"2026-02-27T03:00:00Z","backupSize":"42M","config":{"files":12,"size":"48K"},"sessions":{"files":247,"projects":15,"size":"380M"},"scheduler":"active","index":{"sessions":247}}

claude-backup restore --list --json
{"sessions":[{"uuid":"abc-def","projectHash":"-Users-foo-myapp","sizeBytes":1234,"backedUpAt":"2026-02-27T01:00:00Z"},…]}

claude-backup restore --last 5 --json
{"sessions":[…]}  (same shape, at most 5 entries)

claude-backup restore --project myapp --json
{"sessions":[…]}  (same shape, filtered)

claude-backup restore --date 2026-02-27 --json
{"sessions":[…]}  (same shape, filtered)

claude-backup restore <uuid> --json
{"ok":true,"restored":{"from":"/path/to/file.gz","to":"/path/to/file.jsonl"}}

claude-backup restore <uuid> --json  (file exists, no --force)
stderr: {"error":"File already exists. Use --force to overwrite."}  exit 1

claude-backup restore <uuid> --force --json
{"ok":true,"restored":{"from":"…","to":"…"}}

claude-backup export-config --json
{"ok":true,"exported":{"path":"/Users/x/claude-config-2026-02-27.tar.gz","size":"47K","files":12}}

claude-backup import-config FILE --json
{"ok":true,"imported":{"files":8}}

claude-backup peek <uuid> --json
{"uuid":"abc-def","projectHash":"-Users-foo-myapp","backedUpAt":"2026-02-27T01:00:00Z","sizeBytes":12000,"uncompressedBytes":48000,"messageCount":47,"firstMessages":[{"role":"user","preview":"Help me debug..."}],"lastMessages":[{"role":"assistant","preview":"The fix is deployed..."}]}

claude-backup --version --json
{"version":"3.1.0"}
```

### `status --json` Mode Field

The `status` response includes a `mode` field reflecting the backend:

```json
{"version":"3.1.0","mode":"github","repo":"https://...","lastBackup":"...","...":"..."}
{"version":"3.1.0","mode":"local","repo":null,"lastBackup":"...","...":"..."}
```

### Implementation Pattern

A global `JSON_OUTPUT=false` flag, set by a pre-processing loop **before** the `case` statement. The `case` dispatches on `$1` (the subcommand), so `--json` as `$2+` would never be seen there. Instead, scan all args first:

```bash
# Pre-parse global flags before subcommand dispatch
JSON_OUTPUT=false
FILTERED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=true ;;
    *)      FILTERED_ARGS+=("$arg") ;;
  esac
done
set -- "${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}"
# ${FILTERED_ARGS[@]+"..."} avoids "unbound variable" under set -u when array is empty

case "${1:-}" in
  sync)  shift; cmd_sync "$@" ;;
  ...
esac
```

Helper functions (**must use `if/fi`, not `&&`** — the `&&` pattern returns exit 1 when the condition is false, which crashes the script under `set -e`; this is the exact same bug caught in v3 audit issue #14):

```bash
json_out() { if [ "$JSON_OUTPUT" = true ]; then echo "$1"; fi; }
json_err() { if [ "$JSON_OUTPUT" = true ]; then echo "$1" >&2; fi; }
```

**Output helpers must be mode-aware.** `fail()`, `warn()`, `info()`, `step()` all write human text to stdout unconditionally. In JSON mode they would contaminate the stdout JSON contract. Refactored:

```bash
fail() {
  if [ "$JSON_OUTPUT" = true ]; then
    printf '{"error":"%s"}\n' "$*" >&2
  else
    printf "  ${RED}✗${NC} %s\n" "$*"
  fi
  exit 1
}
info() { if [ "$JSON_OUTPUT" != true ]; then printf "  ${GREEN}✓${NC} %s\n" "$*"; fi; }
warn() { if [ "$JSON_OUTPUT" != true ]; then printf "  ${YELLOW}!${NC} %s\n" "$*"; fi; }
step() { if [ "$JSON_OUTPUT" != true ]; then printf "  ${DIM}%s${NC} " "$*"; fi; }
```

`log()` (writes to `$LOG_FILE`) is unaffected — it should run in both modes.

Each `cmd_*` function checks `$JSON_OUTPUT` and branches:
- `true` → build and emit JSON, skip all `printf` human output
- `false` → existing behavior unchanged

---

## 4. Plugin Structure

The repo IS the plugin. No separate package.

```
claude-backup/                      (repo root)
├── .claude-plugin/
│   ├── plugin.json                 # Plugin manifest
│   └── marketplace.json            # Marketplace catalog (self-hosted)
├── skills/
│   └── backup/
│       └── SKILL.md                # Agent skill
├── cli.sh                          # CLI (already exists)
├── package.json                    # npm package (already exists)
├── CLAUDE.md                       # Repo-level agent instructions (new)
├── lefthook.yml                    # Git hooks config
├── test/
│   └── skill-sync.sh              # Contract test
└── .github/
    └── workflows/
        ├── release.yml             # npm publish (already exists)
        └── ci.yml                  # PR checks: bash -n, skill-sync
```

### plugin.json

```json
{
  "name": "claude-backup",
  "description": "Back up and restore your Claude Code environment",
  "version": "3.1.0",
  "author": { "name": "tombelieber" },
  "repository": "https://github.com/tombelieber/claude-backup"
}
```

### Installation

Claude Code plugins install from marketplaces, not directly from GitHub URLs. The repo acts as its own single-plugin marketplace. Users install in two steps:

```
/plugin marketplace add tombelieber/claude-backup
/plugin install claude-backup
```

To support this, the repo needs a `.claude-plugin/marketplace.json` alongside `plugin.json`:

```json
{
  "plugins": [
    {
      "name": "claude-backup",
      "version": "3.1.0",
      "description": "Back up and restore your Claude Code environment"
    }
  ]
}
```

After install, users get the skill. It auto-activates when Claude detects backup-related intent. The CLI (`npx claude-backup`) is installed separately via npm — the plugin only provides the skill layer.

---

## 5. Skill Design

`skills/backup/SKILL.md` — ~40 lines. The agent's complete interface reference.

```markdown
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
| Run a backup | `claude-backup sync --json` |
| Backup config only | `claude-backup sync --config-only --json` |
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

## Reading responses

- Success: `{"ok": true, …}` with exit code 0
- Error: `{"error": "message"}` on stderr with exit code 1
- `status` response includes `"mode": "github"` or `"mode": "local"`
- Summarize results conversationally for the user. Don't dump raw JSON.

## Helping users find sessions

Use `peek --json` before restoring to confirm the right session. Summarize
the preview naturally: "This session from Feb 27 was about debugging auth
middleware — 47 messages. Want me to restore it?"

## When to suggest backups

- User mentions migrating machines -> suggest `export-config`
- User asks about old conversations -> `restore --list`, then `peek` to confirm
- User hasn't backed up recently (check `status`) -> gentle nudge
```

### Design Decisions

- **No hooks in the plugin.** The skill is sufficient for the agent-as-operator use case. Hooks can be added in a future version if there's a clear need (e.g., auto-backup before destructive git operations).
- **No MCP server.** The JSON CLI + skill pattern is sufficient and proven. MCP can wrap the CLI later if demand appears.
- **Skill is intentionally short.** Every line costs tokens when loaded. The commands table is the agent's complete reference — it doesn't need prose explanations.

---

## 6. Skill-CLI Sync Enforcement

Three layers of protection, from softest to hardest:

### Layer 1: CLAUDE.md Rule (agent-time)

Added to the repo's CLAUDE.md:

```markdown
## Plugin Sync Rule

When modifying `cli.sh` (adding/removing/renaming flags, changing JSON output shapes,
or altering command behavior), you MUST update `skills/backup/SKILL.md` to match.
The skill is the agent's interface to the CLI — if they drift, agents break silently.

Checklist after any cli.sh change:
- [ ] Skill command table matches actual CLI flags
- [ ] JSON response examples in design doc match actual output
- [ ] "When to suggest" section still makes sense
```

### Layer 2: Lefthook Pre-Commit (commit-time)

```yaml
# lefthook.yml
pre-commit:
  commands:
    skill-sync:
      run: bash test/skill-sync.sh
      glob: "{cli.sh,skills/backup/SKILL.md}"
```

**Setup:** Add `lefthook` to `devDependencies` and a `"prepare": "lefthook install"` script in `package.json` so Git hooks install automatically on `npm install` for contributors. Without this, the pre-commit check is invisible.

### Layer 3: GitHub Actions CI (merge-time)

```yaml
# Added to .github/workflows/ci.yml
- name: Verify skill-CLI sync
  run: bash test/skill-sync.sh
```

### Contract Test: `test/skill-sync.sh`

Extracts subcommands and flags from `cli.sh`, verifies each appears in `SKILL.md`:

1. Parse `case` statement for subcommands: `sync`, `status`, `restore`, `export-config`, `import-config`, `uninstall`
2. Parse `--flag` patterns from arg parsers: `--json`, `--config-only`, `--sessions-only`, `--list`, `--last`, `--date`, `--project`, `--force`
3. For each, `grep -qF` in `SKILL.md`
4. Exit 0 if all found, exit 1 with list of missing items

This is a syntactic check, not semantic — it can't verify that the skill *correctly describes* what `--last` does. But it catches the most common drift: adding a flag to the CLI and forgetting to document it.

---

## Scope Summary

| Component | Files | Effort |
|-----------|-------|--------|
| Local-only mode | `cli.sh` | Medium — split `check_requirements`, refactor `cmd_init`, `cmd_sync`, `cmd_status` |
| `peek` command | `cli.sh` | Medium — new `cmd_peek`, python3 JSONL parser with dedup + content extraction |
| `--json` flag on all commands | `cli.sh` | Medium — pre-process args, refactor `fail`/`warn`/`info`/`step`, branch in every `cmd_*` |
| Plugin manifest + marketplace | `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` | Trivial |
| Skill | `skills/backup/SKILL.md` | Small |
| Contract test | `test/skill-sync.sh` | Small |
| Lefthook config + setup | `lefthook.yml`, `package.json` (devDeps + prepare script) | Small |
| CI pipeline | `.github/workflows/ci.yml` | Small — `bash -n` + skill-sync + version-triple check |
| CLAUDE.md sync rule | `CLAUDE.md` | Trivial |
| Version bump | `cli.sh`, `package.json`, `plugin.json`, `marketplace.json` | Trivial |
| README update | `README.md` | Small |

---

## What's NOT in v3.1

- MCP server (can wrap JSON CLI later if needed)
- Hooks in the plugin (no clear use case yet)
- `settings.json` in the plugin (no custom agent needed)
- LSP server (irrelevant for a backup tool)
- GitLab/Bitbucket/S3 backends (abstraction supports it, build when asked)
- `claude-backup remote github` upgrade command (v3.2)

---

## Version

- `cli.sh` VERSION: `3.1.0`
- `package.json` version: `3.1.0`
- `plugin.json` version: `3.1.0`

All four MUST match. The contract test should verify this.

---

## Changelog of Fixes Applied (Audit → Final Design)

### Round 1 (auditing-plans, 4 parallel agents)

| # | Issue | Severity | Fix Applied |
| --- | --- | --- | --- |
| 1 | `json_out()` uses `[ ] && echo` — returns exit 1 under `set -e`, crashes script | Blocker | Replaced with `if [ ... ]; then echo; fi` pattern |
| 2 | `--json` "parsed in top-level case block" — impossible, case dispatches on `$1` (subcommand) | Blocker | Added pre-processing arg loop before `case` that strips `--json` and sets `JSON_OUTPUT` |
| 3 | `check_requirements` hard-exits on missing `gh` — no local-mode fallback possible | Blocker | Split into `check_core_requirements` (hard fail) + `detect_github_available` (soft probe) |
| 4 | Plan says filter `type: "human"` — actual JSONL format uses `type: "user"` | Blocker | Fixed to `type in ("user", "assistant")` |
| 5 | Plan says `role`/`content` at top level — actually nested under `entry["message"]` | Blocker | Fixed field paths to `entry["message"]["role"]`, `entry["message"]["content"]` |
| 6 | JSONL files contain many non-message types that would produce garbage counts | Blocker | Documented all record types, filter strictly to user/assistant |
| 7 | `fail()` writes human text to stdout, violating JSON mode contract | Warning | Made `fail()` mode-aware: JSON → `{"error":"..."}` on stderr |
| 8 | `info()`, `warn()`, `step()` contaminate stdout in JSON mode | Warning | All suppressed when `JSON_OUTPUT=true` |
| 9 | `cmd_status` shows `Repo: unknown` in local mode | Warning | Added mode-conditional branch, skip repo URL in local mode |
| 10 | Assistant messages emit multiple streaming chunks — double-counting | Warning | ~~Added dedup by `message.id`, keep last occurrence~~ → See Round 2 fix #17 |
| 11 | `content` can be a plain string, not always a list | Warning | Added `isinstance(content, str)` guard in parser |
| 12 | `/plugin install github.com/...` syntax doesn't exist | Warning | Added `marketplace.json`, switched to two-step install flow |
| 13 | No CLAUDE.md at repo root | Minor | Added to plugin structure diagram, create during impl |
| 14 | Lefthook setup step missing (devDeps + prepare script) | Minor | Added setup instructions to Layer 2 section |
| 15 | No `ci.yml` exists, only `release.yml` | Minor | Updated structure diagram, expanded CI scope |
| 16 | Content blocks may start with `thinking`/`tool_use`, not `text` | Minor | Parser extracts first `type == "text"` block, skipping others |

### Round 2 (prove-it audit against real JSONL data)

| # | Issue | Severity | Fix Applied |
| --- | --- | --- | --- |
| 17 | Streaming dedup "keep last per message.id" is WRONG — chunks are separate content blocks (thinking → text → tool_use), not progressive snapshots. "Keep last" discards text when final chunk is tool_use. Measured: 14% of messages lose text. `stop_reason` is always `null` (never non-null across 10 files sampled). | Blocker | Replaced "keep last" with merge-all-entries strategy: group by `message.id`, concatenate all content blocks from all entries, then extract first `text` block from merged list. Removed incorrect `stop_reason != null` comment. |
| 18 | `summary` record type exists in real JSONL data (`"type": "summary"` with `summary` + `leafUuid` fields, no `message` key) but not in type table | Minor | Added to type table as filtered-out type |
| 19 | `tool_result` content block type appears in real data but not documented alongside thinking/tool_use/text | Minor | Added `tool_result` to content block type list |
