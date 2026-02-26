# claude-backup v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add config-tier backup, export/import, manifest, and security exclusions to the existing claude-backup bash CLI.

**Architecture:** Single-file bash CLI (`cli.sh`). Extend `cmd_sync` with config copying, add `cmd_export_config` / `cmd_import_config` subcommands, generate `manifest.json` on every sync. All changes are additive — existing session backup logic is untouched.

**Tech Stack:** Bash, git, gh, gzip, tar

---

## Rollback

If anything goes wrong mid-implementation:

```bash
# Undo the last commit (keeps changes staged)
git reset HEAD~1

# Undo multiple commits back to last known-good state
git log --oneline   # find the good commit hash
git reset <hash>    # unstage all changes since that commit

# Nuclear option: restore cli.sh to last commit
git checkout HEAD -- cli.sh
```

If `~/.claude-backup/` is in a bad state from a failed sync test:

```bash
# Remove partial config backup (safe — source files untouched)
rm -rf ~/.claude-backup/config/

# Remove partial manifest
rm -f ~/.claude-backup/manifest.json
```

---

### Task 1: Add config sync constants and security exclusion list

**Files:**
- Modify: `cli.sh:3-11` (constants block — lines 1-2 are shebang/set, do NOT touch them)

**Step 1: Replace lines 3–11 only** (leave lines 1–2 intact: `#!/usr/bin/env bash` and `set -euo pipefail`)

The full replacement for lines 3–11:

```bash
VERSION="2.0.0"
BACKUP_DIR="$HOME/.claude-backup"
SOURCE_DIR="$HOME/.claude/projects"
CLAUDE_DIR="$HOME/.claude"
DEST_DIR="$BACKUP_DIR/projects"
CONFIG_DEST="$BACKUP_DIR/config"
LOG_FILE="$BACKUP_DIR/backup.log"
PLIST_NAME="com.claude-backup.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"
DATA_REPO_NAME="claude-backup-data"

# Config files/dirs to back up (relative to ~/.claude/)
CONFIG_ITEMS=(
  "settings.json"
  "settings.local.json"
  "CLAUDE.md"
  "agents"
  "hooks"
  "skills"
  "rules"
)

# NEVER backup these (hardcoded, not configurable)
SENSITIVE_PATTERNS=(
  ".credentials.json"
  ".encryption_key"
)
```

**Step 2: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add cli.sh
git commit -m "feat: add v2 constants, config items list, security exclusions"
```

---

### Task 2: Write `sync_config` function

**Files:**
- Modify: `cli.sh` (add function before `cmd_sync`)

**Step 1: Add the `sync_config` function**

Insert before the `cmd_sync()` line at `cli.sh:238`:

```bash
# stdout contract: prints a single integer (count of files synced) — always capture with config_count=$(sync_config)
sync_config() {
  local config_added=0

  mkdir -p "$CONFIG_DEST"

  for item in "${CONFIG_ITEMS[@]}"; do
    local src="$CLAUDE_DIR/$item"

    # Skip if source doesn't exist
    [ -e "$src" ] || continue

    # Top-level security check: skip sensitive top-level items
    local skip=false
    for pattern in "${SENSITIVE_PATTERNS[@]}"; do
      if [[ "$item" == *"$pattern"* ]]; then
        skip=true
        break
      fi
    done
    [ "$skip" = true ] && continue

    local dest="$CONFIG_DEST/$item"

    if [ -d "$src" ]; then
      # Directory: rsync-like copy (only changed files)
      mkdir -p "$dest"
      while IFS= read -r -d '' file; do
        local rel="${file#$src/}"
        local dest_file="$dest/$rel"
        mkdir -p "$(dirname "$dest_file")"

        # Per-file sensitive check: a file inside agents/ or skills/ could be named .credentials.json
        local file_basename
        file_basename=$(basename "$file")
        local file_skip=false
        for pattern in "${SENSITIVE_PATTERNS[@]}"; do
          if [[ "$file_basename" == *"$pattern"* ]]; then
            file_skip=true
            break
          fi
        done
        [ "$file_skip" = true ] && continue

        if [ ! -f "$dest_file" ] || [ "$file" -nt "$dest_file" ]; then
          cp "$file" "$dest_file"
          ((config_added++)) || true
        fi
      done < <(find "$src" -type f -print0 2>/dev/null)
    else
      # Single file: copy if newer
      if [ ! -f "$dest" ] || [ "$src" -nt "$dest" ]; then
        cp "$src" "$dest"
        ((config_added++)) || true
      fi
    fi
  done

  echo "$config_added"
}
```

**Step 2: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 3: Smoke test the function in isolation**

Run: `bash -c 'source cli.sh; sync_config'` won't work because cli.sh executes the case statement. Instead, verify by running the full sync in Task 4.

**Step 4: Commit**

```bash
git add cli.sh
git commit -m "feat: add sync_config function for config-tier backup"
```

---

### Task 3: Write `write_manifest` function

**Files:**
- Modify: `cli.sh` (add function after `sync_config`)

**Step 1: Add the `write_manifest` function**

```bash
# Portable byte-count helper (macOS has no du -sb)
dir_bytes() {
  find "$1" -type f -exec stat -f %z {} + 2>/dev/null | awk '{s+=$1}END{print s+0}'
}

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

  # Extract username from git remote URL (no network call — works offline)
  # Handles both HTTPS (https://github.com/user/repo) and SSH (git@github.com:user/repo)
  local cached_user
  cached_user=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null \
    | sed 's|https://[^/]*/\([^/]*\)/.*|\1|; s|git@[^:]*:\([^/]*\)/.*|\1|' \
    | grep -E '^[a-zA-Z0-9._-]+$' \
    || echo "unknown")

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
}
```

**Step 2: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 3: Commit**

```bash
git add cli.sh
git commit -m "feat: add write_manifest function for backup metadata"
```

---

### Task 4: Integrate config sync + manifest into `cmd_sync`

**Files:**
- Modify: `cli.sh` — `cmd_sync` function

**Step 1: Add flag parsing to `cmd_sync`**

Replace the `cmd_sync()` opening with:

```bash
cmd_sync() {
  local sync_config_tier=true
  local sync_sessions_tier=true

  # Parse flags
  for arg in "$@"; do
    case "$arg" in
      --config-only)  sync_sessions_tier=false ;;
      --sessions-only) sync_config_tier=false ;;
    esac
  done
```

**Step 2: Wrap existing session logic in a conditional**

After the lock/init checks and before `log "Starting backup..."`, add:

```bash
  local config_count=0

  # Tier 1: Config backup
  if [ "$sync_config_tier" = true ]; then
    printf "\n${BOLD}Backing up config profile...${NC}\n"
    config_count=$(sync_config)
    info "Config: $config_count files synced"
  fi
```

Wrap the existing session sync block (from `log "Starting backup..."` through `info "Compressed: $added, copied: $updated, removed: $removed"` — **do not rely on line numbers here; use these exact strings to locate the block, as Tasks 1-3 will have shifted them by ~120 lines**) inside:

```bash
  if [ "$sync_sessions_tier" = true ]; then
    # ... existing session sync code (unchanged) ...
  fi
```

**Step 3: Add history.jsonl backup and manifest generation before the git commit**

Before the `cd "$BACKUP_DIR"` / `git add -A` line, add:

```bash
  # Backup history.jsonl (Tier 2)
  if [ "$sync_sessions_tier" = true ] && [ -f "$CLAUDE_DIR/history.jsonl" ]; then
    if [ ! -f "$BACKUP_DIR/history.jsonl.gz" ] || \
       [ "$CLAUDE_DIR/history.jsonl" -nt "$BACKUP_DIR/history.jsonl.gz" ]; then
      gzip -cn "$CLAUDE_DIR/history.jsonl" > "$BACKUP_DIR/history.jsonl.gz"
      info "history.jsonl backed up"
    fi
  fi

  # Write manifest
  write_manifest
```

**Step 4: Update the case statement to pass flags**

Change the sync case from:
```bash
  sync)          cmd_sync ;;
```
to:
```bash
  sync)          shift; cmd_sync "$@" ;;
```

**Step 5: Verify syntax**

Run: `bash -n cli.sh`
Expected: No output

**Step 6: Test full sync**

Run: `./cli.sh sync`
Expected: See both "Backing up config profile..." and "Syncing Claude sessions..." output. Check `~/.claude-backup/config/` has settings.json, CLAUDE.md, etc. Check `manifest.json` exists.

**Step 7: Test --config-only**

Run: `./cli.sh sync --config-only`
Expected: See "Backing up config profile..." but NOT "Syncing Claude sessions..."

**Step 8: Commit**

```bash
git add cli.sh
git commit -m "feat: integrate config sync and manifest into cmd_sync with tier flags"
```

---

### Task 5: Add `cmd_export_config` command

**Files:**
- Modify: `cli.sh` (add function + case)

**Step 1: Add the function**

```bash
cmd_export_config() {
  local output_file="${1:-}"
  local timestamp
  timestamp=$(date '+%Y-%m-%d')

  if [ -z "$output_file" ]; then
    output_file="$HOME/claude-config-${timestamp}.tar.gz"
  fi

  printf "\n${BOLD}Exporting Claude Code config...${NC}\n\n"

  # Create temp dir for export
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  local exported=0

  for item in "${CONFIG_ITEMS[@]}"; do
    local src="$CLAUDE_DIR/$item"
    [ -e "$src" ] || continue

    if [ -d "$src" ]; then
      # Use filtered per-file copy (same logic as sync_config) — cp -R would bypass sensitive-file checks
      while IFS= read -r -d '' file; do
        local file_basename
        file_basename=$(basename "$file")
        local file_skip=false
        for pattern in "${SENSITIVE_PATTERNS[@]}"; do
          if [[ "$file_basename" == *"$pattern"* ]]; then
            file_skip=true
            break
          fi
        done
        [ "$file_skip" = true ] && continue
        local rel="${file#$src/}"
        mkdir -p "$tmp_dir/$item/$(dirname "$rel")"
        cp "$file" "$tmp_dir/$item/$rel"
      done < <(find "$src" -type f -print0 2>/dev/null)
    else
      cp "$src" "$tmp_dir/$item"
    fi
    ((exported++)) || true

    # Print what's included
    if [ -d "$src" ]; then
      local count
      count=$(find "$src" -type f 2>/dev/null | wc -l | tr -d ' ')
      info "$item/ ($count files)"
    else
      info "$item"
    fi
  done

  if [ "$exported" -eq 0 ]; then
    warn "No config files found to export"
    return 1
  fi

  # Security scan: warn if any file contains sensitive patterns
  local sensitive_found=false
  while IFS= read -r -d '' file; do
    if grep -qiE '(token|secret|password|api.?key)' "$file" 2>/dev/null; then
      local rel="${file#$tmp_dir/}"
      warn "Potentially sensitive content in: $rel"
      sensitive_found=true
    fi
  done < <(find "$tmp_dir" -type f -print0 2>/dev/null)

  if [ "$sensitive_found" = true ]; then
    printf "\n  ${YELLOW}Review the files above before sharing this export.${NC}\n"
  fi

  # Create tarball
  tar -czf "$output_file" -C "$tmp_dir" .
  local size
  size=$(du -h "$output_file" 2>/dev/null | cut -f1 | tr -d ' ')

  printf "\n${GREEN}${BOLD}Exported${NC} to ${BOLD}${output_file}${NC} (${size})\n"
  printf "${DIM}Transfer via AirDrop, USB, or email. Import with:${NC}\n"
  printf "  claude-backup import-config ${output_file}\n\n"
}
```

**Step 2: Add case entry**

In the case statement, add before the `--help` line:

```bash
  export-config) cmd_export_config "${2:-}" ;;
```

**Step 3: Verify syntax**

Run: `bash -n cli.sh`

**Step 4: Test export**

Run: `./cli.sh export-config`
Expected: See list of exported files, tarball created at `~/claude-config-YYYY-MM-DD.tar.gz`. Verify contents: `tar -tzf ~/claude-config-*.tar.gz`

**Step 5: Commit**

```bash
git add cli.sh
git commit -m "feat: add export-config command for portable config tarball"
```

---

### Task 6: Add `cmd_import_config` command

**Files:**
- Modify: `cli.sh` (add function + case)

**Step 1: Add the function**

```bash
cmd_import_config() {
  local input_file=""
  local force=false

  # Parse args
  for arg in "$@"; do
    case "$arg" in
      --force) force=true ;;
      *)       [ -z "$input_file" ] && input_file="$arg" ;;
    esac
  done

  if [ -z "$input_file" ]; then
    printf "\n${BOLD}Usage:${NC} claude-backup import-config <file.tar.gz> [--force]\n\n"
    printf "  ${DIM}--force  Overwrite existing files${NC}\n\n"
    return 1
  fi

  if [ ! -f "$input_file" ]; then
    fail "File not found: $input_file"
  fi

  printf "\n${BOLD}Importing Claude Code config...${NC}\n"
  if [ "$force" = true ]; then
    printf "  ${YELLOW}Force mode: existing files will be overwritten${NC}\n"
  fi
  printf "\n"

  # Create temp dir for inspection
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  tar -xzf "$input_file" -C "$tmp_dir"

  # Security check BEFORE copying anything: abort if archive contains sensitive files (including nested)
  for pattern in "${SENSITIVE_PATTERNS[@]}"; do
    local basename_pattern
    basename_pattern=$(basename "$pattern")
    if find "$tmp_dir" -name "$basename_pattern" -print -quit 2>/dev/null | grep -q .; then
      fail "Archive contains sensitive file matching '$basename_pattern' — import aborted. Inspect with: tar -tzf $input_file"
    fi
  done

  local imported=0

  # Import each config item
  for item in "${CONFIG_ITEMS[@]}"; do
    local src="$tmp_dir/$item"
    [ -e "$src" ] || continue

    local dest="$CLAUDE_DIR/$item"

    if [ -d "$src" ]; then
      mkdir -p "$dest"
      while IFS= read -r -d '' file; do
        local rel="${file#$src/}"
        local dest_file="$dest/$rel"
        mkdir -p "$(dirname "$dest_file")"
        if [ -f "$dest_file" ] && [ "$force" = false ]; then
          warn "Skipped (exists): $item/$rel"
        else
          cp "$file" "$dest_file"
          ((imported++)) || true
        fi
      done < <(find "$src" -type f -print0 2>/dev/null)
      local count
      count=$(find "$src" -type f 2>/dev/null | wc -l | tr -d ' ')
      info "$item/ ($count files)"
    else
      if [ -f "$dest" ] && [ "$force" = false ]; then
        warn "Skipped (exists): $item"
      else
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        ((imported++)) || true
        info "$item"
      fi
    fi
  done

  printf "\n${GREEN}${BOLD}Done!${NC} Imported $imported files.\n"
  printf "${DIM}Restart Claude Code to apply settings.${NC}\n"
  printf "${DIM}Note: Plugins will be downloaded on first launch.${NC}\n\n"
}
```

**Step 2: Add case entry**

```bash
  import-config) shift; cmd_import_config "$@" ;;
```

> **Note on shift pattern:** `export-config` (Task 5) does NOT use `shift` — it passes `${2:-}` directly because `cmd_export_config` takes a single optional positional arg. `import-config` uses `shift; "$@"` because `cmd_import_config` takes variadic args (`--force`, filename in any order). Do NOT "fix" export-config to match this pattern.

**Step 3: Verify syntax**

Run: `bash -n cli.sh`

**Step 4: Test round-trip**

Run:
```bash
./cli.sh export-config /tmp/test-config.tar.gz
tar -tzf /tmp/test-config.tar.gz   # inspect contents
# Verify no .credentials.json or .encryption_key in tarball
```

**Step 5: Commit**

```bash
git add cli.sh
git commit -m "feat: add import-config command for machine migration"
```

---

### Task 7: Update `cmd_init`, `cmd_status`, `show_help`

**Files:**
- Modify: `cli.sh` — three existing functions

**Step 1: Update `cmd_init`**

In `cmd_init`, find and replace the success message block starting at `printf "\n${BOLD}${GREEN}All set!${NC} Your sessions are backed up.\n\n"` (current line ~231) with:

```bash
  printf "\n${BOLD}${GREEN}All set!${NC} Your Claude Code environment is backed up.\n\n"
  printf "  ${BOLD}Commands:${NC}\n"
  printf "    claude-backup sync            Run backup now\n"
  printf "    claude-backup status           Check last backup\n"
  printf "    claude-backup export-config    Export config for sharing\n"
  printf "    claude-backup restore ID       Restore a session\n"
  printf "\n"
```

Also update the repo description in the `gh repo create` call:

```bash
    gh repo create "$DATA_REPO_NAME" --private \
      --description "Claude Code environment backups (auto-generated by claude-backup)" \
```

**Step 2: Update `cmd_status`**

Add config info after the backup size block:

```bash
  # Config backup
  if [ -d "$CONFIG_DEST" ]; then
    local config_count config_size
    config_count=$(find "$CONFIG_DEST" -type f 2>/dev/null | wc -l | tr -d ' ')
    config_size=$(du -sh "$CONFIG_DEST" 2>/dev/null | cut -f1)
    printf "  ${BOLD}Config:${NC}      $config_size ($config_count files)\n"
  fi
```

**Step 3: Update `show_help`**

Replace the entire help text with:

```bash
show_help() {
  cat <<EOF
${BOLD}Claude Backup${NC} v$VERSION

Back up your Claude Code environment to a private GitHub repo.

${BOLD}Usage:${NC}
  claude-backup                Interactive first-time setup
  claude-backup init           Same as above
  claude-backup sync           Backup config + sessions
  claude-backup sync --config-only    Config only (fast)
  claude-backup sync --sessions-only  Sessions only
  claude-backup status         Show backup status
  claude-backup export-config  Export config as portable tarball
  claude-backup import-config FILE  Import config on new machine
  claude-backup restore ID     Restore a session by UUID
  claude-backup uninstall      Remove scheduler and optionally data
  claude-backup --help         Show this help
  claude-backup --version      Show version

${BOLD}Requirements:${NC}
  git, gh (GitHub CLI, authenticated), gzip, macOS

${BOLD}More info:${NC}
  https://github.com/tombelieber/claude-backup
EOF
}
```

**Step 4: Verify syntax**

Run: `bash -n cli.sh`

**Step 5: Test help and status**

Run: `./cli.sh --help` — verify new commands shown
Run: `./cli.sh status` — verify config line shown

**Step 6: Commit**

```bash
git add cli.sh
git commit -m "feat: update init, status, help for v2 config backup"
```

---

### Task 8: Bump version and update .gitignore in backup dir

**Files:**
- Modify: `package.json` — bump version
- Modify: `cli.sh` — update .gitignore in `cmd_init`

**Step 1: Bump version in package.json**

Change `"version": "1.0.0"` to `"version": "2.0.0"`.

**Step 2: Update .gitignore in cmd_init**

Add `*.tmp` and `.sync.lock/` to the generated .gitignore:

```bash
  cat > "$BACKUP_DIR/.gitignore" <<'GITIGNORE'
backup.log
launchd-stdout.log
launchd-stderr.log
*.lock
*.tmp
.sync.lock/
cli.sh
GITIGNORE
```

**Step 3: Commit**

```bash
git add package.json cli.sh
git commit -m "chore: bump version to 2.0.0, update backup .gitignore"
```

---

### Task 9: Update README.md

**Files:**
- Modify: `README.md`

**Step 1: Rewrite README for v2**

Update the README to document:
- Two-tier backup explanation (config + sessions)
- Updated command table with new commands
- Machine migration section (export/import flow)
- Updated storage layout table
- What's backed up / what's excluded
- Security section

Keep it concise. Reference the design doc at `docs/plans/2026-02-25-claude-backup-v2-design.md` for content but don't copy verbatim — README should be user-facing, not design-doc-facing.

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for v2 with config backup and migration"
```

---

### Task 10: End-to-end verification

**No file changes — verification only.**

**Step 1: Check current state**

Run: `./cli.sh status`

If already initialized (shows existing backup info): proceed to Step 2.
If not initialized (fails with "Not initialized"): run `./cli.sh init` first, then continue from Step 2.

**Step 2: Verify sync with both tiers**

Run: `./cli.sh sync`
Verify:
- `~/.claude-backup/config/settings.json` exists
- `~/.claude-backup/config/CLAUDE.md` exists (if source exists)
- `~/.claude-backup/config/agents/` has files (if source has files)
- `~/.claude-backup/config/skills/` has files
- `~/.claude-backup/manifest.json` exists with valid JSON
- No `.credentials.json` or `.encryption_key` anywhere in `~/.claude-backup/`

**Step 3: Verify config-only sync**

Run: `./cli.sh sync --config-only`
Verify: Only config output, no session output.

**Step 4: Verify history.jsonl is backed up**

Run: `ls -la ~/.claude-backup/history.jsonl.gz`
Expected: File exists, is a gzip-compressed copy of `~/.claude/history.jsonl`

**Step 5: Verify manifest.json is valid and works offline**

Run: `cat ~/.claude-backup/manifest.json | python3 -m json.tool`
Expected: Valid JSON with version, machine, user, config, sessions fields. User field is populated (extracted from git remote, no network call).

**Step 6: Verify export/import round-trip**

```bash
./cli.sh export-config /tmp/test-export.tar.gz
tar -tzf /tmp/test-export.tar.gz  # verify contents, no credentials
# Verify sensitive content warning if applicable
```

**Step 7: Verify import --force flag**

```bash
# Without --force: existing files should be skipped
./cli.sh import-config /tmp/test-export.tar.gz
# Expected: "Skipped (exists)" warnings for all files

# With --force: existing files should be overwritten
./cli.sh import-config /tmp/test-export.tar.gz --force
# Expected: No skip warnings, files overwritten
```

**Step 8: Verify security exclusions**

```bash
# Must NOT contain credentials
find ~/.claude-backup/ -name ".credentials.json" -o -name ".encryption_key" | wc -l
# Expected: 0
```

**Step 9: Verify --help shows all commands**

Run: `./cli.sh --help`
Expected: Shows export-config, import-config (with --force note), sync flags

**Step 10: Verify --version shows 2.0.0**

Run: `./cli.sh --version`
Expected: `claude-backup v2.0.0`

---

## Changelog of Fixes Applied (Audit → Final Plan)

| # | Issue | Severity | Fix Applied |
|---|-------|----------|-------------|
| 1 | `du -sb` doesn't exist on macOS | Blocker | Replaced with portable `dir_bytes()` helper using `stat -f %z + awk` |
| 2 | `gh api user` network call on every sync (fails offline) | Blocker | Replaced with git remote URL parse — zero network calls |
| 3 | `history.jsonl` in design doc but missing from implementation | Blocker | Added gzip backup of `~/.claude/history.jsonl` in session sync block |
| 4 | Task 1 replacement block omits `#!/usr/bin/env bash` and `set -euo pipefail` | Blocker | Clarified instruction: replace lines 3–11 only, leave lines 1–2 intact |
| 5 | Task 4 anchor `info "Compressed: $added..."` doesn't exist verbatim | Blocker | Fixed to exact string: `info "Compressed: $added, copied: $updated, removed: $removed"` at line 333 |
| 6 | No rollback/recovery procedure | Blocker | Added Rollback section before Task 1 |
| 7 | `import-config` had no override option for existing files | Warning | Added `--force` flag to `cmd_import_config` |
| 8 | Task 4 Step 2 line references were paraphrased | Warning | Added exact line numbers (262, 333) |
| 9 | Task 10 Step 1 "if not already initialized" was ambiguous | Warning | Clarified both branches (initialized vs not) |
| 10 | Task 7 Step 1 didn't specify what string to replace | Warning | Added exact current string to find and replace |
| 11 | Task 9 referenced "the design doc" without a path | Minor | Added explicit path: `docs/plans/2026-02-25-claude-backup-v2-design.md` |
| 12 | Task 2 insertion point had no line number | Minor | Added `cli.sh:238` |
| 13 | Task 5/6 inconsistent shift pattern unexplained | Minor | Added explicit note explaining why export-config must NOT use shift |
| 14 | Tasks 8 and 9 were in wrong order (README before version bump) | Minor | Swapped: version bump is now Task 8, README is Task 9 |
| 15 | `sync_config` directory branch used no per-file basename check — a `.credentials.json` nested inside `agents/` or `skills/` would bypass SENSITIVE_PATTERNS | Blocker | Added per-file basename check inside the `while IFS= read` loop before each `cp` |
| 16 | `cmd_import_config` security check fired AFTER files copied to disk; only checked top-level `$tmp_dir/$pattern`; said "Ignored" but file was already written | Blocker | Moved check immediately after `tar -xzf`, before any copying; uses `find "$tmp_dir" -name "$basename_pattern"` for nested detection; uses `fail` (abort) not `warn`; removed stale post-import check |
| 17 | `cmd_export_config` used `cp -R` for directories — same bypass risk as #15 | Blocker | Replaced with filtered per-file loop matching `sync_config` pattern |
| 18 | Task 4 Step 2 line numbers (262, 333) will be stale after Tasks 1-3 insert ~120 lines | Warning | Removed line numbers; instruction now says "use these exact strings to locate the block" |
| 19 | `sync_config` stdout contract undocumented (executors could misuse the function) | Warning | Added comment above function: `# stdout contract: prints a single integer — always capture with config_count=$(sync_config)` |
| 20 | `write_manifest` sed regex requires 2 `/` separators — SSH remotes (`git@github.com:user/repo`) have only 1 and return the full URL as `cached_user` | Warning | Replaced single-branch sed with two-branch expression: HTTPS branch + SSH branch (`s\|git@[^:]*:\([^/]*\)/.*\|\1\|`) |
| 21 | `\|\| echo "unknown"` fallback didn't fire when sed returned a non-matching raw URL (e.g. `file://`, `ssh://`, non-standard remotes) — `sed` exits 0 on no-match, so `\|\|` never triggered | Warning | Added `\| grep -E '^[a-zA-Z0-9._-]+$'` after sed — validates output looks like a GitHub username; raw URLs fail the grep, causing `\|\| echo "unknown"` to fire correctly |
