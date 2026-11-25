#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Install the portable multi-agent-delegation skill and (optionally) default global rules.

Options:
  --skill-only    Install only ~/.agents/skills/multi-agent-delegation (default)
  --with-rules    Also idempotently inject delegation rules into ~/.gemini/AGENTS.md and ~/.claude/CLAUDE.md
  --dry-run       Preview all actions without modifying any files
  -h, --help      Show this help
EOF
}

WITH_RULES="0"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill-only) WITH_RULES="0"; shift 1 ;;
    --with-rules) WITH_RULES="1"; shift 1 ;;
    --dry-run) DRY_RUN="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="${KIT_DIR}/skill/multi-agent-delegation"
SKILL_DST="${HOME}/.agents/skills/multi-agent-delegation"
AGENTS_RULE_DST="${HOME}/.gemini/AGENTS.md"
CLAUDE_RULE_DST="${HOME}/.claude/CLAUDE.md"

echo "==> Checking available agent CLIs on this machine:"
for bin in agy claude agent; do
  if command -v "$bin" >/dev/null 2>&1; then
    echo "  [OK]      $bin -> $(command -v "$bin")"
  else
    echo "  [MISSING] $bin (optional; missing workers auto-fallback to agy hydrogen)"
  fi
done
echo ""

# 1. Install Skill
echo "==> Step 1: Install Skill -> ${SKILL_DST}"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY-RUN] mkdir -p \"${HOME}/.agents/skills\""
  echo "  [DRY-RUN] copy \"${SKILL_SRC}\" -> \"${SKILL_DST}\""
  echo "  [DRY-RUN] chmod +x \"${SKILL_DST}/scripts/run_delegate.sh\""
else
  mkdir -p "${HOME}/.agents/skills"
  rm -rf "${SKILL_DST}"
  cp -R "${SKILL_SRC}" "${SKILL_DST}"
  chmod +x "${SKILL_DST}/scripts/run_delegate.sh"
  bash -n "${SKILL_DST}/scripts/run_delegate.sh"
  echo "  [DONE] Skill installed and script syntax verified."
fi

# 2. Optional idempotent rule injection
inject_block() {
  local target_file="$1"
  local snippet_file="$2"
  local begin_marker="<!-- BEGIN multi-agent-delegation -->"
  local end_marker="<!-- END multi-agent-delegation -->"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [DRY-RUN] idempotently upsert ${snippet_file} into ${target_file}"
    return 0
  fi

  mkdir -p "$(dirname "$target_file")"
  if [[ -f "$target_file" ]]; then
    local ts
    ts="$(date +%Y%m%d%H%M%S)"
    cp "$target_file" "${target_file}.bak.${ts}"
    echo "  [BACKUP] ${target_file}.bak.${ts}"
  else
    touch "$target_file"
  fi

  python3 - "$target_file" "$snippet_file" "$begin_marker" "$end_marker" <<'PY'
import re, sys

target_path, snippet_path, begin_m, end_m = sys.argv[1:5]
content = open(target_path, encoding="utf-8").read()
snippet = open(snippet_path, encoding="utf-8").read().strip()
block = f"{begin_m}\n{snippet}\n{end_m}\n"

pattern = re.compile(re.escape(begin_m) + r".*?" + re.escape(end_m) + r"\n?", re.S)
if pattern.search(content):
    new_content = pattern.sub(block, content, count=1)
else:
    sep = "" if (not content or content.endswith("\n\n")) else ("\n" if content.endswith("\n") else "\n\n")
    new_content = content + sep + block

with open(target_path, "w", encoding="utf-8") as f:
    f.write(new_content)
PY
  echo "  [DONE] Updated ${target_file}"
}

if [[ "$WITH_RULES" == "1" ]]; then
  echo ""
  echo "==> Step 2: Inject default delegation rules (idempotent)"
  inject_block "$AGENTS_RULE_DST" "${KIT_DIR}/rules/AGENTS-snippet.md"
  inject_block "$CLAUDE_RULE_DST" "${KIT_DIR}/rules/CLAUDE-snippet.md"
else
  echo ""
  echo "==> Step 2: Skipped global rule injection (run with --with-rules to enable auto-trigger by default)"
fi

echo ""
echo "==> Done! Start a new AGY session to use 'multi-agent-delegation'."
