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

# --- Subcommand dispatch (placeholder — filled in next tasks) ---

cmd_init() { echo "TODO: init"; }
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

  # Remove deleted projects
  if [ -d "$DEST_DIR" ]; then
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
  git push -q 2>/dev/null
  printf "${GREEN}✓${NC}\n"

  log "Backup pushed successfully"
  printf "\n${GREEN}${BOLD}Done!${NC} Backup complete.\n"
}
cmd_status() { echo "TODO: status"; }
cmd_restore() { echo "TODO: restore"; }
cmd_uninstall() { echo "TODO: uninstall"; }

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
