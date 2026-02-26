#!/usr/bin/env bash
set -euo pipefail

VERSION="3.1.0"
BACKUP_DIR="$HOME/.claude-backup"
SOURCE_DIR="$HOME/.claude/projects"
CLAUDE_DIR="$HOME/.claude"
DEST_DIR="$BACKUP_DIR/projects"
CONFIG_DEST="$BACKUP_DIR/config"
LOG_FILE="$BACKUP_DIR/backup.log"
SERVICE_LABEL="com.claude-backup"
PLIST_PATH="$HOME/Library/LaunchAgents/com.claude-backup.plist"
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
info() { if [ "$JSON_OUTPUT" != true ]; then printf "  ${GREEN}✓${NC} %s\n" "$*"; fi; }
warn() { if [ "$JSON_OUTPUT" != true ]; then printf "  ${YELLOW}!${NC} %s\n" "$*"; fi; }
fail() {
  if [ "$JSON_OUTPUT" = true ]; then
    local escaped
    escaped=$(printf '%s' "$*" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')
    printf '{"error":"%s"}\n' "$escaped" >&2
  else
    printf "  ${RED}✗${NC} %s\n" "$*"
  fi
  exit 1
}
step() { if [ "$JSON_OUTPUT" != true ]; then printf "  ${DIM}%s${NC} " "$*"; fi; }
json_out() { if [ "$JSON_OUTPUT" = true ]; then printf '%s\n' "$1"; fi; }
json_err() { if [ "$JSON_OUTPUT" = true ]; then printf '%s\n' "$1" >&2; fi; }
json_escape() { python3 -c "import json,sys; sys.stdout.write(json.dumps(sys.argv[1])[1:-1])" "$1"; }

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
  git, gzip, python3, macOS. GitHub CLI (gh) optional — enables remote backup.

${BOLD}More info:${NC}
  https://github.com/tombelieber/claude-backup
EOF
}

# Checks git and gzip. Hard-fails if missing (always required).
check_core_requirements() {
  local ok=true

  step "git"
  if command -v git &>/dev/null; then
    if [ "$JSON_OUTPUT" != true ]; then printf "${GREEN}✓${NC}\n"; fi
  else
    if [ "$JSON_OUTPUT" != true ]; then printf "${RED}✗ not found${NC}\n"; fi
    ok=false
  fi

  step "gzip"
  if command -v gzip &>/dev/null; then
    if [ "$JSON_OUTPUT" != true ]; then printf "${GREEN}✓${NC}\n"; fi
  else
    if [ "$JSON_OUTPUT" != true ]; then printf "${RED}✗ not found${NC}\n"; fi
    ok=false
  fi

  step "python3"
  if command -v python3 &>/dev/null; then
    if [ "$JSON_OUTPUT" != true ]; then printf "${GREEN}✓${NC}\n"; fi
  else
    if [ "$JSON_OUTPUT" != true ]; then printf "${RED}✗ not found${NC}\n"; fi
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
    <string>$SERVICE_LABEL</string>
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

  local domain="gui/$(id -u)"
  launchctl bootout "$domain/$SERVICE_LABEL" 2>/dev/null || true
  launchctl bootstrap "$domain" "$PLIST_PATH"
}

# --- Subcommands ---

cmd_init() {
  printf "\n${BOLD}Claude Backup${NC} v$VERSION\n\n"

  # Check if already initialized
  if [ -d "$BACKUP_DIR/.git" ]; then
    info "Already initialized at $BACKUP_DIR"
    local mode
    mode=$(read_backup_mode)
    if [ "$mode" != "local" ]; then
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
  if [ "$JSON_OUTPUT" != true ]; then printf "${BOLD}Checking requirements...${NC}\n"; fi
  check_core_requirements
  if [ "$JSON_OUTPUT" != true ]; then printf "\n"; fi

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
    if [ "$BACKUP_MODE" != "local" ]; then
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

machine_slug() {
  # Compute a filesystem-safe slug from the short hostname
  local slug
  slug=$(hostname -s | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/^-*//; s/-*$//' | cut -c1-64)
  if [ -z "$slug" ]; then
    slug="unknown"
  fi
  echo "$slug"
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
  if [ "$mode" != "local" ]; then
    cached_user=$(cd "$BACKUP_DIR" && git remote get-url origin 2>/dev/null \
      | sed 's|https://[^/]*/\([^/]*\)/.*|\1|; s|git@[^:]*:\([^/]*\)/.*|\1|' \
      | grep -E '^[a-zA-Z0-9._-]+$' \
      || echo "unknown")
  fi

  cat > "$BACKUP_DIR/manifest.json" <<MANIFEST
{
  "version": "$VERSION",
  "mode": "$mode",
  "machine": "$(json_escape "$(hostname)")",
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

build_session_index() {
  # Scans ~/.claude-backup/projects/ and writes session-index.json.
  # One entry per *.jsonl.gz file. Sorted newest-first by backedUpAt.
  # v4: also scan *.jsonl.age.gz when encryption is added.
  local index_file="$BACKUP_DIR/session-index.json"
  local entries=""
  local count=0

  while IFS= read -r -d '' gz_file; do
    local filename project_hash uuid size_bytes mod_time
    filename=$(basename "$gz_file")
    project_hash=$(basename "$(dirname "$gz_file")")
    uuid="${filename%.jsonl.gz}"
    size_bytes=$(stat -f %z "$gz_file" 2>/dev/null || echo 0)
    mod_time=$(date -u -r "$gz_file" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")

    [ $count -gt 0 ] && entries="${entries},"
    entries="${entries}
    {\"uuid\":\"${uuid}\",\"projectHash\":\"${project_hash}\",\"sizeBytes\":${size_bytes},\"backedUpAt\":\"${mod_time}\"}"
    ((count++)) || true  # || true: (( )) exits 1 when result is 0; guards against set -e
  done < <(find "$DEST_DIR" -name "*.jsonl.gz" -type f -print0 2>/dev/null)

  if [ $count -eq 0 ]; then
    cat > "$index_file" <<INDEX
{
  "version": "$VERSION",
  "generatedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "sessions": []
}
INDEX
  else
    cat > "$index_file" <<INDEX
{
  "version": "$VERSION",
  "generatedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "sessions": [${entries}
  ]
}
INDEX
  fi
}

# stdout contract: prints pipe-delimited rows (uuid|projectHash|sizeBytes|backedUpAt) — sorted newest first.
# Args: <mode> <arg>
#   mode=all     arg=ignored      → all sessions
#   mode=last    arg=N            → last N sessions
#   mode=date    arg=YYYY-MM-DD   → sessions where backedUpAt starts with arg (UTC)
#   mode=project arg=partial      → sessions where projectHash contains arg (case-insensitive)
query_session_index() {
  local mode="${1:-all}"
  local arg="${2:-}"
  local index_file="$BACKUP_DIR/session-index.json"

  [ -f "$index_file" ] || { warn "No session index. Run: claude-backup sync" >&2; return 1; }

  python3 - "$mode" "$arg" "$index_file" <<'PYEOF'
import json, sys

mode = sys.argv[1]
arg  = sys.argv[2]
path = sys.argv[3]

with open(path) as f:
    data = json.load(f)

sessions = data.get("sessions", [])
sessions.sort(key=lambda s: s.get("backedUpAt", ""), reverse=True)

if mode == "last":
    sessions = sessions[:int(arg) if arg else 10]
elif mode == "date":
    sessions = [s for s in sessions if s.get("backedUpAt", "").startswith(arg)]
elif mode == "project":
    sessions = [s for s in sessions if arg.lower() in s.get("projectHash", "").lower()]

for s in sessions:
    print(f"{s['uuid']}|{s['projectHash']}|{s['sizeBytes']}|{s['backedUpAt']}")
PYEOF
}

cmd_sync() {
  local sync_config_tier=true
  local sync_sessions_tier=true
  local json_config_count=0
  local json_added=0 json_updated=0 json_removed=0
  local json_pushed=false

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

  # v3 migration: ensure session-index.json is gitignored (existing installs)
  local gi="$BACKUP_DIR/.gitignore"
  if [ -f "$gi" ] && ! grep -qF 'session-index.json' "$gi"; then
    echo 'session-index.json' >> "$gi"
  fi

  local config_count=0

  # Tier 1: Config backup
  if [ "$sync_config_tier" = true ]; then
    if [ "$JSON_OUTPUT" != true ]; then printf "\n${BOLD}Backing up config profile...${NC}\n"; fi
    config_count=$(sync_config)
    json_config_count=$config_count
    info "Config: $config_count files synced"
  fi

  if [ "$sync_sessions_tier" = true ]; then
    if [ ! -d "$SOURCE_DIR" ]; then
      fail "Claude sessions directory not found: $SOURCE_DIR"
    fi
    log "Starting backup..."
    if [ "$JSON_OUTPUT" != true ]; then printf "\n${BOLD}Syncing Claude sessions...${NC}\n\n"; fi

    local added=0 updated=0 removed=0
    local total_sessions=0 total_projects=0

    # Count totals for progress
    total_projects=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    total_sessions=$(find "$SOURCE_DIR" -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
    step "Found $total_sessions sessions across $total_projects projects"
    if [ "$JSON_OUTPUT" != true ]; then printf "\n"; fi

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

    json_added=$added
    json_updated=$updated
    json_removed=$removed
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

  # Write manifest (always) and session index (only when sessions were synced)
  write_manifest
  if [ "$sync_sessions_tier" = true ]; then build_session_index; fi

  # Commit and push
  cd "$BACKUP_DIR"
  git add -A

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

  local file_count total_size
  file_count=$(git diff --cached --numstat | wc -l | tr -d ' ')
  total_size=$(du -sh "$DEST_DIR" 2>/dev/null | cut -f1)

  step "Committing $file_count files ($total_size total)..."
  git commit -q -m "backup $(date '+%Y-%m-%d %H:%M') — ${file_count} files, ${total_size} total"
  if [ "$JSON_OUTPUT" != true ]; then printf "${GREEN}✓${NC}\n"; fi

  local mode="${BACKUP_MODE:-$(read_backup_mode)}"
  if [ "$mode" != "local" ]; then
    step "Pushing to remote..."
    local push_output
    if ! push_output=$(git push -u origin HEAD -q 2>&1); then
      if [ "$JSON_OUTPUT" != true ]; then printf "${RED}FAILED${NC}\n"; fi
      warn "Push failed. Check your GitHub authentication and network."
      json_err '{"error":"Push failed. Check your GitHub authentication and network."}'
      log "Push failed"
      return 1
    fi
    if [ "$JSON_OUTPUT" != true ]; then printf "${GREEN}✓${NC}\n"; fi
    log "Backup pushed successfully"
    json_pushed=true
  else
    log "Backup committed locally (local mode — no push)"
  fi

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
}
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

  # Remote URL (remote modes only)
  if [ "$mode" != "local" ]; then
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
  if launchctl list "$SERVICE_LABEL" &>/dev/null; then
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
  if [ "$mode" != "local" ]; then
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
  if launchctl list "$SERVICE_LABEL" &>/dev/null; then
    scheduler="active"
  fi

  local index_sessions=0
  local index_file="$BACKUP_DIR/session-index.json"
  if [ -f "$index_file" ]; then
    index_sessions=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('sessions',[])))" "$index_file" 2>/dev/null || echo "0")
  fi

  printf '{"version":"%s","mode":"%s","repo":%s,"lastBackup":"%s","backupSize":"%s","machine":"%s","machineSlug":"%s","config":{"files":%s,"size":"%s"},"sessions":{"files":%s,"projects":%s,"size":"%s"},"scheduler":"%s","index":{"sessions":%s}}\n' \
    "$VERSION" "$mode" "$repo" "$last_backup" "$backup_size" \
    "$(json_escape "$(hostname)")" "$(json_escape "$(get_machine_slug)")" \
    "$config_files" "$config_size" "$session_files" "$session_projects" "$session_size" \
    "$scheduler" "$index_sessions"
}

cmd_restore() {
  local mode="uuid"
  local uuid=""
  local last_n=10
  local filter_date=""
  local filter_project=""
  local force=false

  # Parse args — supports both "--last 10" (two args) and UUID with optional --force
  local args=("$@")
  local i=0
  while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
      --list)    mode="list" ;;
      --force)   force=true ;;
      --last)    mode="last";    ((i++)) || true; last_n="${args[$i]:-10}"
                 [[ "$last_n" == --* ]] && fail "Missing number after --last"
                 [[ ! "$last_n" =~ ^[0-9]+$ ]] && fail "--last requires a positive integer" ;;
      --date)    mode="date";    ((i++)) || true; filter_date="${args[$i]:-}"
                 [ -z "$filter_date" ] && fail "Missing value for --date (expected YYYY-MM-DD)"
                 [[ "$filter_date" == --* ]] && fail "Missing value for --date (expected YYYY-MM-DD)" ;;
      --project) mode="project"; ((i++)) || true; filter_project="${args[$i]:-}"
                 [ -z "$filter_project" ] && fail "Missing value for --project"
                 [[ "$filter_project" == --* ]] && fail "Missing value for --project" ;;
      *)         [ "$mode" = "uuid" ] && uuid="${args[$i]}" ;;
    esac
    ((i++)) || true
  done

  if [ ! -d "$DEST_DIR" ]; then
    fail "No backups found. Run: claude-backup sync"
  fi

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

  # ── UUID restore mode ─────────────────────────────────────────────────────────
  if [ -z "$uuid" ]; then
    printf "\n${BOLD}Usage:${NC}\n"
    printf "  claude-backup restore <uuid>                  Restore by UUID\n"
    printf "  claude-backup restore <uuid> --force          Overwrite existing\n"
    printf "  claude-backup restore --list                  List all sessions\n"
    printf "  claude-backup restore --last N                List last N sessions\n"
    printf "  claude-backup restore --date YYYY-MM-DD       Sessions from date (UTC)\n"
    printf "  claude-backup restore --project PARTIAL       Filter by project name\n\n"
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
    if [ "$JSON_OUTPUT" = true ]; then
      json_err '{"error":"Multiple matches found. Provide a more specific UUID."}'
    else
      printf "\n${YELLOW}Multiple matches found:${NC}\n"
      echo "$matches" | while read -r f; do printf "  %s\n" "$f"; done
      printf "\nProvide a more specific UUID.\n\n"
    fi
    return 1
  fi

  local gz_file="$matches"
  local filename project_dir
  filename=$(basename "$gz_file" .gz)
  project_dir=$(basename "$(dirname "$gz_file")")

  local target_dir="$SOURCE_DIR/$project_dir"
  local target_file="$target_dir/$filename"

  if [ "$JSON_OUTPUT" != true ]; then
    printf "\n${BOLD}Restoring session:${NC}\n"
    printf "  ${DIM}From:${NC} $gz_file\n"
    printf "  ${DIM}To:${NC}   $target_file\n\n"
  fi

  if [ -f "$target_file" ] && [ "$force" = false ]; then
    if [ "$JSON_OUTPUT" = true ]; then
      json_err '{"error":"File already exists. Use --force to overwrite."}'
    else
      warn "File already exists. Use --force to overwrite."
    fi
    return 1
  fi

  mkdir -p "$target_dir"
  gzip -dkc "$gz_file" > "$target_file"
  if [ "$JSON_OUTPUT" = true ]; then
    printf '{"ok":true,"restored":{"from":"%s","to":"%s"}}\n' "$(json_escape "$gz_file")" "$(json_escape "$target_file")"
  else
    info "Session restored: $target_file"
    printf "\n"
  fi
}
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
  local peek_exit=0
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
    return role, text[:80].replace("\n", " ")

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
  ) || peek_exit=$?

  if [ "$peek_exit" -ne 0 ] || [ -z "$peek_json" ]; then
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
cmd_uninstall() {
  printf "\n${BOLD}Uninstalling Claude Backup${NC}\n\n"

  # Remove launchd schedule
  if [ -f "$PLIST_PATH" ]; then
    local domain="gui/$(id -u)"
    launchctl bootout "$domain/$SERVICE_LABEL" 2>/dev/null || true
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

  if [ "$JSON_OUTPUT" != true ]; then printf "\n${BOLD}Exporting Claude Code config...${NC}\n\n"; fi

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

  if [ "$sensitive_found" = true ] && [ "$JSON_OUTPUT" != true ]; then
    printf "\n  ${YELLOW}Review the files above before sharing this export.${NC}\n"
  fi

  # Create tarball
  tar -czf "$output_file" -C "$tmp_dir" .
  local size
  size=$(du -h "$output_file" 2>/dev/null | cut -f1 | tr -d ' ')

  if [ "$JSON_OUTPUT" = true ]; then
    printf '{"ok":true,"exported":{"path":"%s","size":"%s","files":%s}}\n' "$(json_escape "$output_file")" "$(json_escape "$size")" "$exported"
  else
    printf "\n${GREEN}${BOLD}Exported${NC} to ${BOLD}${output_file}${NC} (${size})\n"
    printf "${DIM}Transfer via AirDrop, USB, or email. Import with:${NC}\n"
    printf "  claude-backup import-config ${output_file}\n\n"
  fi
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

  if [ "$JSON_OUTPUT" != true ]; then
    printf "\n${BOLD}Importing Claude Code config...${NC}\n"
    if [ "$force" = true ]; then
      printf "  ${YELLOW}Force mode: existing files will be overwritten${NC}\n"
    fi
    printf "\n"
  fi

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

  if [ "$JSON_OUTPUT" = true ]; then
    printf '{"ok":true,"imported":{"files":%s}}\n' "$imported"
  else
    printf "\n${GREEN}${BOLD}Done!${NC} Imported $imported files.\n"
    printf "${DIM}Restart Claude Code to apply settings.${NC}\n"
    printf "${DIM}Note: Plugins will be downloaded on first launch.${NC}\n\n"
  fi
}

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
  peek)          shift; cmd_peek "${1:-}" ;;
  uninstall)     cmd_uninstall ;;
  export-config) shift; cmd_export_config "${1:-}" ;;
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
