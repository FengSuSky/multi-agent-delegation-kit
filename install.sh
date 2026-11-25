#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Install or upgrade the portable multi-agent-delegation skill while preserving user-level configuration.

Options:
  --skill-only          Install/upgrade ~/.agents/skills/multi-agent-delegation and init user config if missing (default)
  --with-rules          Also idempotently inject delegation rules into ~/.gemini/AGENTS.md and ~/.claude/CLAUDE.md
  --profile <name>      Initialize user config from a built-in profile (agy-cursor-zhipu | claude-deepseek-glm | agy-only)
  --init-project <dir>  Also scaffold <dir>/.agents/delegation/{config.env,overrides.md} if missing
  --dry-run             Preview all actions without modifying any files
  -h, --help            Show this help
EOF
}

WITH_RULES="0"
DRY_RUN="0"
PROFILE_NAME=""
INIT_PROJECT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill-only) WITH_RULES="0"; shift 1 ;;
    --with-rules) WITH_RULES="1"; shift 1 ;;
    --profile) PROFILE_NAME="$2"; shift 2 ;;
    --init-project) INIT_PROJECT_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="${KIT_DIR}/skill/multi-agent-delegation"
SKILL_DST="${HOME}/.agents/skills/multi-agent-delegation"
USER_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/multi-agent-delegation"
AGENTS_RULE_DST="${HOME}/.gemini/AGENTS.md"
CLAUDE_RULE_DST="${HOME}/.claude/CLAUDE.md"

if [[ -n "$PROFILE_NAME" && ! -f "${SKILL_SRC}/profiles/${PROFILE_NAME}.env" ]]; then
  echo "Error: unknown profile '${PROFILE_NAME}'. Available profiles:" >&2
  ls -1 "${SKILL_SRC}/profiles"/*.env | xargs -n1 basename | sed 's/\.env$//' | sed 's/^/  - /' >&2
  exit 1
fi

echo "==> Checking available agent CLIs on this machine:"
for bin in agy claude agent; do
  if command -v "$bin" >/dev/null 2>&1; then
    echo "  [OK]      $bin -> $(command -v "$bin")"
  else
    echo "  [MISSING] $bin (optional; configure your profile or DELEGATE_DISABLED_HARNESSES)"
  fi
done
echo ""

# 1. Install / Upgrade Skill
echo "==> Step 1: Install/Upgrade Skill -> ${SKILL_DST}"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY-RUN] mkdir -p \"${HOME}/.agents/skills\""
  echo "  [DRY-RUN] sync \"${SKILL_SRC}\" -> \"${SKILL_DST}\""
  echo "  [DRY-RUN] chmod +x \"${SKILL_DST}/scripts/run_delegate.sh\" \"${SKILL_DST}/scripts/load_config.sh\""
else
  mkdir -p "${HOME}/.agents/skills"
  rm -rf "${SKILL_DST}"
  cp -R "${SKILL_SRC}" "${SKILL_DST}"
  chmod +x "${SKILL_DST}/scripts/run_delegate.sh" "${SKILL_DST}/scripts/load_config.sh"
  bash -n "${SKILL_DST}/scripts/run_delegate.sh"
  bash -n "${SKILL_DST}/scripts/load_config.sh"
  echo "  [DONE] Skill installed and scripts syntax-verified."
fi

# 2. Preserve or initialize user-level configuration (never overwrite!)
echo ""
echo "==> Step 2: Ensure user-level config -> ${USER_CFG_DIR} (preserved across upgrades)"
if [[ "$DRY_RUN" == "1" ]]; then
  if [[ -f "${USER_CFG_DIR}/config.env" ]]; then
    echo "  [DRY-RUN] KEEP existing ${USER_CFG_DIR}/config.env"
  elif [[ -n "$PROFILE_NAME" ]]; then
    echo "  [DRY-RUN] CREATE ${USER_CFG_DIR}/config.env from profile '${PROFILE_NAME}'"
  else
    echo "  [DRY-RUN] CREATE ${USER_CFG_DIR}/config.env from default template"
  fi
  if [[ -f "${USER_CFG_DIR}/overrides.md" ]]; then
    echo "  [DRY-RUN] KEEP existing ${USER_CFG_DIR}/overrides.md"
  else
    echo "  [DRY-RUN] CREATE ${USER_CFG_DIR}/overrides.md from template"
  fi
else
  if [[ -n "$PROFILE_NAME" ]]; then
    bash "${SKILL_DST}/scripts/load_config.sh" --use-profile "$PROFILE_NAME"
  else
    bash "${SKILL_DST}/scripts/load_config.sh" --init-user
  fi
fi

# 3. Optional project-level config initialization
if [[ -n "$INIT_PROJECT_DIR" ]]; then
  echo ""
  echo "==> Step 3: Ensure project-level config -> ${INIT_PROJECT_DIR}/.agents/delegation"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [DRY-RUN] init project config templates in ${INIT_PROJECT_DIR}/.agents/delegation (non-destructive)"
  else
    bash "${SKILL_DST}/scripts/load_config.sh" --init-project "$INIT_PROJECT_DIR"
  fi
fi

# 4. Optional idempotent rule injection
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

echo ""
if [[ "$WITH_RULES" == "1" ]]; then
  echo "==> Step 4: Inject default delegation rules (idempotent)"
  inject_block "$AGENTS_RULE_DST" "${KIT_DIR}/rules/AGENTS-snippet.md"
  inject_block "$CLAUDE_RULE_DST" "${KIT_DIR}/rules/CLAUDE-snippet.md"
else
  echo "==> Step 4: Skipped global rule injection (run with --with-rules to enable auto-trigger by default)"
fi

echo ""
echo "==> Done!"
echo "  - List subscription profiles: bash ${SKILL_DST}/scripts/load_config.sh --list-profiles"
echo "  - Switch profile anytime:     bash ${SKILL_DST}/scripts/load_config.sh --use-profile <name> --force"
echo "  - Inspect effective config:   bash ${SKILL_DST}/scripts/load_config.sh --show"
echo "  - Init project overrides:     bash ${SKILL_DST}/scripts/load_config.sh --init-project <project_dir>"
