#!/usr/bin/env bash
set -euo pipefail

# Layered config resolver, profile switcher & initializer for multi-agent-delegation.
# Priority: CLI flags > Project (.agents/delegation/config.env) > User (~/.config/multi-agent-delegation/config.env) > Defaults.

usage() {
  cat <<'EOF'
Usage: load_config.sh [options]

Inspect layered configuration & local core MD files, switch subscription profiles,
or initialize user/project config templates.

Options:
  --dir <path>          Target workspace directory for project-level lookup (default: .)
  --show                Print human-readable merged configuration and discovered MD files (default)
  --json                Print merged configuration and discovered MD files as JSON
  --export-env          Print safe shell variable assignments for sourcing by run_delegate.sh
  --list-profiles       List built-in subscription profiles
  --use-profile <name>  Write a built-in profile to ~/.config/multi-agent-delegation/config.env (non-destructive unless --force)
  --init-user           Create ~/.config/multi-agent-delegation/{config.env,overrides.md} if missing
  --init-project [dir]  Create <dir>/.agents/delegation/{config.env,overrides.md} if missing (default: --dir or .)
  --force               Overwrite existing config files when used with --init-user / --init-project / --use-profile
  -h, --help            Show this help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATES_DIR="${SKILL_DIR}/templates"
PROFILES_DIR="${SKILL_DIR}/profiles"
USER_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/multi-agent-delegation"

MODE="show"
TARGET_DIR="."
INIT_PROJECT_DIR=""
PROFILE_NAME=""
FORCE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --show) MODE="show"; shift 1 ;;
    --json) MODE="json"; shift 1 ;;
    --export-env) MODE="export-env"; shift 1 ;;
    --list-profiles) MODE="list-profiles"; shift 1 ;;
    --use-profile) MODE="use-profile"; PROFILE_NAME="$2"; shift 2 ;;
    --init-user) MODE="init-user"; shift 1 ;;
    --init-project)
      MODE="init-project"
      if [[ $# -ge 2 && "$2" != --* ]]; then
        INIT_PROJECT_DIR="$2"
        shift 2
      else
        shift 1
      fi
      ;;
    --force) FORCE="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

copy_template() {
  local src="$1"
  local dst="$2"
  if [[ -f "$dst" && "$FORCE" != "1" ]]; then
    echo "  [KEEP]   ${dst} (already exists; pass --force to overwrite)"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "  [CREATE] ${dst}"
}

if [[ "$MODE" == "list-profiles" ]]; then
  echo "Available built-in subscription profiles (${PROFILES_DIR}):"
  for f in "${PROFILES_DIR}"/*.env; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .env)"
    summary="$(grep -m1 '^# Summary:' "$f" | sed 's/^# Summary:[[:space:]]*//' || true)"
    printf "  %-22s %s\n" "$name" "$summary"
  done
  exit 0
fi

if [[ "$MODE" == "use-profile" ]]; then
  profile_file="${PROFILES_DIR}/${PROFILE_NAME}.env"
  if [[ ! -f "$profile_file" ]]; then
    echo "Error: unknown profile '${PROFILE_NAME}'. Run --list-profiles to see available profiles." >&2
    exit 1
  fi
  echo "==> Applying profile '${PROFILE_NAME}' -> ${USER_CFG_DIR}"
  copy_template "$profile_file" "${USER_CFG_DIR}/config.env"
  copy_template "${TEMPLATES_DIR}/user-overrides.md.example" "${USER_CFG_DIR}/overrides.md"
  exit 0
fi

if [[ "$MODE" == "init-user" ]]; then
  echo "==> Initializing user-level config in ${USER_CFG_DIR}"
  copy_template "${TEMPLATES_DIR}/user-config.env.example" "${USER_CFG_DIR}/config.env"
  copy_template "${TEMPLATES_DIR}/user-overrides.md.example" "${USER_CFG_DIR}/overrides.md"
  exit 0
fi

if [[ "$MODE" == "init-project" ]]; then
  local_proj="${INIT_PROJECT_DIR:-$TARGET_DIR}"
  if [[ ! -d "$local_proj" ]]; then
    echo "Error: directory does not exist: ${local_proj}" >&2
    exit 1
  fi
  abs_proj="$(cd "$local_proj" && pwd)"
  proj_cfg_dir="${abs_proj}/.agents/delegation"
  echo "==> Initializing project-level config in ${proj_cfg_dir}"
  copy_template "${TEMPLATES_DIR}/project-config.env.example" "${proj_cfg_dir}/config.env"
  copy_template "${TEMPLATES_DIR}/project-overrides.md.example" "${proj_cfg_dir}/overrides.md"
  exit 0
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: directory does not exist: ${TARGET_DIR}" >&2
  exit 1
fi
ABS_TARGET="$(cd "$TARGET_DIR" && pwd)"

python3 - "$MODE" "$ABS_TARGET" "$USER_CFG_DIR" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

mode, target_dir_str, user_cfg_dir_str = sys.argv[1:4]
home = Path.home().resolve()
target_dir = Path(target_dir_str).resolve()
user_cfg_dir = Path(user_cfg_dir_str).expanduser()

ROLE_KEYS = [
    "DELEGATE_ROLE_SCOUT",
    "DELEGATE_ROLE_FAST",
    "DELEGATE_ROLE_CODER",
    "DELEGATE_ROLE_HEAVY",
    "DELEGATE_ROLE_ARCHITECT",
]

ENDPOINT_KEYS = [
    "DELEGATE_ROLE_SCOUT_BASE_URL",
    "DELEGATE_ROLE_SCOUT_API_KEY_ENV",
    "DELEGATE_ROLE_FAST_BASE_URL",
    "DELEGATE_ROLE_FAST_API_KEY_ENV",
    "DELEGATE_ROLE_CODER_BASE_URL",
    "DELEGATE_ROLE_CODER_API_KEY_ENV",
    "DELEGATE_ROLE_HEAVY_BASE_URL",
    "DELEGATE_ROLE_HEAVY_API_KEY_ENV",
    "DELEGATE_ROLE_ARCHITECT_BASE_URL",
    "DELEGATE_ROLE_ARCHITECT_API_KEY_ENV",
]

DEFAULTS = {
    # 5 Universal Role Bindings (harness:model)
    "DELEGATE_ROLE_SCOUT": "agy:gemini-4-hydrogen-low",
    "DELEGATE_ROLE_FAST": "agy:gemini-4-hydrogen-medium",
    "DELEGATE_ROLE_CODER": "claude:sonnet",
    "DELEGATE_ROLE_HEAVY": "agy:claude-sonnet-5-5-medium",
    "DELEGATE_ROLE_ARCHITECT": "agy:claude-opus-5-5-medium",
    # Per-role optional Claude Anthropic-compatible endpoints
    "DELEGATE_ROLE_SCOUT_BASE_URL": "",
    "DELEGATE_ROLE_SCOUT_API_KEY_ENV": "",
    "DELEGATE_ROLE_FAST_BASE_URL": "",
    "DELEGATE_ROLE_FAST_API_KEY_ENV": "",
    "DELEGATE_ROLE_CODER_BASE_URL": "",
    "DELEGATE_ROLE_CODER_API_KEY_ENV": "",
    "DELEGATE_ROLE_HEAVY_BASE_URL": "",
    "DELEGATE_ROLE_HEAVY_API_KEY_ENV": "",
    "DELEGATE_ROLE_ARCHITECT_BASE_URL": "",
    "DELEGATE_ROLE_ARCHITECT_API_KEY_ENV": "",
    # Execution & fallback defaults
    "DELEGATE_DEFAULT_FALLBACK": "fast",
    "DELEGATE_DEFAULT_TEST_CMD": "python3",
    "DELEGATE_DEFAULT_EFFORT": "high",
    "DELEGATE_DEFAULT_MAX_BUDGET": "1.00",
    "DELEGATE_DEFAULT_TIMEOUT": "300s",
    "DELEGATE_SCRATCH_DIR": str(home / "work" / "agy-scratch"),
    "DELEGATE_DISABLED_HARNESSES": "",
    "DELEGATE_DISABLED_PRESETS": "",
    # Legacy preset model overrides (for --preset backward compatibility)
    "DELEGATE_MODEL_HYDROGEN_LOW": "gemini-4-hydrogen-low",
    "DELEGATE_MODEL_HYDROGEN": "gemini-4-hydrogen-medium",
    "DELEGATE_MODEL_GLM": "sonnet",
    "DELEGATE_MODEL_GLM_OPUS": "opus",
    "DELEGATE_MODEL_SONNET_AGY": "claude-sonnet-5-5-medium",
    "DELEGATE_MODEL_SONNET_CURSOR": "claude-sonnet-5-5-medium",
    "DELEGATE_MODEL_OPUS_PLAN": "claude-opus-5-5-medium",
}

KEY_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")

def safe_is_file(path: Path) -> bool:
    try:
        return path.is_file()
    except PermissionError:
        return False

def find_project_root(start: Path) -> Path:
    cur = start
    while True:
        try:
            if (cur / ".agents" / "delegation").is_dir() or (cur / ".git").exists():
                return cur
        except PermissionError:
            return start
        if cur == home or cur.parent == cur:
            return start
        cur = cur.parent

def parse_env_file(path: Path) -> dict:
    parsed = {}
    if not safe_is_file(path):
        return parsed
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        m = KEY_RE.match(line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if key not in DEFAULTS:
            continue
        if len(val) >= 2 and ((val[0] == val[-1] == '"') or (val[0] == val[-1] == "'")):
            val = val[1:-1]
        val = val.replace("$HOME", str(home)).replace("${HOME}", str(home))
        if val.startswith("~/"):
            val = str(home / val[2:])
        parsed[key] = val
    return parsed

project_root = find_project_root(target_dir)
user_env_path = user_cfg_dir / "config.env"
project_env_path = project_root / ".agents" / "delegation" / "config.env"

values = dict(DEFAULTS)
sources = {k: "default" for k in DEFAULTS}

for k, v in parse_env_file(user_env_path).items():
    values[k] = v
    sources[k] = "user"

for k, v in parse_env_file(project_env_path).items():
    values[k] = v
    sources[k] = "project"

md_candidates = [
    ("project_overrides", project_root / ".agents" / "delegation" / "overrides.md"),
    ("project_agents_md", project_root / "AGENTS.md"),
    ("project_claude_md", project_root / "CLAUDE.md"),
    ("user_overrides", user_cfg_dir / "overrides.md"),
    ("user_agents_md", home / ".gemini" / "AGENTS.md"),
    ("user_claude_md", home / ".claude" / "CLAUDE.md"),
]

discovered_md = [
    {"scope": scope, "path": str(p), "exists": safe_is_file(p)}
    for scope, p in md_candidates
]

if mode == "export-env":
    for k, v in values.items():
        print(f"{k}={shlex.quote(v)}")
    print(f"DELEGATE_PROJECT_ROOT={shlex.quote(str(project_root))}")
    print(f"DELEGATE_USER_CONFIG_PATH={shlex.quote(str(user_env_path))}")
    print(f"DELEGATE_PROJECT_CONFIG_PATH={shlex.quote(str(project_env_path))}")
    sys.exit(0)

payload = {
    "project_root": str(project_root),
    "config_files": {
        "user": {"path": str(user_env_path), "exists": safe_is_file(user_env_path)},
        "project": {"path": str(project_env_path), "exists": safe_is_file(project_env_path)},
    },
    "values": values,
    "sources": sources,
    "markdown_files": discovered_md,
}

if mode == "json":
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    sys.exit(0)

print(f"Project root:   {project_root}")
print(f"User config:    {user_env_path} ({'loaded' if safe_is_file(user_env_path) else 'not found'})")
print(f"Project config: {project_env_path} ({'loaded' if safe_is_file(project_env_path) else 'not found'})")
print("")
print("Universal Role Bindings (CLI > project > user > default):")
for k in ROLE_KEYS:
    role_name = k.replace("DELEGATE_ROLE_", "").lower()
    base_url = values[f"{k}_BASE_URL"]
    key_env = values[f"{k}_API_KEY_ENV"]
    extra = ""
    if base_url or key_env:
        extra = f" (endpoint={base_url or 'default'}, key_env={key_env or 'default'})"
    print(f"  {role_name:10} -> {values[k]!r:32} [{sources[k]}]{extra}")
print("")
print("Execution & Fallback Defaults:")
for k in [
    "DELEGATE_DEFAULT_FALLBACK",
    "DELEGATE_DEFAULT_TEST_CMD",
    "DELEGATE_DEFAULT_EFFORT",
    "DELEGATE_DEFAULT_MAX_BUDGET",
    "DELEGATE_DEFAULT_TIMEOUT",
    "DELEGATE_SCRATCH_DIR",
    "DELEGATE_DISABLED_HARNESSES",
    "DELEGATE_DISABLED_PRESETS",
]:
    print(f"  {k}={values[k]!r}  [{sources[k]}]")
print("")
print("Discovered core & override Markdown files (high -> low priority):")
for item in discovered_md:
    flag = "EXISTS" if item["exists"] else "absent"
    print(f"  [{flag:6}] {item['scope']:18} {item['path']}")
PY
