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
