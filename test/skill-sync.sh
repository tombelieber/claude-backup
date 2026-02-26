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
  if ! grep -qF -- "$pattern" "$file"; then
    echo "MISSING in $file: $pattern ($label)"
    ((ERRORS++)) || true
  fi
}

# Subcommands (from case statement in cli.sh)
for cmd in sync status restore peek export-config import-config; do
  check "subcommand" "$cmd" "$SKILL"
done

# Flags (from arg parsers in cli.sh)
for flag in --json --config-only --list --last --date --project --force; do
  check "flag" "$flag" "$SKILL"
done

# Version triple check: cli.sh, package.json, plugin.json must match
CLI_VER=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$CLI")
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
