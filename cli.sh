#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
BACKUP_DIR="$HOME/.claude-backup"
SOURCE_DIR="$HOME/.claude/projects"
DEST_DIR="$BACKUP_DIR/projects"
LOG_FILE="$BACKUP_DIR/backup.log"
PLIST_NAME="com.claude-session-backup.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"
DATA_REPO_NAME="claude-sessions-backup"

# Colors (if terminal supports it)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' BLUE='' BOLD='' DIM='' NC=''
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
info() { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*"; exit 1; }
step() { printf "  ${DIM}%s${NC} " "$*"; }

show_help() {
  cat <<EOF
${BOLD}Claude Session Backup${NC} v$VERSION

Back up your Claude Code chat sessions to a private GitHub repo.

${BOLD}Usage:${NC}
  claude-session-backup              Interactive first-time setup
  claude-session-backup init         Same as above
  claude-session-backup sync         Run backup now
  claude-session-backup status       Show backup status
  claude-session-backup restore ID   Restore a session by UUID
  claude-session-backup uninstall    Remove scheduler and optionally data
  claude-session-backup --help       Show this help
  claude-session-backup --version    Show version

${BOLD}Requirements:${NC}
  git, gh (GitHub CLI, authenticated), gzip, macOS

${BOLD}More info:${NC}
  https://github.com/tombelieber/claude-session-backup
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
  cli_path=$(command -v claude-session-backup 2>/dev/null || echo "")

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

# --- Subcommand dispatch (placeholder — filled in next tasks) ---

cmd_init() {
  printf "\n${BOLD}Claude Session Backup${NC} v$VERSION\n\n"

  # Check if already initialized
  if [ -d "$BACKUP_DIR/.git" ]; then
    info "Already initialized at $BACKUP_DIR"
    local remote_url
    remote_url=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null || echo "unknown")
    printf "  ${DIM}Remote: ${remote_url}${NC}\n"
    printf "\n  Run ${BOLD}claude-session-backup sync${NC} to backup now.\n\n"
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
      --description "Claude Code session backups (auto-generated)" \
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

  printf "\n${BOLD}${GREEN}All set!${NC} Your sessions are backed up.\n\n"
  printf "  ${BOLD}Commands:${NC}\n"
  printf "    claude-session-backup sync       Run backup now\n"
  printf "    claude-session-backup status      Check last backup\n"
  printf "    claude-session-backup restore ID  Restore a session\n"
  printf "\n"
}
cmd_sync() {
  if [ ! -d "$BACKUP_DIR/.git" ]; then
    fail "Not initialized. Run: claude-session-backup init"
  fi
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
  git commit -q -m "backup $(date '+%Y-%m-%d %H:%M') — $file_count files, $total_size total"
  printf "${GREEN}✓${NC}\n"

  step "Pushing to GitHub..."
  git push -u origin HEAD -q 2>/dev/null
  printf "${GREEN}✓${NC}\n"

  log "Backup pushed successfully"
  printf "\n${GREEN}${BOLD}Done!${NC} Backup complete.\n"
}
cmd_status() {
  printf "\n${BOLD}Claude Session Backup${NC} v$VERSION\n\n"

  if [ ! -d "$BACKUP_DIR/.git" ]; then
    fail "Not initialized. Run: claude-session-backup init"
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

  # Source size
  if [ -d "$SOURCE_DIR" ]; then
    local source_size session_count project_count
    source_size=$(du -sh "$SOURCE_DIR" 2>/dev/null | cut -f1)
    session_count=$(find "$SOURCE_DIR" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
    project_count=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    printf "  ${BOLD}Source size:${NC}  $source_size ($session_count sessions, $project_count projects)\n"
  fi

  # Scheduler status
  if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
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
    printf "\n${BOLD}Usage:${NC} claude-session-backup restore <session-uuid>\n\n"
    printf "  Find session UUIDs with:\n"
    printf "    ls ~/.claude-backup/projects/*/\n\n"
    return 1
  fi

  if [ ! -d "$DEST_DIR" ]; then
    fail "No backups found. Run: claude-session-backup init"
  fi

  # Find matching .gz files
  local matches
  matches=$(find "$DEST_DIR" -name "*${uuid}*" -type f 2>/dev/null)

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
  printf "\n${BOLD}Uninstalling Claude Session Backup${NC}\n\n"

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

case "${1:-}" in
  init|"")       cmd_init ;;
  sync)          cmd_sync ;;
  status)        cmd_status ;;
  restore)       cmd_restore "${2:-}" ;;
  uninstall)     cmd_uninstall ;;
  --help|-h)     show_help ;;
  --version|-v)  echo "claude-session-backup v$VERSION" ;;
  *)             echo "Unknown command: $1"; show_help; exit 1 ;;
esac
