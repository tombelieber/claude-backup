#!/usr/bin/env bash
set -euo pipefail

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

# Colors (if terminal supports it)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'

  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' BOLD='' DIM='' NC=''
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
info() { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*"; exit 1; }
step() { printf "  ${DIM}%s${NC} " "$*"; }

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

schedule_launchd() {
  # Resolve absolute path to cli.sh (works whether run via npx or direct)
  local cli_path
  cli_path=$(command -v claude-backup 2>/dev/null || echo "")

  # Fallback: if run directly (not via npm bin), use the backup dir's copy
  if [ -z "$cli_path" ] || [ ! -f "$cli_path" ]; then
    # Copy cli.sh into backup dir so launchd has a stable path
    cp "${BASH_SOURCE[0]}" "$BACKUP_DIR/cli.sh"
    chmod +x "$BACKUP_DIR/cli.sh"
    cli_path="$BACKUP_DIR/cli.sh"
  fi

  mkdir -p "$(dirname "$PLIST_PATH")"

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$cli_path</string>
        <string>sync</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>3</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$BACKUP_DIR/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$BACKUP_DIR/launchd-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
PLIST

  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"
}

# --- Subcommands ---

cmd_init() {
  printf "\n${BOLD}Claude Backup${NC} v$VERSION\n\n"

  # Check if already initialized
  if [ -d "$BACKUP_DIR/.git" ]; then
    info "Already initialized at $BACKUP_DIR"
    local remote_url
    remote_url=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null || echo "unknown")
    printf "  ${DIM}Remote: ${remote_url}${NC}\n"
    printf "\n  Run ${BOLD}claude-backup sync${NC} to backup now.\n\n"
    return 0
  fi

  # Check requirements
  printf "${BOLD}Checking requirements...${NC}\n"
  check_requirements
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

  # Get GitHub username
  local gh_user
  gh_user=$(gh api user --jq .login 2>/dev/null)

  # Create private repo
  printf "${BOLD}Creating private repo...${NC}\n"
  step "github.com/$gh_user/$DATA_REPO_NAME"

  if gh repo view "$gh_user/$DATA_REPO_NAME" &>/dev/null; then
    printf "${YELLOW}exists${NC}\n"
  else
    gh repo create "$DATA_REPO_NAME" --private \
      --description "Claude Code environment backups (auto-generated by claude-backup)" \
      >/dev/null 2>&1
    printf "${GREEN}✓${NC}\n"
  fi
  printf "\n"

  # Initialize local backup directory
  printf "${BOLD}Setting up local backup...${NC}\n"
  mkdir -p "$BACKUP_DIR"
  cd "$BACKUP_DIR"

  if [ ! -d ".git" ]; then
    git init -q -b main
    git remote add origin "https://github.com/$gh_user/$DATA_REPO_NAME.git"
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
GITIGNORE

  info "Initialized at $BACKUP_DIR"
  printf "\n"

  # Run first backup
  printf "${BOLD}Running first backup...${NC}\n"
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
  printf "    claude-backup restore ID       Restore a session\n"
  printf "\n"
}

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

  # Prevent concurrent sync operations (atomic via mkdir)
  local lock_dir="$BACKUP_DIR/.sync.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    local lock_pid
    lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      warn "Another sync is running (PID $lock_pid). Skipping."
      return 0
    fi
    # Stale lock — previous process died
    rm -rf "$lock_dir"
    mkdir "$lock_dir"
  fi
  echo $$ > "$lock_dir/pid"
  trap 'rm -rf "$BACKUP_DIR/.sync.lock"' EXIT

  if [ ! -d "$BACKUP_DIR/.git" ]; then
    fail "Not initialized. Run: claude-backup init"
  fi
  local config_count=0

  # Tier 1: Config backup
  if [ "$sync_config_tier" = true ]; then
    printf "\n${BOLD}Backing up config profile...${NC}\n"
    config_count=$(sync_config)
    info "Config: $config_count files synced"
  fi

  if [ "$sync_sessions_tier" = true ]; then
    if [ ! -d "$SOURCE_DIR" ]; then
      fail "Claude sessions directory not found: $SOURCE_DIR"
    fi
    log "Starting backup..."
    printf "\n${BOLD}Syncing Claude sessions...${NC}\n\n"

    local added=0 updated=0 removed=0
    local total_sessions=0 total_projects=0

    # Count totals for progress
    total_projects=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    total_sessions=$(find "$SOURCE_DIR" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
    step "Found $total_sessions sessions across $total_projects projects"
    printf "\n"

    # Sync each project directory
    while IFS= read -r -d '' project_dir; do
      local project_name
      project_name=$(basename "$project_dir")
      local dest_project="$DEST_DIR/$project_name"
      mkdir -p "$dest_project"

      # Compress JSONL files
      while IFS= read -r -d '' jsonl_file; do
        local filename gz_dest
        filename=$(basename "$jsonl_file")
        gz_dest="$dest_project/${filename}.gz"

        if [ -f "$gz_dest" ] && [ "$jsonl_file" -ot "$gz_dest" ]; then
          continue
        fi

        gzip -cn "$jsonl_file" > "$gz_dest"
        ((added++)) || true
      done < <(find "$project_dir" -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null)

      # Copy non-JSONL files as-is
      while IFS= read -r -d '' other_file; do
        local filename dest_file
        filename=$(basename "$other_file")
        dest_file="$dest_project/$filename"

        if [ -f "$dest_file" ] && [ "$other_file" -ot "$dest_file" ]; then
          continue
        fi

        cp "$other_file" "$dest_file"
        ((updated++)) || true
      done < <(find "$project_dir" -maxdepth 1 -type f ! -name "*.jsonl" -print0 2>/dev/null)

    done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

    # Remove deleted projects (with safety check)
    if [ -d "$DEST_DIR" ]; then
      local source_count backup_count
      source_count=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
      backup_count=$(find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

      if [ "$backup_count" -gt 0 ] && [ "$source_count" -eq 0 ]; then
        warn "Source directory appears empty — skipping removal to protect backups"
        log "WARNING: source empty, skipping deletion pass"
      else
        while IFS= read -r -d '' backup_project; do
          local project_name
          project_name=$(basename "$backup_project")
          if [ ! -d "$SOURCE_DIR/$project_name" ]; then
            log "Removing deleted project: $project_name"
            rm -rf "$backup_project"
            ((removed++)) || true
          fi
        done < <(find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
      fi
    fi

    info "Compressed: $added, copied: $updated, removed: $removed"
    log "Processed: $added compressed, $updated copied, $removed removed"
  fi

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

  # Commit and push
  cd "$BACKUP_DIR"
  git add -A

  if git diff --cached --quiet; then
    info "No changes — already up to date"
    return 0
  fi

  local file_count total_size
  file_count=$(git diff --cached --numstat | wc -l | tr -d ' ')
  total_size=$(du -sh "$DEST_DIR" 2>/dev/null | cut -f1)

  step "Committing $file_count files ($total_size total)..."
  git commit -q -m "backup $(date '+%Y-%m-%d %H:%M') — ${file_count} files, ${total_size} total"
  printf "${GREEN}✓${NC}\n"

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
}
cmd_status() {
  printf "\n${BOLD}Claude Backup${NC} v$VERSION\n\n"

  if [ ! -d "$BACKUP_DIR/.git" ]; then
    fail "Not initialized. Run: claude-backup init"
  fi

  # Remote URL
  local remote_url
  remote_url=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null || echo "unknown")
  printf "  ${BOLD}Repo:${NC}       $remote_url\n"

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
cmd_restore() {
  local uuid="${1:-}"

  if [ -z "$uuid" ]; then
    printf "\n${BOLD}Usage:${NC} claude-backup restore <session-uuid>\n\n"
    printf "  Find session UUIDs with:\n"
    printf "    ls ~/.claude-backup/projects/*/\n\n"
    return 1
  fi

  if [[ ! "$uuid" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    fail "Invalid session identifier: $uuid"
  fi

  if [ ! -d "$DEST_DIR" ]; then
    fail "No backups found. Run: claude-backup init"
  fi

  # Find matching .gz files
  local matches
  matches=$(find "$DEST_DIR" -name "*${uuid}*.gz" -type f 2>/dev/null)

  if [ -z "$matches" ]; then
    fail "No backup found matching: $uuid"
  fi

  local match_count
  match_count=$(echo "$matches" | wc -l | tr -d ' ')

  if [ "$match_count" -gt 1 ]; then
    printf "\n${YELLOW}Multiple matches found:${NC}\n"
    echo "$matches" | while read -r f; do
      printf "  %s\n" "$f"
    done
    printf "\nProvide a more specific UUID.\n\n"
    return 1
  fi

  local gz_file="$matches"
  local filename project_dir
  filename=$(basename "$gz_file" .gz)
  project_dir=$(basename "$(dirname "$gz_file")")

  local target_dir="$SOURCE_DIR/$project_dir"
  local target_file="$target_dir/$filename"

  printf "\n${BOLD}Restoring session:${NC}\n"
  printf "  ${DIM}From:${NC} $gz_file\n"
  printf "  ${DIM}To:${NC}   $target_file\n\n"

  if [ -f "$target_file" ]; then
    warn "File already exists at destination (will not overwrite)"
    return 1
  fi

  mkdir -p "$target_dir"
  gzip -dkc "$gz_file" > "$target_file"
  info "Session restored: $target_file"
  printf "\n"
}
cmd_uninstall() {
  printf "\n${BOLD}Uninstalling Claude Backup${NC}\n\n"

  # Remove launchd schedule
  if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    info "Removed daily schedule"
  else
    info "No schedule found"
  fi

  # Ask about data
  if [ -d "$BACKUP_DIR" ]; then
    printf "\n  Local backup data at: ${DIM}$BACKUP_DIR${NC}\n"
    printf "  ${YELLOW}Delete local backup data?${NC} [y/N] "
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      rm -rf "$BACKUP_DIR"
      info "Deleted $BACKUP_DIR"
    else
      info "Kept $BACKUP_DIR"
    fi
  fi

  printf "\n${DIM}Note: Your GitHub repo was not deleted.${NC}\n"
  printf "${DIM}Delete manually: gh repo delete $DATA_REPO_NAME${NC}\n\n"
}

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

case "${1:-}" in
  init|"")       cmd_init ;;
  sync)          shift; cmd_sync "$@" ;;
  status)        cmd_status ;;
  restore)       cmd_restore "${2:-}" ;;
  uninstall)     cmd_uninstall ;;
  export-config) cmd_export_config "${2:-}" ;;
  import-config) shift; cmd_import_config "$@" ;;
  --help|-h)     show_help ;;
  --version|-v)  echo "claude-backup v$VERSION" ;;
  *)             echo "Unknown command: $1"; show_help; exit 1 ;;
esac
