# claude-backup v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add config-tier backup, export/import, manifest, and security exclusions to the existing claude-backup bash CLI.

**Architecture:** Single-file bash CLI (`cli.sh`). Extend `cmd_sync` with config copying, add `cmd_export_config` / `cmd_import_config` subcommands, generate `manifest.json` on every sync. All changes are additive — existing session backup logic is untouched.

**Tech Stack:** Bash, git, gh, gzip, tar

---

### Task 1: Add config sync constants and security exclusion list

**Files:**
- Modify: `cli.sh:1-11` (constants block)

**Step 1: Add new constants after existing ones (line 11)**

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

Insert before the `cmd_sync()` line:

```bash
sync_config() {
  local config_added=0

  mkdir -p "$CONFIG_DEST"

  for item in "${CONFIG_ITEMS[@]}"; do
    local src="$CLAUDE_DIR/$item"

    # Skip if source doesn't exist
    [ -e "$src" ] || continue

    # Security check: skip sensitive files
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
write_manifest() {
  local config_files=0 config_size=0
  local session_files=0 session_projects=0 session_size=0 session_uncompressed=0

  if [ -d "$CONFIG_DEST" ]; then
    config_files=$(find "$CONFIG_DEST" -type f 2>/dev/null | wc -l | tr -d ' ')
    config_size=$(du -sb "$CONFIG_DEST" 2>/dev/null | cut -f1 || echo "0")
  fi

  if [ -d "$DEST_DIR" ]; then
    session_files=$(find "$DEST_DIR" -name "*.gz" -type f 2>/dev/null | wc -l | tr -d ' ')
    session_projects=$(find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    session_size=$(du -sb "$DEST_DIR" 2>/dev/null | cut -f1 || echo "0")
  fi

  if [ -d "$SOURCE_DIR" ]; then
    session_uncompressed=$(du -sb "$SOURCE_DIR" 2>/dev/null | cut -f1 || echo "0")
  fi

  cat > "$BACKUP_DIR/manifest.json" <<MANIFEST
{
  "version": "$VERSION",
  "machine": "$(hostname)",
  "user": "$(gh api user --jq .login 2>/dev/null || echo "unknown")",
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

Wrap the existing session sync block (from `log "Starting backup..."` through `info "Compressed: $added..."`) inside:

```bash
  if [ "$sync_sessions_tier" = true ]; then
    # ... existing session sync code (unchanged) ...
  fi
```

**Step 3: Add manifest generation before the git commit**

Before the `cd "$BACKUP_DIR"` / `git add -A` line, add:

```bash
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
      mkdir -p "$tmp_dir/$item"
      cp -R "$src/." "$tmp_dir/$item/"
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
  local input_file="${1:-}"

  if [ -z "$input_file" ]; then
    printf "\n${BOLD}Usage:${NC} claude-backup import-config <file.tar.gz>\n\n"
    return 1
  fi

  if [ ! -f "$input_file" ]; then
    fail "File not found: $input_file"
  fi

  printf "\n${BOLD}Importing Claude Code config...${NC}\n\n"

  # Create temp dir for inspection
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  tar -xzf "$input_file" -C "$tmp_dir"

  local imported=0

  # Import each config item
  for item in "${CONFIG_ITEMS[@]}"; do
    local src="$tmp_dir/$item"
    [ -e "$src" ] || continue

    local dest="$CLAUDE_DIR/$item"

    if [ -d "$src" ]; then
      mkdir -p "$dest"
      # Copy files, but don't overwrite existing
      while IFS= read -r -d '' file; do
        local rel="${file#$src/}"
        local dest_file="$dest/$rel"
        mkdir -p "$(dirname "$dest_file")"
        if [ -f "$dest_file" ]; then
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
      if [ -f "$dest" ]; then
        warn "Skipped (exists): $item"
      else
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        ((imported++)) || true
        info "$item"
      fi
    fi
  done

  # Safety: verify no credentials were imported
  for pattern in "${SENSITIVE_PATTERNS[@]}"; do
    if [ -f "$tmp_dir/$pattern" ]; then
      warn "Ignored sensitive file in archive: $pattern"
    fi
  done

  printf "\n${GREEN}${BOLD}Done!${NC} Imported $imported files.\n"
  printf "${DIM}Restart Claude Code to apply settings.${NC}\n"
  printf "${DIM}Note: Plugins will be downloaded on first launch.${NC}\n\n"
}
```

**Step 2: Add case entry**

```bash
  import-config) cmd_import_config "${2:-}" ;;
```

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

In `cmd_init`, after "Running first backup..." and before scheduling, the existing `cmd_sync` call will now automatically include config. Update the success message at the end:

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

### Task 8: Update README.md

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

Keep it concise. See the design doc for content but don't copy verbatim — README should be user-facing, not design-doc-facing.

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for v2 with config backup and migration"
```

---

### Task 9: Update package.json and .gitignore in backup dir

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

### Task 10: End-to-end verification

**No file changes — verification only.**

**Step 1: Verify full init flow (if not already initialized)**

Run: `./cli.sh status`
Verify: Shows config, sessions, scheduler status, manifest info.

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

**Step 4: Verify export/import round-trip**

```bash
./cli.sh export-config /tmp/test-export.tar.gz
tar -tzf /tmp/test-export.tar.gz  # verify contents, no credentials
# Verify sensitive content warning if applicable
```

**Step 5: Verify security exclusions**

```bash
# Must NOT contain credentials
find ~/.claude-backup/ -name ".credentials.json" -o -name ".encryption_key" | wc -l
# Expected: 0
```

**Step 6: Verify --help shows all commands**

Run: `./cli.sh --help`

**Step 7: Verify --version shows 2.0.0**

Run: `./cli.sh --version`
Expected: `claude-backup v2.0.0`
