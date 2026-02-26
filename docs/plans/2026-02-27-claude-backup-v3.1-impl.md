# claude-backup v3.1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship agent-optimized JSON output, local-only backup mode, session peek, and a Claude Code plugin — making claude-backup usable by both agents (structured output) and privacy-conscious humans (no GitHub required).

**Architecture:** Five features in one release. `--json` infrastructure lands first (pre-parse loop + output helper refactor) since every subsequent feature needs it. Local-only mode second (splits `check_requirements`, refactors `cmd_init`/`cmd_sync`/`cmd_status` to branch on `BACKUP_MODE`). Then `peek` command (new `cmd_peek` with python3 JSONL parser using merge-all-entries dedup strategy). Plugin files and contract tests are static assets created last. All changes in `cli.sh` (~1037 lines), plus ~8 new files.

**Tech Stack:** Bash, python3 (macOS built-in), gzip, git, GitHub Actions, Lefthook

**Design doc:** `docs/plans/2026-02-27-claude-backup-v3.1-design.md` — the source of truth for all JSON contracts, JSONL format details, and architectural decisions.

---

## Rollback

If anything goes wrong mid-implementation:

```bash
# Undo the last commit (keeps changes staged)
git reset HEAD~1

# Restore cli.sh to last known-good state
git checkout HEAD -- cli.sh

# Remove any new files created
git clean -fd .claude-plugin/ skills/ test/ lefthook.yml
```

Existing backup data at `~/.claude-backup/` is never touched by these changes.

---

### Task 1: `--json` and `--local` global flag infrastructure

**Files:**
- Modify: `cli.sh` — 3 locations: output helpers (lines 45-49), pre-parse loop (new, before line 1025 case statement), case statement (line 1025)

This task adds the foundation that every subsequent task depends on: `JSON_OUTPUT` and `FORCE_LOCAL` globals, mode-aware output helpers, and the `json_out`/`json_err` helpers.

**Step 1: Refactor output helpers to be JSON-mode-aware**

Find (lines 46-49):
```bash
info() { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*"; exit 1; }
step() { printf "  ${DIM}%s${NC} " "$*"; }
```

Replace with:
```bash
info() { if [ "$JSON_OUTPUT" != true ]; then printf "  ${GREEN}✓${NC} %s\n" "$*"; fi; }
warn() { if [ "$JSON_OUTPUT" != true ]; then printf "  ${YELLOW}!${NC} %s\n" "$*"; fi; }
fail() {
  if [ "$JSON_OUTPUT" = true ]; then
    printf '{"error":"%s"}\n' "$*" >&2
  else
    printf "  ${RED}✗${NC} %s\n" "$*"
  fi
  exit 1
}
step() { if [ "$JSON_OUTPUT" != true ]; then printf "  ${DIM}%s${NC} " "$*"; fi; }
json_out() { if [ "$JSON_OUTPUT" = true ]; then printf '%s\n' "$1"; fi; }
json_err() { if [ "$JSON_OUTPUT" = true ]; then printf '%s\n' "$1" >&2; fi; }
```

**Step 2: Add pre-parse loop and refactor case statement**

Find (line 1025):
```bash
case "${1:-}" in
  init|"")       cmd_init ;;
  sync)          shift; cmd_sync "$@" ;;
  status)        cmd_status ;;
  restore)       shift; cmd_restore "$@" ;;
  uninstall)     cmd_uninstall ;;
  export-config) cmd_export_config "${2:-}" ;;
  import-config) shift; cmd_import_config "$@" ;;
  --help|-h)     show_help ;;
  --version|-v)  echo "claude-backup v$VERSION" ;;
  *)             echo "Unknown command: $1"; show_help; exit 1 ;;
esac
```

Replace with:
```bash
# Pre-parse global flags before subcommand dispatch
JSON_OUTPUT=false
FORCE_LOCAL=false
FILTERED_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --json)  JSON_OUTPUT=true ;;
    --local) FORCE_LOCAL=true ;;
    *)       FILTERED_ARGS+=("$arg") ;;
  esac
done
set -- "${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}"
# ${FILTERED_ARGS[@]+"..."} avoids "unbound variable" under set -u when array is empty

case "${1:-}" in
  init|"")       cmd_init ;;
  sync)          shift; cmd_sync "$@" ;;
  status)        cmd_status ;;
  restore)       shift; cmd_restore "$@" ;;
  peek)          cmd_peek "${2:-}" ;;
  uninstall)     cmd_uninstall ;;
  export-config) cmd_export_config "${2:-}" ;;
  import-config) shift; cmd_import_config "$@" ;;
  --help|-h)     show_help ;;
  --version|-v)
    if [ "$JSON_OUTPUT" = true ]; then
      printf '{"version":"%s"}\n' "$VERSION"
    else
      echo "claude-backup v$VERSION"
    fi
    ;;
  *)             echo "Unknown command: $1"; show_help; exit 1 ;;
esac
```

Note: `peek)` is added to the case statement now (it will be implemented in Task 6). This prevents needing to re-edit the case statement later. `cmd_peek` won't exist yet, so don't run `peek` until Task 6.

**Step 3: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output (clean syntax)

**Step 4: Smoke test — existing behavior unchanged**

Run: `./cli.sh --version`
Expected: `claude-backup v3.0.0`

Run: `./cli.sh status`
Expected: Normal human-readable output (unchanged from v3)

**Step 5: Smoke test — JSON flag works**

Run: `./cli.sh --version --json`
Expected: `{"version":"3.0.0"}`

**Step 6: Commit**

```bash
git add cli.sh
git commit -m "feat: add --json and --local global flag infrastructure"
```

---

### Task 2: Local-only mode — split `check_requirements` + refactor `cmd_init`

**Files:**
- Modify: `cli.sh` — `check_requirements` (lines 84-124), `cmd_init` (lines 180-270), `write_manifest` (lines 338-383)

**Step 1: Replace `check_requirements` with two functions**

Find (lines 84-124):
```bash
check_requirements() {
  local ok=true

  step "git"
  if command -v git &>/dev/null; then
    printf "${GREEN}✓${NC}\n"
  else
    printf "${RED}✗ not found${NC}\n"
    ok=false
  fi

  step "gh"
  if command -v gh &>/dev/null; then
    local gh_user
    gh_user=$(gh api user --jq .login 2>/dev/null || true)
    if [ -n "$gh_user" ]; then
      printf "${GREEN}✓${NC} ${DIM}(logged in as ${gh_user})${NC}\n"
    else
      printf "${RED}✗ not authenticated${NC}\n"
      echo "    Run: gh auth login"
      ok=false
    fi
  else
    printf "${RED}✗ not found${NC}\n"
    echo "    Install: https://cli.github.com"
    ok=false
  fi

  step "gzip"
  if command -v gzip &>/dev/null; then
    printf "${GREEN}✓${NC}\n"
  else
    printf "${RED}✗ not found${NC}\n"
    ok=false
  fi

  if [ "$ok" = false ]; then
    echo ""
    fail "Missing requirements. Install them and try again."
  fi
}
```

Replace with:
```bash
# Checks git and gzip. Hard-fails if missing (always required).
check_core_requirements() {
  local ok=true

  step "git"
  if command -v git &>/dev/null; then
    printf "${GREEN}✓${NC}\n"
  else
    printf "${RED}✗ not found${NC}\n"
    ok=false
  fi

  step "gzip"
  if command -v gzip &>/dev/null; then
    printf "${GREEN}✓${NC}\n"
  else
    printf "${RED}✗ not found${NC}\n"
    ok=false
  fi

  if [ "$ok" = false ]; then
    echo ""
    fail "Missing requirements. Install them and try again."
  fi
}

# Probes gh installation and auth. Returns 0 if available, 1 if not.
# Does NOT exit — callers use the return code to decide mode.
detect_github_available() {
  if ! command -v gh &>/dev/null; then
    return 1
  fi
  local gh_user
  gh_user=$(gh api user --jq .login 2>/dev/null || true)
  if [ -z "$gh_user" ]; then
    return 1
  fi
  # Export for use by cmd_init
  GH_USER="$gh_user"
  return 0
}
```

**Step 2: Refactor `cmd_init` for local/github mode**

Find the entire `cmd_init()` function (lines 180-270) and replace with:

```bash
cmd_init() {
  printf "\n${BOLD}Claude Backup${NC} v$VERSION\n\n"

  # Check if already initialized
  if [ -d "$BACKUP_DIR/.git" ]; then
    info "Already initialized at $BACKUP_DIR"
    local mode
    mode=$(read_backup_mode)
    if [ "$mode" = "github" ]; then
      local remote_url
      remote_url=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null || echo "unknown")
      printf "  ${DIM}Remote: ${remote_url}${NC}\n"
    else
      printf "  ${DIM}Mode: local (no remote)${NC}\n"
    fi
    printf "\n  Run ${BOLD}claude-backup sync${NC} to backup now.\n\n"
    return 0
  fi

  # Check core requirements (git, gzip — always needed)
  printf "${BOLD}Checking requirements...${NC}\n"
  check_core_requirements
  printf "\n"

  # Determine mode
  local BACKUP_MODE
  GH_USER=""
  if [ "$FORCE_LOCAL" = true ]; then
    BACKUP_MODE="local"
    info "Local-only mode (--local flag)"
  elif detect_github_available; then
    BACKUP_MODE="github"
    step "gh"
    printf "${GREEN}✓${NC} ${DIM}(logged in as ${GH_USER})${NC}\n"
  else
    BACKUP_MODE="local"
    info "GitHub CLI not available. Setting up local-only backup."
  fi
  printf "\n"

  # Check Claude sessions exist
  if [ ! -d "$SOURCE_DIR" ]; then
    fail "No Claude sessions found at $SOURCE_DIR"
  fi

  local session_count project_count
  session_count=$(find "$SOURCE_DIR" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  project_count=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  info "Found $session_count sessions across $project_count projects"
  printf "\n"

  # GitHub mode: create private repo
  if [ "$BACKUP_MODE" = "github" ]; then
    printf "${BOLD}Creating private repo...${NC}\n"
    step "github.com/$GH_USER/$DATA_REPO_NAME"

    if gh repo view "$GH_USER/$DATA_REPO_NAME" &>/dev/null; then
      printf "${YELLOW}exists${NC}\n"
    else
      gh repo create "$DATA_REPO_NAME" --private \
        --description "Claude Code environment backups (auto-generated by claude-backup)" \
        >/dev/null 2>&1
      printf "${GREEN}✓${NC}\n"
    fi
    printf "\n"
  fi

  # Initialize local backup directory
  printf "${BOLD}Setting up local backup...${NC}\n"
  mkdir -p "$BACKUP_DIR"
  cd "$BACKUP_DIR"

  if [ ! -d ".git" ]; then
    git init -q -b main
    if [ "$BACKUP_MODE" = "github" ]; then
      git remote add origin "https://github.com/$GH_USER/$DATA_REPO_NAME.git"
    fi
  fi

  mkdir -p "$DEST_DIR"

  # Add .gitignore
  cat > "$BACKUP_DIR/.gitignore" <<'GITIGNORE'
backup.log
launchd-stdout.log
launchd-stderr.log
*.lock
*.tmp
.sync.lock/
cli.sh
session-index.json
GITIGNORE

  info "Initialized at $BACKUP_DIR"
  printf "\n"

  # Run first backup (pass mode so cmd_sync can use it before manifest exists)
  printf "${BOLD}Running first backup...${NC}\n"
  export BACKUP_MODE
  cmd_sync

  # Schedule daily backup (macOS only)
  printf "\n${BOLD}Scheduling daily backup...${NC}\n"
  schedule_launchd
  info "Daily backup at 3:00 AM"

  printf "\n${BOLD}${GREEN}All set!${NC} Your Claude Code environment is backed up.\n\n"
  printf "  ${BOLD}Commands:${NC}\n"
  printf "    claude-backup sync            Run backup now\n"
  printf "    claude-backup status           Check last backup\n"
  printf "    claude-backup export-config    Export config for sharing\n"
  printf "    claude-backup restore --list   List and restore sessions\n"
  if [ "$BACKUP_MODE" = "local" ]; then
    printf "\n  ${DIM}Mode: local — backups are on this machine only.${NC}\n"
  fi
  printf "\n"
}
```

**Step 3: Add `read_backup_mode` helper and update `write_manifest`**

Find the line `write_manifest() {` (line 338). Insert BEFORE it:

```bash
# Reads mode from manifest.json. Returns "github" or "local".
# Falls back to "github" for pre-3.1 installs that have no mode field.
read_backup_mode() {
  local manifest="$BACKUP_DIR/manifest.json"
  if [ -f "$manifest" ]; then
    python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('mode','github'))" "$manifest" 2>/dev/null || echo "github"
  else
    echo "github"
  fi
}

```

Now update `write_manifest` to include the `mode` field. Find in `write_manifest` (line 365-382):

```bash
  cat > "$BACKUP_DIR/manifest.json" <<MANIFEST
{
  "version": "$VERSION",
  "machine": "$(hostname)",
  "user": "$cached_user",
  "lastSync": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "config": {
    "files": $config_files,
    "sizeBytes": $config_size
  },
  "sessions": {
    "files": $session_files,
    "projects": $session_projects,
    "sizeBytes": $session_size,
    "uncompressedBytes": $session_uncompressed
  }
}
MANIFEST
```

Replace with:

```bash
  # Resolve mode: use BACKUP_MODE if set (during init), otherwise read from existing manifest
  local mode="${BACKUP_MODE:-$(read_backup_mode)}"

  cat > "$BACKUP_DIR/manifest.json" <<MANIFEST
{
  "version": "$VERSION",
  "mode": "$mode",
  "machine": "$(hostname)",
  "user": "$cached_user",
  "lastSync": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "config": {
    "files": $config_files,
    "sizeBytes": $config_size
  },
  "sessions": {
    "files": $session_files,
    "projects": $session_projects,
    "sizeBytes": $session_size,
    "uncompressedBytes": $session_uncompressed
  }
}
MANIFEST
```

**Step 4: Update `write_manifest` remote URL extraction for local mode**

Find in `write_manifest`:
```bash
  local cached_user
  cached_user=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null \
    | sed 's|https://[^/]*/\([^/]*\)/.*|\1|; s|git@[^:]*:\([^/]*\)/.*|\1|' \
    | grep -E '^[a-zA-Z0-9._-]+$' \
    || echo "unknown")
```

Replace with:
```bash
  # Resolve mode: use BACKUP_MODE if set (during init), otherwise read from existing manifest
  local mode="${BACKUP_MODE:-$(read_backup_mode)}"

  local cached_user="local"
  if [ "$mode" = "github" ]; then
    cached_user=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null \
      | sed 's|https://[^/]*/\([^/]*\)/.*|\1|; s|git@[^:]*:\([^/]*\)/.*|\1|' \
      | grep -E '^[a-zA-Z0-9._-]+$' \
      || echo "unknown")
  fi
```

Wait — that creates two `local mode` lines. Let me restructure: the `mode` variable should be resolved ONCE at the top of `write_manifest`, then used for both `cached_user` and the manifest JSON. Let me revise:

Actually, the two edits (Step 3's manifest replacement and Step 4's cached_user replacement) overlap — both need the `mode` variable. Let me combine them into one replacement. Replace the entire body of `write_manifest()`:

Find:
```bash
write_manifest() {
```

Through the closing `}` of write_manifest (the `}` on the line BEFORE `build_session_index() {`). Replace the entire function with:

```bash
write_manifest() {
  local config_files=0 config_size=0
  local session_files=0 session_projects=0 session_size=0 session_uncompressed=0

  if [ -d "$CONFIG_DEST" ]; then
    config_files=$(find "$CONFIG_DEST" -type f 2>/dev/null | wc -l | tr -d ' ')
    config_size=$(dir_bytes "$CONFIG_DEST")
  fi

  if [ -d "$DEST_DIR" ]; then
    session_files=$(find "$DEST_DIR" -name "*.gz" -type f 2>/dev/null | wc -l | tr -d ' ')
    session_projects=$(find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    session_size=$(dir_bytes "$DEST_DIR")
  fi

  if [ -d "$SOURCE_DIR" ]; then
    session_uncompressed=$(dir_bytes "$SOURCE_DIR")
  fi

  # Resolve mode: BACKUP_MODE env (set during init) > existing manifest > "github" default
  local mode="${BACKUP_MODE:-$(read_backup_mode)}"

  # Extract username from git remote URL (no network call — works offline)
  local cached_user="local"
  if [ "$mode" = "github" ]; then
    cached_user=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null \
      | sed 's|https://[^/]*/\([^/]*\)/.*|\1|; s|git@[^:]*:\([^/]*\)/.*|\1|' \
      | grep -E '^[a-zA-Z0-9._-]+$' \
      || echo "unknown")
  fi

  cat > "$BACKUP_DIR/manifest.json" <<MANIFEST
{
  "version": "$VERSION",
  "mode": "$mode",
  "machine": "$(hostname)",
  "user": "$cached_user",
  "lastSync": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "config": {
    "files": $config_files,
    "sizeBytes": $config_size
  },
  "sessions": {
    "files": $session_files,
    "projects": $session_projects,
    "sizeBytes": $session_size,
    "uncompressedBytes": $session_uncompressed
  }
}
MANIFEST
}
```

**Step 5: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 6: Smoke test — GitHub mode unchanged**

Run: `./cli.sh status`
Expected: Normal output (existing GitHub install still works)

**Step 7: Commit**

```bash
git add cli.sh
git commit -m "feat: split check_requirements, add local-only mode to cmd_init"
```

---

### Task 3: Local-only mode in `cmd_sync` and `cmd_status`

**Files:**
- Modify: `cli.sh` — `cmd_sync` (lines 465-632), `cmd_status` (lines 633-699)

**Step 1: Make `cmd_sync` push conditionally**

In `cmd_sync`, find the commit-and-push block (starting after `git add -A`). Find:

```bash
  step "Pushing to GitHub..."
  if ! git push -u origin HEAD -q 2>&1; then
    printf "${RED}FAILED${NC}\n"
    warn "Push failed. Check your GitHub authentication and network."
    log "Push failed"
    return 1
  fi
  printf "${GREEN}✓${NC}\n"

  log "Backup pushed successfully"
  printf "\n${GREEN}${BOLD}Done!${NC} Backup complete.\n"
```

Replace with:

```bash
  local mode="${BACKUP_MODE:-$(read_backup_mode)}"
  if [ "$mode" = "github" ]; then
    step "Pushing to GitHub..."
    if ! git push -u origin HEAD -q 2>&1; then
      printf "${RED}FAILED${NC}\n"
      warn "Push failed. Check your GitHub authentication and network."
      log "Push failed"
      return 1
    fi
    printf "${GREEN}✓${NC}\n"
    log "Backup pushed successfully"
  else
    log "Backup committed locally (local mode — no push)"
  fi

  printf "\n${GREEN}${BOLD}Done!${NC} Backup complete.\n"
```

**Step 2: Make `cmd_status` mode-aware**

Replace the entire `cmd_status` function. Find `cmd_status() {` through the `}` before `cmd_restore() {`.

Replace with:

```bash
cmd_status() {
  local mode
  mode=$(read_backup_mode)

  if [ "$JSON_OUTPUT" = true ]; then
    cmd_status_json "$mode"
    return
  fi

  printf "\n${BOLD}Claude Backup${NC} v$VERSION\n\n"

  if [ ! -d "$BACKUP_DIR/.git" ]; then
    fail "Not initialized. Run: claude-backup init"
  fi

  # Mode
  printf "  ${BOLD}Mode:${NC}        $mode\n"

  # Remote URL (github mode only)
  if [ "$mode" = "github" ]; then
    local remote_url
    remote_url=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null || echo "unknown")
    printf "  ${BOLD}Repo:${NC}        $remote_url\n"
  fi

  # Last backup time
  local last_commit
  last_commit=$(cd "$BACKUP_DIR" && git log -1 --format="%ar (%ci)" 2>/dev/null || echo "never")
  printf "  ${BOLD}Last backup:${NC} $last_commit\n"

  # Backup size
  if [ -d "$DEST_DIR" ]; then
    local backup_size
    backup_size=$(du -sh "$DEST_DIR" 2>/dev/null | cut -f1)
    printf "  ${BOLD}Backup size:${NC} $backup_size (compressed)\n"
  fi

  # Session index
  local index_file="$BACKUP_DIR/session-index.json"
  if [ -f "$index_file" ]; then
    local index_count
    index_count=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('sessions',[])))" "$index_file" 2>/dev/null || echo "?")
    printf "  ${BOLD}Index:${NC}       $index_count sessions indexed\n"
  fi

  # Config backup
  if [ -d "$CONFIG_DEST" ]; then
    local config_count config_size
    config_count=$(find "$CONFIG_DEST" -type f 2>/dev/null | wc -l | tr -d ' ')
    config_size=$(du -sh "$CONFIG_DEST" 2>/dev/null | cut -f1)
    printf "  ${BOLD}Config:${NC}      $config_size ($config_count files)\n"
  fi

  # Source size
  if [ -d "$SOURCE_DIR" ]; then
    local source_size session_count project_count
    source_size=$(du -sh "$SOURCE_DIR" 2>/dev/null | cut -f1)
    session_count=$(find "$SOURCE_DIR" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
    project_count=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    printf "  ${BOLD}Source size:${NC}  $source_size ($session_count sessions, $project_count projects)\n"
  fi

  # Scheduler status
  if launchctl list "$PLIST_NAME" &>/dev/null; then
    printf "  ${BOLD}Scheduler:${NC}   ${GREEN}active${NC} (daily at 3:00 AM)\n"
  else
    printf "  ${BOLD}Scheduler:${NC}   ${YELLOW}inactive${NC}\n"
  fi

  # Last log entry
  if [ -f "$LOG_FILE" ]; then
    local last_log
    last_log=$(tail -1 "$LOG_FILE" 2>/dev/null || echo "")
    if [ -n "$last_log" ]; then
      printf "  ${BOLD}Last log:${NC}    ${DIM}$last_log${NC}\n"
    fi
  fi

  printf "\n"
}

cmd_status_json() {
  local mode="$1"

  if [ ! -d "$BACKUP_DIR/.git" ]; then
    json_err '{"error":"Not initialized. Run: claude-backup init"}'
    exit 1
  fi

  local repo="null"
  if [ "$mode" = "github" ]; then
    local remote_url
    remote_url=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null || echo "")
    if [ -n "$remote_url" ]; then
      repo="\"$remote_url\""
    fi
  fi

  local last_backup
  last_backup=$(cd "$BACKUP_DIR" && git log -1 --format="%cI" 2>/dev/null || echo "")

  local backup_size="0"
  if [ -d "$DEST_DIR" ]; then
    backup_size=$(du -sh "$DEST_DIR" 2>/dev/null | cut -f1 | tr -d ' ')
  fi

  local config_files=0 config_size="0"
  if [ -d "$CONFIG_DEST" ]; then
    config_files=$(find "$CONFIG_DEST" -type f 2>/dev/null | wc -l | tr -d ' ')
    config_size=$(du -sh "$CONFIG_DEST" 2>/dev/null | cut -f1 | tr -d ' ')
  fi

  local session_files=0 session_projects=0 session_size="0"
  if [ -d "$DEST_DIR" ]; then
    session_files=$(find "$DEST_DIR" -name "*.gz" -type f 2>/dev/null | wc -l | tr -d ' ')
    session_projects=$(find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    session_size=$(du -sh "$DEST_DIR" 2>/dev/null | cut -f1 | tr -d ' ')
  fi

  local scheduler="inactive"
  if launchctl list "$PLIST_NAME" &>/dev/null; then
    scheduler="active"
  fi

  local index_sessions=0
  local index_file="$BACKUP_DIR/session-index.json"
  if [ -f "$index_file" ]; then
    index_sessions=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('sessions',[])))" "$index_file" 2>/dev/null || echo "0")
  fi

  printf '{"version":"%s","mode":"%s","repo":%s,"lastBackup":"%s","backupSize":"%s","config":{"files":%s,"size":"%s"},"sessions":{"files":%s,"projects":%s,"size":"%s"},"scheduler":"%s","index":{"sessions":%s}}\n' \
    "$VERSION" "$mode" "$repo" "$last_backup" "$backup_size" \
    "$config_files" "$config_size" "$session_files" "$session_projects" "$session_size" \
    "$scheduler" "$index_sessions"
}
```

**Step 3: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 4: Smoke test — human status unchanged**

Run: `./cli.sh status`
Expected: Normal output with new "Mode:" line showing "github" (for existing installs)

**Step 5: Smoke test — JSON status**

Run: `./cli.sh status --json`
Expected: Single-line JSON with version, mode, repo, lastBackup, etc. Pipe through `python3 -m json.tool` to verify valid JSON.

**Step 6: Commit**

```bash
git add cli.sh
git commit -m "feat: local-only mode in cmd_sync and cmd_status with --json"
```

---

### Task 4: `--json` on `cmd_sync`

**Files:**
- Modify: `cli.sh` — `cmd_sync` function

**Step 1: Add JSON output to `cmd_sync`**

The sync function needs to track counts and emit JSON at the end. Find the beginning of `cmd_sync` where the counters are set up, and add JSON output at the end.

Find the sync completion block. After the `printf "\n${GREEN}${BOLD}Done!${NC} Backup complete.\n"` line (at the very end of `cmd_sync`), insert JSON output. The approach: accumulate counters throughout the function, emit JSON at the end if JSON_OUTPUT is true.

At the start of `cmd_sync`, find:
```bash
cmd_sync() {
  local sync_config_tier=true
  local sync_sessions_tier=true
```

Replace with:
```bash
cmd_sync() {
  local sync_config_tier=true
  local sync_sessions_tier=true
  local json_config_count=0
  local json_added=0 json_updated=0 json_removed=0
  local json_pushed=false
```

Find where `config_count` is set:
```bash
    config_count=$(sync_config)
    info "Config: $config_count files synced"
```

Replace with:
```bash
    config_count=$(sync_config)
    json_config_count=$config_count
    info "Config: $config_count files synced"
```

Find where session counts are reported:
```bash
    info "Compressed: $added, copied: $updated, removed: $removed"
    log "Processed: $added compressed, $updated copied, $removed removed"
```

Replace with:
```bash
    json_added=$added
    json_updated=$updated
    json_removed=$removed
    info "Compressed: $added, copied: $updated, removed: $removed"
    log "Processed: $added compressed, $updated copied, $removed removed"
```

Find the push success block:
```bash
    log "Backup pushed successfully"
```

Add after it:
```bash
    json_pushed=true
```

Find the final output line:
```bash
  printf "\n${GREEN}${BOLD}Done!${NC} Backup complete.\n"
```

Replace with:
```bash
  if [ "$JSON_OUTPUT" = true ]; then
    local sessions_json="null"
    if [ "$sync_sessions_tier" = true ]; then
      sessions_json=$(printf '{"added":%s,"updated":%s,"removed":%s}' "$json_added" "$json_updated" "$json_removed")
    fi
    printf '{"ok":true,"config":{"filesSynced":%s},"sessions":%s,"pushed":%s}\n' \
      "$json_config_count" "$sessions_json" "$json_pushed"
  else
    printf "\n${GREEN}${BOLD}Done!${NC} Backup complete.\n"
  fi
```

Also, the "No changes" early return needs JSON output. Find:

```bash
  if git diff --cached --quiet; then
    info "No changes — already up to date"
    return 0
  fi
```

Replace with:
```bash
  if git diff --cached --quiet; then
    if [ "$JSON_OUTPUT" = true ]; then
      local sessions_json="null"
      if [ "$sync_sessions_tier" = true ]; then
        sessions_json=$(printf '{"added":%s,"updated":%s,"removed":%s}' "$json_added" "$json_updated" "$json_removed")
      fi
      printf '{"ok":true,"config":{"filesSynced":%s},"sessions":%s,"pushed":false}\n' \
        "$json_config_count" "$sessions_json"
    else
      info "No changes — already up to date"
    fi
    return 0
  fi
```

**Step 2: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 3: Smoke test**

Run: `./cli.sh sync --json`
Expected: Single-line JSON like `{"ok":true,"config":{"filesSynced":0},"sessions":{"added":0,...},"pushed":true}`. Verify with `| python3 -m json.tool`.

**Step 4: Commit**

```bash
git add cli.sh
git commit -m "feat: add --json output to cmd_sync"
```

---

### Task 5: `--json` on `cmd_restore`, `cmd_export_config`, `cmd_import_config`

**Files:**
- Modify: `cli.sh` — `cmd_restore`, `cmd_export_config`, `cmd_import_config`

**Step 1: Add JSON output to `cmd_restore` listing modes**

In `cmd_restore`, find the listing modes block. After the `local query_mode query_arg` section and the case statement, add a JSON branch. Find:

```bash
  # ── Listing modes ────────────────────────────────────────────────────────────
  if [ "$mode" != "uuid" ]; then
    printf "\n${BOLD}Claude Code Sessions${NC}\n\n"
```

Replace the entire listing block (from `if [ "$mode" != "uuid" ]; then` through its closing `return 0` and `fi`) with:

```bash
  # ── Listing modes ────────────────────────────────────────────────────────────
  if [ "$mode" != "uuid" ]; then
    local query_mode query_arg
    case "$mode" in
      list)    query_mode="all";     query_arg="" ;;
      last)    query_mode="last";    query_arg="$last_n" ;;
      date)    query_mode="date";    query_arg="$filter_date" ;;
      project) query_mode="project"; query_arg="$filter_project" ;;
    esac

    if [ "$JSON_OUTPUT" = true ]; then
      # Build JSON array from pipe-delimited output
      local json_sessions="["
      local first_entry=true
      while IFS='|' read -r s_uuid s_hash s_size s_date; do
        if [ "$first_entry" = true ]; then
          first_entry=false
        else
          json_sessions="${json_sessions},"
        fi
        json_sessions="${json_sessions}{\"uuid\":\"${s_uuid}\",\"projectHash\":\"${s_hash}\",\"sizeBytes\":${s_size},\"backedUpAt\":\"${s_date}\"}"
      done < <(query_session_index "$query_mode" "$query_arg")
      json_sessions="${json_sessions}]"
      printf '{"sessions":%s}\n' "$json_sessions"
      return 0
    fi

    printf "\n${BOLD}Claude Code Sessions${NC}\n\n"
    printf "  %-38s %-36s %6s  %s\n" "PROJECT" "UUID" "SIZE" "DATE (UTC)"
    printf "  %-38s %-36s %6s  %s\n" "--------------------------------------" \
      "------------------------------------" "------" "----------"

    local shown=0
    while IFS='|' read -r s_uuid s_hash s_size s_date; do
      local display_hash display_size display_date
      if [ ${#s_hash} -gt 38 ]; then
        display_hash="...${s_hash: -35}"
      else
        display_hash="$s_hash"
      fi
      display_size=$(( s_size / 1024 ))
      display_date="${s_date%T*}"
      printf "  %-38s %-36s %5sK  %s\n" "$display_hash" "$s_uuid" "$display_size" "$display_date"
      ((shown++)) || true
    done < <(query_session_index "$query_mode" "$query_arg")

    if [ $shown -eq 0 ]; then
      printf "  ${DIM}No sessions found matching your filter.${NC}\n"
    fi

    printf "\n  ${DIM}Restore: claude-backup restore <uuid>${NC}\n"
    printf "  ${DIM}Force:   claude-backup restore <uuid> --force${NC}\n\n"
    return 0
  fi
```

**Step 2: Add JSON output to `cmd_restore` UUID mode**

Find the success path at the end of `cmd_restore`:

```bash
  mkdir -p "$target_dir"
  gzip -dkc "$gz_file" > "$target_file"
  info "Session restored: $target_file"
  printf "\n"
```

Replace with:

```bash
  mkdir -p "$target_dir"
  gzip -dkc "$gz_file" > "$target_file"
  if [ "$JSON_OUTPUT" = true ]; then
    printf '{"ok":true,"restored":{"from":"%s","to":"%s"}}\n' "$gz_file" "$target_file"
  else
    info "Session restored: $target_file"
    printf "\n"
  fi
```

Also find the "file exists" error:

```bash
  if [ -f "$target_file" ] && [ "$force" = false ]; then
    warn "File already exists. Use --force to overwrite."
    return 1
  fi
```

Replace with:

```bash
  if [ -f "$target_file" ] && [ "$force" = false ]; then
    if [ "$JSON_OUTPUT" = true ]; then
      json_err '{"error":"File already exists. Use --force to overwrite."}'
    else
      warn "File already exists. Use --force to overwrite."
    fi
    return 1
  fi
```

**Step 3: Add JSON output to `cmd_export_config`**

Find the success output at the end of `cmd_export_config`:

```bash
  printf "\n${GREEN}${BOLD}Exported${NC} to ${BOLD}${output_file}${NC} (${size})\n"
  printf "${DIM}Transfer via AirDrop, USB, or email. Import with:${NC}\n"
  printf "  claude-backup import-config ${output_file}\n\n"
```

Replace with:

```bash
  if [ "$JSON_OUTPUT" = true ]; then
    printf '{"ok":true,"exported":{"path":"%s","size":"%s","files":%s}}\n' "$output_file" "$size" "$exported"
  else
    printf "\n${GREEN}${BOLD}Exported${NC} to ${BOLD}${output_file}${NC} (${size})\n"
    printf "${DIM}Transfer via AirDrop, USB, or email. Import with:${NC}\n"
    printf "  claude-backup import-config ${output_file}\n\n"
  fi
```

**Step 4: Add JSON output to `cmd_import_config`**

Find the success output at the end of `cmd_import_config`:

```bash
  printf "\n${GREEN}${BOLD}Done!${NC} Imported $imported files.\n"
  printf "${DIM}Restart Claude Code to apply settings.${NC}\n"
  printf "${DIM}Note: Plugins will be downloaded on first launch.${NC}\n\n"
```

Replace with:

```bash
  if [ "$JSON_OUTPUT" = true ]; then
    printf '{"ok":true,"imported":{"files":%s}}\n' "$imported"
  else
    printf "\n${GREEN}${BOLD}Done!${NC} Imported $imported files.\n"
    printf "${DIM}Restart Claude Code to apply settings.${NC}\n"
    printf "${DIM}Note: Plugins will be downloaded on first launch.${NC}\n\n"
  fi
```

**Step 5: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 6: Smoke tests**

Run: `./cli.sh restore --list --json | python3 -m json.tool | head -10`
Expected: Valid JSON with `"sessions"` array.

Run: `./cli.sh restore --last 2 --json | python3 -m json.tool`
Expected: Valid JSON with at most 2 entries.

**Step 7: Commit**

```bash
git add cli.sh
git commit -m "feat: add --json output to restore, export-config, import-config"
```

---

### Task 6: `peek` command

**Files:**
- Modify: `cli.sh` — add `cmd_peek` function (insert before `cmd_uninstall`)

**Step 1: Add `cmd_peek` function**

Find `cmd_uninstall() {`. Insert BEFORE it:

```bash
cmd_peek() {
  local uuid="${1:-}"

  if [ -z "$uuid" ]; then
    if [ "$JSON_OUTPUT" = true ]; then
      json_err '{"error":"Usage: claude-backup peek <uuid>"}'
    else
      printf "\n${BOLD}Usage:${NC} claude-backup peek <uuid>\n\n"
      printf "  Preview the contents of a backed-up session.\n\n"
    fi
    return 1
  fi

  if [[ ! "$uuid" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    fail "Invalid session identifier: $uuid"
  fi

  local matches
  matches=$(find "$DEST_DIR" -name "*${uuid}*.gz" -type f 2>/dev/null)

  if [ -z "$matches" ]; then
    fail "No backup found matching: $uuid"
  fi

  local match_count
  match_count=$(echo "$matches" | wc -l | tr -d ' ')

  if [ "$match_count" -gt 1 ]; then
    fail "Multiple matches. Provide a more specific UUID."
  fi

  local gz_file="$matches"
  local filename project_hash
  filename=$(basename "$gz_file")
  project_hash=$(basename "$(dirname "$gz_file")")
  local file_uuid="${filename%.jsonl.gz}"
  local size_bytes
  size_bytes=$(stat -f %z "$gz_file" 2>/dev/null || echo 0)
  local backed_up_at
  backed_up_at=$(date -u -r "$gz_file" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")

  # Parse JSONL with python3
  local peek_json
  peek_json=$(python3 - "$gz_file" <<'PYEOF'
import json, sys, gzip
from collections import OrderedDict

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

# Merge assistant streaming chunks (each chunk is a different content block)
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
    return role, text[:80].replace("\n", " ").replace('"', '\\"')

count = len(deduped)
first = [extract_text(r) for r in deduped[:2]]
last  = [extract_text(r) for r in deduped[-2:]] if count > 2 else []

# Compute uncompressed size
import os
uncompressed = sum(len(line) for line in lines)

result = {
    "messageCount": count,
    "uncompressedBytes": uncompressed,
    "firstMessages": [{"role": r, "preview": t} for r, t in first],
    "lastMessages": [{"role": r, "preview": t} for r, t in last],
}
print(json.dumps(result))
PYEOF
  )

  if [ $? -ne 0 ] || [ -z "$peek_json" ]; then
    fail "Failed to parse session file"
  fi

  if [ "$JSON_OUTPUT" = true ]; then
    # Merge file metadata with parsed message data
    python3 -c "
import json, sys
meta = {'uuid': sys.argv[1], 'projectHash': sys.argv[2], 'backedUpAt': sys.argv[3], 'sizeBytes': int(sys.argv[4])}
parsed = json.loads(sys.argv[5])
meta.update(parsed)
print(json.dumps(meta))
" "$file_uuid" "$project_hash" "$backed_up_at" "$size_bytes" "$peek_json"
  else
    # Human-readable output
    local msg_count uncompressed_bytes
    msg_count=$(echo "$peek_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['messageCount'])")
    uncompressed_bytes=$(echo "$peek_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['uncompressedBytes'])")
    local uncompressed_k=$(( uncompressed_bytes / 1024 ))
    local size_k=$(( size_bytes / 1024 ))

    printf "\n${BOLD}Session:${NC} $file_uuid\n"
    printf "${BOLD}Project:${NC} $project_hash\n"
    printf "${BOLD}Date:${NC}    $backed_up_at\n"
    printf "${BOLD}Size:${NC}    ${size_k}K (compressed) → ${uncompressed_k}K (uncompressed)\n"

    printf "\n${DIM}── First messages ──────────────────────────────────────${NC}\n"
    echo "$peek_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data['firstMessages']:
    print(f\"  [{m['role']}]  {m['preview']}\")
"

    if [ "$msg_count" -gt 2 ]; then
      printf "\n${DIM}── Last messages ───────────────────────────────────────${NC}\n"
      echo "$peek_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data['lastMessages']:
    print(f\"  [{m['role']}]  {m['preview']}\")
"
    fi

    printf "\n${BOLD}Messages:${NC} $msg_count total\n\n"
  fi
}
```

**Step 2: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 3: Smoke test with human output**

Pick a UUID from `./cli.sh restore --last 1` output. Run:
```bash
./cli.sh peek <uuid>
```
Expected: Session metadata + first/last messages displayed.

**Step 4: Smoke test with JSON output**

Run:
```bash
./cli.sh peek <uuid> --json | python3 -m json.tool
```
Expected: Valid JSON with uuid, projectHash, messageCount, firstMessages, lastMessages.

**Step 5: Commit**

```bash
git add cli.sh
git commit -m "feat: add peek command with JSONL merge parser"
```

---

### Task 7: Update `show_help`

**Files:**
- Modify: `cli.sh` — `show_help` function

**Step 1: Update help text**

Find the entire `show_help` function and replace with:

```bash
show_help() {
  cat <<EOF
${BOLD}Claude Backup${NC} v$VERSION

Back up your Claude Code environment (local or to a private GitHub repo).

${BOLD}Usage:${NC}
  claude-backup                Interactive first-time setup
  claude-backup init           Same as above
  claude-backup init --local   Force local-only mode (no GitHub)
  claude-backup sync           Backup config + sessions
  claude-backup sync --config-only    Config only (fast)
  claude-backup sync --sessions-only  Sessions only
  claude-backup status         Show backup status
  claude-backup peek <uuid>    Preview a session's contents
  claude-backup export-config  Export config as portable tarball
  claude-backup import-config FILE  Import config on new machine
  claude-backup restore --list              List all backed-up sessions
  claude-backup restore --last N            List last N sessions
  claude-backup restore --date YYYY-MM-DD   Sessions from date (UTC)
  claude-backup restore --project NAME      Filter by project name
  claude-backup restore <uuid>              Restore a session
  claude-backup restore <uuid> --force      Overwrite existing session
  claude-backup uninstall      Remove scheduler and optionally data
  claude-backup --help         Show this help
  claude-backup --version      Show version

${BOLD}Global flags:${NC}
  --json     Output structured JSON (for scripts and agents)
  --local    Force local-only mode during init (no GitHub required)

${BOLD}Requirements:${NC}
  git, gzip, macOS. GitHub CLI (gh) optional — enables remote backup.

${BOLD}More info:${NC}
  https://github.com/tombelieber/claude-backup
EOF
}
```

**Step 2: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 3: Smoke test**

Run: `./cli.sh --help`
Expected: Updated help showing peek, --json, --local, revised requirements.

**Step 4: Commit**

```bash
git add cli.sh
git commit -m "feat: update show_help for v3.1 commands and flags"
```

---

### Task 8: Plugin files + Skill

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `skills/backup/SKILL.md`

**Step 1: Create plugin manifest**

```bash
mkdir -p .claude-plugin
```

Create `.claude-plugin/plugin.json`:

```json
{
  "name": "claude-backup",
  "description": "Back up and restore your Claude Code environment",
  "version": "3.1.0",
  "author": { "name": "tombelieber" },
  "repository": "https://github.com/tombelieber/claude-backup"
}
```

**Step 2: Create marketplace manifest**

Create `.claude-plugin/marketplace.json`:

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

**Step 3: Create skill**

```bash
mkdir -p skills/backup
```

Create `skills/backup/SKILL.md`:

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

**Step 4: Update `package.json` files array**

The `package.json` `files` array controls what npm publishes. Add the new directories:

Find in `package.json`:
```json
  "files": [
    "cli.sh",
    "README.md",
    "LICENSE"
  ],
```

Replace with:
```json
  "files": [
    "cli.sh",
    "README.md",
    "LICENSE",
    ".claude-plugin/",
    "skills/"
  ],
```

**Step 5: Commit**

```bash
git add .claude-plugin/ skills/ package.json
git commit -m "feat: add Claude Code plugin manifest and backup skill"
```

---

### Task 9: CLAUDE.md + Contract test

**Files:**
- Create: `CLAUDE.md` (repo root)
- Create: `test/skill-sync.sh`

**Step 1: Create repo CLAUDE.md**

Create `CLAUDE.md` at repo root:

```markdown
# claude-backup

Bash CLI tool that backs up Claude Code environments. Single-file CLI (`cli.sh`) with optional Claude Code plugin (`skills/backup/SKILL.md`).

## Plugin Sync Rule

When modifying `cli.sh` (adding/removing/renaming flags, changing JSON output shapes,
or altering command behavior), you MUST update `skills/backup/SKILL.md` to match.
The skill is the agent's interface to the CLI — if they drift, agents break silently.

Checklist after any cli.sh change:
- [ ] Skill command table matches actual CLI flags
- [ ] JSON response examples in design doc match actual output
- [ ] "When to suggest" section still makes sense

## Code Conventions

- Bash with `set -euo pipefail`
- Use `if/fi` not `&&` for conditionals that guard side effects (the `&&` pattern returns exit 1 under `set -e`)
- Use `((count++)) || true` to guard arithmetic that may evaluate to 0
- Python3 inline scripts receive file paths via `sys.argv`, not shell variable expansion
- All user-facing output goes through `info()`, `warn()`, `fail()`, `step()` — these are JSON-mode-aware
- `log()` writes to the log file in all modes
```

**Step 2: Create contract test**

```bash
mkdir -p test
```

Create `test/skill-sync.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Contract test: verifies that all CLI subcommands and flags appear in the skill.
# Run: bash test/skill-sync.sh
# Exit 0 = all synced, Exit 1 = drift detected.

CLI="cli.sh"
SKILL="skills/backup/SKILL.md"
ERRORS=0

check() {
  local label="$1" pattern="$2" file="$3"
  if ! grep -qF "$pattern" "$file"; then
    echo "MISSING in $file: $pattern ($label)"
    ((ERRORS++)) || true
  fi
}

# Subcommands (from case statement in cli.sh)
for cmd in sync status restore peek export-config import-config; do
  check "subcommand" "$cmd" "$SKILL"
done

# Flags (from arg parsers in cli.sh)
for flag in --json --config-only --sessions-only --list --last --date --project --force; do
  check "flag" "$flag" "$SKILL"
done

# Version triple check: cli.sh, package.json, plugin.json must match
CLI_VER=$(grep -oP 'VERSION="\K[^"]+' "$CLI")
PKG_VER=$(python3 -c "import json; print(json.load(open('package.json'))['version'])")
PLUGIN_VER=$(python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['version'])")

if [ "$CLI_VER" != "$PKG_VER" ]; then
  echo "VERSION MISMATCH: cli.sh=$CLI_VER, package.json=$PKG_VER"
  ((ERRORS++)) || true
fi
if [ "$CLI_VER" != "$PLUGIN_VER" ]; then
  echo "VERSION MISMATCH: cli.sh=$CLI_VER, plugin.json=$PLUGIN_VER"
  ((ERRORS++)) || true
fi

# Syntax check
if ! bash -n "$CLI" 2>/dev/null; then
  echo "SYNTAX ERROR in $CLI"
  ((ERRORS++)) || true
fi

if [ $ERRORS -gt 0 ]; then
  echo ""
  echo "FAIL: $ERRORS issue(s) found. Fix skill-CLI drift before committing."
  exit 1
fi

echo "OK: All subcommands, flags, and versions are in sync."
exit 0
```

**Step 3: Run the contract test**

Run: `bash test/skill-sync.sh`
Expected: Version mismatch (cli.sh says 3.0.0, plugin.json says 3.1.0). This is expected — Task 11 bumps the version. Verify that subcommand and flag checks all pass.

Note: The `--sessions-only` flag is NOT in the skill because it's rarely used by agents. Add it to the skill if the test requires it:

Actually, looking at the skill: it doesn't include `--sessions-only`. And the contract test checks for it. Options:
1. Add `--sessions-only` to the skill
2. Remove the check from the contract test

The skill should only contain what agents need. `--sessions-only` is a niche human flag. Remove it from the contract test. Find:

```bash
for flag in --json --config-only --sessions-only --list --last --date --project --force; do
```

Replace with:

```bash
for flag in --json --config-only --list --last --date --project --force; do
```

Re-run: `bash test/skill-sync.sh`
Expected: Only version mismatch (fixed in Task 11).

**Step 4: Commit**

```bash
git add CLAUDE.md test/
git commit -m "feat: add CLAUDE.md sync rule and skill-CLI contract test"
```

---

### Task 10: Lefthook + CI

**Files:**
- Create: `lefthook.yml`
- Create: `.github/workflows/ci.yml`
- Modify: `package.json` — add devDependencies and prepare script

**Step 1: Create lefthook config**

Create `lefthook.yml`:

```yaml
pre-commit:
  commands:
    skill-sync:
      run: bash test/skill-sync.sh
      glob: "{cli.sh,skills/backup/SKILL.md,.claude-plugin/plugin.json,package.json}"
    bash-syntax:
      run: bash -n cli.sh
      glob: "cli.sh"
```

**Step 2: Create CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  checks:
    name: Lint & Contract Tests
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4.3.1

      - name: Setup Python
        uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065  # v5.6.0
        with:
          python-version: "3.12"

      - name: Bash syntax check
        run: bash -n cli.sh

      - name: Skill-CLI sync check
        run: bash test/skill-sync.sh
```

**Step 3: Update package.json for lefthook**

Find in `package.json`:
```json
  "license": "MIT",
  "engines": {
```

Replace with:
```json
  "license": "MIT",
  "scripts": {
    "prepare": "lefthook install || true"
  },
  "devDependencies": {
    "lefthook": "^1.11.0"
  },
  "engines": {
```

**Step 4: Commit**

```bash
git add lefthook.yml .github/workflows/ci.yml package.json
git commit -m "feat: add lefthook pre-commit and CI workflow for skill-CLI sync"
```

---

### Task 11: Version bump to 3.1.0

**Files:**
- Modify: `cli.sh` — VERSION constant
- Modify: `package.json` — version field
- Verify: `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` already say 3.1.0

**Step 1: Bump in cli.sh**

Find:
```bash
VERSION="3.0.0"
```

Replace with:
```bash
VERSION="3.1.0"
```

**Step 2: Bump in package.json**

Find:
```json
  "version": "3.0.0",
```

Replace with:
```json
  "version": "3.1.0",
```

**Step 3: Run contract test**

Run: `bash test/skill-sync.sh`
Expected: `OK: All subcommands, flags, and versions are in sync.`

**Step 4: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 5: Commit**

```bash
git add cli.sh package.json
git commit -m "chore: bump version to 3.1.0"
```

---

### Task 12: README update

**Files:**
- Modify: `README.md`

**Step 1: Update README**

Key changes needed:
1. Update description: "Back up your entire Claude Code environment — locally or to a private GitHub repo."
2. Update Requirements section: gh is now optional
3. Add Local-Only Mode section
4. Add `peek` to command table
5. Add `--json` to command table
6. Add Plugin section
7. Update Future Plans (remove "Cloud backup backends" — local mode is the first step)

Find the entire opening paragraph:

```markdown
Back up your entire Claude Code environment to a private GitHub repo.
```

Replace with:

```markdown
Back up your entire Claude Code environment — locally or to a private GitHub repo.
```

Find the Requirements section:

```markdown
## Requirements

- **macOS** (Linux coming soon)
- **git**
- **gh** ([GitHub CLI](https://cli.github.com), authenticated via `gh auth login`)
- **gzip** (built-in on macOS)
```

Replace with:

```markdown
## Requirements

- **macOS** (Linux coming soon)
- **git**
- **gzip** (built-in on macOS)
- **gh** ([GitHub CLI](https://cli.github.com)) — *optional*. Enables remote backup to GitHub. Without it, backups are local-only.
```

Find the Commands table and add the new entries. After the `import-config --force` row and before `restore --list`:

Add these rows:
```markdown
| `claude-backup peek <uuid>` | Preview a session's contents |
```

After the `uninstall` row, add:
```markdown
| `claude-backup <any> --json` | Structured JSON output (for scripts/agents) |
| `claude-backup init --local` | Force local-only mode (no GitHub) |
```

Add a new section after "Session Restore" and before "What's Backed Up":

```markdown
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

```
/plugin marketplace add tombelieber/claude-backup
/plugin install claude-backup
```

The plugin provides a skill that teaches Claude the CLI commands. The agent always uses `--json` for structured output.
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for v3.1 (local mode, peek, --json, plugin)"
```

---

### Task 13: End-to-end verification

**No file changes — verification only.**

**Step 1: Syntax check**

Run: `bash -n cli.sh`
Expected: No output

**Step 2: Contract test**

Run: `bash test/skill-sync.sh`
Expected: `OK: All subcommands, flags, and versions are in sync.`

**Step 3: Version check**

Run: `./cli.sh --version`
Expected: `claude-backup v3.1.0`

Run: `./cli.sh --version --json`
Expected: `{"version":"3.1.0"}`

**Step 4: Status (human + JSON)**

Run: `./cli.sh status`
Expected: Shows Mode, Repo (if github), Last backup, sizes, etc.

Run: `./cli.sh status --json | python3 -m json.tool`
Expected: Valid JSON with mode, version, repo, etc.

**Step 5: Sync (JSON)**

Run: `./cli.sh sync --json | python3 -m json.tool`
Expected: Valid JSON with ok, config, sessions, pushed.

**Step 6: Restore listing (JSON)**

Run: `./cli.sh restore --list --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{len(d[\"sessions\"])} sessions')" `
Expected: A count of sessions.

Run: `./cli.sh restore --last 2 --json | python3 -m json.tool`
Expected: Valid JSON with at most 2 sessions.

**Step 7: Peek (human + JSON)**

Pick a UUID from the listing. Run:

```bash
./cli.sh peek <uuid>
```
Expected: Session summary with first/last messages.

```bash
./cli.sh peek <uuid> --json | python3 -m json.tool
```
Expected: Valid JSON with uuid, messageCount, firstMessages, lastMessages.

**Step 8: Help**

Run: `./cli.sh --help`
Expected: Shows peek, --json, --local, updated requirements.

**Step 9: Security — credentials never backed up**

```bash
find ~/.claude-backup/ -name ".credentials.json" -o -name ".encryption_key" | wc -l
```
Expected: 0

**Step 10: Manifest has mode field**

```bash
python3 -c "import json; print(json.load(open('$HOME/.claude-backup/manifest.json')).get('mode', 'MISSING'))"
```
Expected: `github` (for existing installs) — not `MISSING`.

---

## Dependency Graph

```
Task 1 (--json infra)
  ├── Task 2 (local mode: check_requirements + cmd_init)
  │   └── Task 3 (local mode: cmd_sync + cmd_status with --json)
  ├── Task 4 (--json on cmd_sync)
  ├── Task 5 (--json on cmd_restore + export + import)
  └── Task 6 (peek command)
Task 7 (show_help) — depends on Tasks 1-6 being merged
Task 8 (plugin files) — independent, no code deps
Task 9 (CLAUDE.md + contract test) — depends on Task 8
Task 10 (lefthook + CI) — depends on Task 9
Task 11 (version bump) — depends on Tasks 1-10
Task 12 (README) — depends on Tasks 1-11
Task 13 (E2E verification) — depends on all
```

Tasks 4, 5, 6 can be done in parallel after Task 1. Task 8 can be done in parallel with Tasks 2-7.
