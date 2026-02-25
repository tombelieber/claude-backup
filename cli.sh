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
cmd_sync() { echo "TODO: sync"; }
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
