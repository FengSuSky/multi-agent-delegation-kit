#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run_delegate.sh (--role <role> | --preset <preset>) --dir <workdir> --brief <file> --out <out.json> [options]

Universal Roles (recommended, vendor-agnostic, customizable via config.env / profiles):
  scout          Fast search, summary, full test/eval monitoring, log analysis
  fast           Small chores, unit tests, small-to-medium deterministic edits
  coder          Standard / multi-file implementation & test-verified bug fixes
  heavy          Escalation after 2-3 failed self-fix loops
  architect      High-risk architecture & trade-offs (read-only plan mode)

Legacy Presets (backward compatible):
  hydrogen-low   AGY gemini-4-hydrogen-low
  hydrogen       AGY gemini-4-hydrogen-medium
  glm            Claude Code sonnet (e.g. Zhipu GLM-5.3-Flash)
  glm-opus       Claude Code opus (e.g. Zhipu GLM-5.4)
  sonnet-agy     AGY claude-sonnet-5-5-medium
  sonnet-cursor  Cursor claude-sonnet-5-5-medium
  opus-plan      AGY claude-opus-5-5-medium --mode plan

Options:
  --test-cmd <cmd>       Allowed test command prefix for Claude Code (default: from config or python3)
  --effort <level>       Claude Code reasoning effort: low|medium|high|xhigh|max (default: from config or high)
  --max-budget <usd>     Claude Code max budget in USD (default: from config or 1.00)
  --timeout <dur>        AGY print timeout (default: from config or 300s)
  --resume <session_id>  Resume an existing session/conversation ID to reuse context & cache
  --keep-session         Keep Claude Code session on disk so follow-up turns can use --resume
  --fallback <target>    Auto-fallback role or preset on error/quota/disabled (default: from config or fast; 'none' to disable)
  --show-config          Print effective merged config (project > user > defaults) for --dir (default: .) and exit
  --resolve-only         Resolve target (--role/--preset) to harness/model/endpoint as JSON without executing
  -h, --help             Show this help

Configuration layering (high -> low priority):
  1. CLI flags
  2. Project config: <project_root>/.agents/delegation/config.env
  3. User config:    ~/.config/multi-agent-delegation/config.env
  4. Built-in defaults
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_CONFIG="${SCRIPT_DIR}/load_config.sh"

ROLE=""
PRESET=""
WORKDIR=""
BRIEF_FILE=""
OUT_FILE=""
CLI_TEST_CMD=""
CLI_EFFORT=""
CLI_MAX_BUDGET=""
CLI_TIMEOUT=""
RESUME_ID=""
KEEP_SESSION="0"
CLI_FALLBACK=""
SHOW_CONFIG="0"
RESOLVE_ONLY="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --preset) PRESET="$2"; shift 2 ;;
    --dir) WORKDIR="$2"; shift 2 ;;
    --brief) BRIEF_FILE="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --test-cmd) CLI_TEST_CMD="$2"; shift 2 ;;
    --effort) CLI_EFFORT="$2"; shift 2 ;;
    --max-budget) CLI_MAX_BUDGET="$2"; shift 2 ;;
    --timeout) CLI_TIMEOUT="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; KEEP_SESSION="1"; shift 2 ;;
    --keep-session) KEEP_SESSION="1"; shift 1 ;;
    --fallback) CLI_FALLBACK="$2"; shift 2 ;;
    --show-config) SHOW_CONFIG="1"; shift 1 ;;
    --resolve-only) RESOLVE_ONLY="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$SHOW_CONFIG" == "1" ]]; then
  exec bash "$LOAD_CONFIG" --show --dir "${WORKDIR:-.}"
fi

TARGET="${ROLE:-$PRESET}"
if [[ -z "$TARGET" ]]; then
  echo "Error: either --role <role> or --preset <preset> is required." >&2
  usage >&2
  exit 2
fi

if [[ "$RESOLVE_ONLY" == "1" ]]; then
  WORKDIR="${WORKDIR:-.}"
else
  if [[ -z "$WORKDIR" || -z "$BRIEF_FILE" || -z "$OUT_FILE" ]]; then
    echo "Error: --dir, --brief, and --out are required." >&2
    usage >&2
    exit 2
  fi
fi

if [[ ! -d "$WORKDIR" ]]; then
  echo "Error: workdir does not exist: $WORKDIR" >&2
  exit 1
fi
ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"

if [[ "$RESOLVE_ONLY" != "1" ]]; then
  if [[ ! -f "$BRIEF_FILE" ]]; then
    echo "Error: brief file does not exist: $BRIEF_FILE" >&2
    exit 1
  fi
  ABS_BRIEF="$(cd "$(dirname "$BRIEF_FILE")" && pwd)/$(basename "$BRIEF_FILE")"
  mkdir -p "$(dirname "$OUT_FILE")"
  ABS_OUT="$(cd "$(dirname "$OUT_FILE")" && pwd)/$(basename "$OUT_FILE")"
fi

# Load layered defaults (project > user > built-in) safely without executing arbitrary shell code
if [[ -f "$LOAD_CONFIG" ]]; then
  eval "$(bash "$LOAD_CONFIG" --export-env --dir "$ABS_WORKDIR")"
fi

TEST_CMD="${CLI_TEST_CMD:-${DELEGATE_DEFAULT_TEST_CMD:-python3}}"
EFFORT="${CLI_EFFORT:-${DELEGATE_DEFAULT_EFFORT:-high}}"
MAX_BUDGET="${CLI_MAX_BUDGET:-${DELEGATE_DEFAULT_MAX_BUDGET:-1.00}}"
TIMEOUT="${CLI_TIMEOUT:-${DELEGATE_DEFAULT_TIMEOUT:-300s}}"
FALLBACK="${CLI_FALLBACK:-${DELEGATE_DEFAULT_FALLBACK:-fast}}"
DISABLED_HARNESSES="${DELEGATE_DISABLED_HARNESSES:-}"
DISABLED_PRESETS="${DELEGATE_DISABLED_PRESETS:-}"

MODEL_HYDROGEN_LOW="${DELEGATE_MODEL_HYDROGEN_LOW:-gemini-4-hydrogen-low}"
MODEL_HYDROGEN="${DELEGATE_MODEL_HYDROGEN:-gemini-4-hydrogen-medium}"
MODEL_GLM="${DELEGATE_MODEL_GLM:-sonnet}"
MODEL_GLM_OPUS="${DELEGATE_MODEL_GLM_OPUS:-opus}"
MODEL_SONNET_AGY="${DELEGATE_MODEL_SONNET_AGY:-claude-sonnet-5-5-medium}"
MODEL_SONNET_CURSOR="${DELEGATE_MODEL_SONNET_CURSOR:-claude-sonnet-5-5-medium}"
MODEL_OPUS_PLAN="${DELEGATE_MODEL_OPUS_PLAN:-claude-opus-5-5-medium}"

in_csv() {
  local needle="$1"
  local haystack="$2"
  [[ -z "$haystack" ]] && return 1
  local IFS=','
  local item
  for item in $haystack; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

# Resolve a role or legacy preset into:
# RES_HARNESS, RES_MODEL, RES_MODE (default|plan), RES_BASE_URL, RES_API_KEY_ENV
resolve_target() {
  local t="$1"
  RES_HARNESS=""
  RES_MODEL=""
  RES_MODE="default"
  RES_BASE_URL=""
  RES_API_KEY_ENV=""

  case "$t" in
    scout|fast|coder|heavy|architect)
      local upper
      upper="$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')"
      local spec_var="DELEGATE_ROLE_${upper}"
      local url_var="DELEGATE_ROLE_${upper}_BASE_URL"
      local key_var="DELEGATE_ROLE_${upper}_API_KEY_ENV"
      local spec="${!spec_var:-}"
      if [[ "$spec" != *:* ]]; then
        echo "Error: invalid role binding ${spec_var}='${spec}' (expected '<harness>:<model>')." >&2
        return 2
      fi
      RES_HARNESS="${spec%%:*}"
      RES_MODEL="${spec#*:}"
      RES_BASE_URL="${!url_var:-}"
      RES_API_KEY_ENV="${!key_var:-}"
      if [[ "$t" == "architect" ]]; then
        RES_MODE="plan"
      fi
      ;;
    hydrogen-low)
      RES_HARNESS="agy"; RES_MODEL="$MODEL_HYDROGEN_LOW"
      ;;
    hydrogen)
      RES_HARNESS="agy"; RES_MODEL="$MODEL_HYDROGEN"
      ;;
    glm)
      RES_HARNESS="claude"; RES_MODEL="$MODEL_GLM"
      ;;
    glm-opus)
      RES_HARNESS="claude"; RES_MODEL="$MODEL_GLM_OPUS"
      ;;
    sonnet-agy)
      RES_HARNESS="agy"; RES_MODEL="$MODEL_SONNET_AGY"
      ;;
    sonnet-cursor)
      RES_HARNESS="cursor"; RES_MODEL="$MODEL_SONNET_CURSOR"
      ;;
    opus-plan)
      RES_HARNESS="agy"; RES_MODEL="$MODEL_OPUS_PLAN"; RES_MODE="plan"
      ;;
    *)
      echo "Error: unknown role/preset '$t'" >&2
      usage >&2
      return 2
      ;;
  esac
}

is_target_disabled() {
  local t="$1"
  local h="$2"
  in_csv "$t" "$DISABLED_PRESETS" || in_csv "$h" "$DISABLED_HARNESSES"
}

resolve_target "$TARGET"

ROUTED_FROM=""
if is_target_disabled "$TARGET" "$RES_HARNESS"; then
  if [[ "$FALLBACK" != "none" && "$FALLBACK" != "$TARGET" ]]; then
    local_orig="$TARGET"
    local_orig_h="$RES_HARNESS"
    resolve_target "$FALLBACK"
    if ! is_target_disabled "$FALLBACK" "$RES_HARNESS"; then
      echo "[CONFIG] Target '${local_orig}' (harness=${local_orig_h}) is disabled; routing directly to '${FALLBACK}' (${RES_HARNESS}:${RES_MODEL})." >&2
      ROUTED_FROM="$local_orig"
      TARGET="$FALLBACK"
      RESUME_ID=""
    else
      echo "Error: target '${local_orig}' and fallback '${FALLBACK}' are both disabled." >&2
      exit 1
    fi
  else
    echo "Error: target '${TARGET}' (harness=${RES_HARNESS}) is disabled and no active fallback is available." >&2
    exit 1
  fi
fi

if [[ "$RESOLVE_ONLY" == "1" ]]; then
  python3 - "$TARGET" "$ROUTED_FROM" "$RES_HARNESS" "$RES_MODEL" "$RES_MODE" "$RES_BASE_URL" "$RES_API_KEY_ENV" "$FALLBACK" "$TEST_CMD" "$EFFORT" "$MAX_BUDGET" "$TIMEOUT" <<'PY'
import json, sys
keys = [
    "target", "routed_from", "harness", "model", "mode",
    "base_url", "api_key_env", "fallback", "test_cmd", "effort", "max_budget", "timeout",
]
print(json.dumps(dict(zip(keys, sys.argv[1:])), ensure_ascii=False, indent=2))
PY
  exit 0
fi

check_agy_dir() {
  if [[ "$ABS_WORKDIR" != "$HOME"* ]]; then
    echo "Error: AGY requires --dir to be under \$HOME ($HOME), got: $ABS_WORKDIR" >&2
    exit 1
  fi
}

BRIEF_CONTENT="$(cat "$ABS_BRIEF")"

run_resolved() {
  local harness="$1"
  local model="$2"
  local mode="$3"
  local base_url="$4"
  local api_key_env="$5"
  local resume_id="$6"
  local out_path="$7"
  local err_log="$8"

  cd "$ABS_WORKDIR"

  case "$harness" in
    agy)
      check_agy_dir
      local args=(--model "$model" --output-format json --print-timeout "$TIMEOUT")
      [[ "$mode" == "plan" ]] && args+=(--mode plan)
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      /usr/bin/time -p agy "${args[@]}" -p "$BRIEF_CONTENT" > "$out_path" 2> "$err_log"
      ;;
    claude)
      local perm_mode="acceptEdits"
      local allowed_tools="Read,Edit,Write,Bash(${TEST_CMD}:*)"
      if [[ "$mode" == "plan" ]]; then
        perm_mode="plan"
        allowed_tools="Read,Glob,Grep"
      fi
      local args=(
        -p --model "$model"
        --effort "$EFFORT"
        --max-budget-usd "$MAX_BUDGET"
        --exclude-dynamic-system-prompt-sections
        --permission-mode "$perm_mode"
        --permission-prompts none
        --output-format json
      )
      [[ "$KEEP_SESSION" == "0" ]] && args+=(--no-session-persistence)
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")

      local env_prefix=()
      if [[ -n "$base_url" ]]; then
        env_prefix+=("ANTHROPIC_BASE_URL=${base_url}")
      fi
      if [[ -n "$api_key_env" ]]; then
        local token_val="${!api_key_env:-}"
        if [[ -z "$token_val" ]]; then
          echo "Error: role requires env var '${api_key_env}' to be set for Claude endpoint." >&2
          return 1
        fi
        env_prefix+=("ANTHROPIC_AUTH_TOKEN=${token_val}")
      fi

      # Feed brief via stdin so variadic --allowedTools never consumes the prompt argument
      if [[ ${#env_prefix[@]} -gt 0 ]]; then
        /usr/bin/time -p env "${env_prefix[@]}" claude "${args[@]}" --allowedTools "$allowed_tools" < "$ABS_BRIEF" > "$out_path" 2> "$err_log"
      else
        /usr/bin/time -p claude "${args[@]}" --allowedTools "$allowed_tools" < "$ABS_BRIEF" > "$out_path" 2> "$err_log"
      fi
      ;;
    cursor)
      local args=(-p --trust --model "$model" --output-format json)
      [[ "$mode" == "plan" ]] && args+=(--mode plan)
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      /usr/bin/time -p agent "${args[@]}" "$BRIEF_CONTENT" > "$out_path" 2> "$err_log"
      ;;
    *)
      echo "Error: unsupported harness '${harness}' (supported: agy, claude, cursor)." >&2
      return 2
      ;;
  esac
}

needs_fallback() {
  local rc="$1"
  local out_path="$2"
  local err_log="$3"

  if [[ "$rc" -ne 0 ]]; then
    return 0
  fi
  if [[ ! -s "$out_path" ]]; then
    return 0
  fi
  python3 - "$out_path" "$err_log" <<'PY'
import json, re, sys

out_path, err_path = sys.argv[1], sys.argv[2]
quota_pat = re.compile(
    r"(quota|rate.?limit|insufficient|balance|credit|429|402|overloaded|exhausted|usage.?limit|billing|unauthorized)",
    re.I,
)
try:
    raw = open(out_path, encoding="utf-8", errors="ignore").read().strip()
    data = json.loads(raw) if raw else {}
except Exception:
    sys.exit(0)

is_err = bool(data.get("is_error")) or str(data.get("status", "")).upper() in {"ERROR", "FAILED"}
text = " ".join(
    str(data.get(k, "")) for k in ("error", "result", "response", "subtype", "api_error_status")
)
err_txt = open(err_path, encoding="utf-8", errors="ignore").read() if err_path else ""

if is_err or (quota_pat.search(text) and len(text) < 600) or quota_pat.search(err_txt):
    sys.exit(0)
sys.exit(1)
PY
}

ERR_LOG="${ABS_OUT}.stderr"
set +e
run_resolved "$RES_HARNESS" "$RES_MODEL" "$RES_MODE" "$RES_BASE_URL" "$RES_API_KEY_ENV" "$RESUME_ID" "$ABS_OUT" "$ERR_LOG"
RC=$?
set -e

cat "$ERR_LOG" >&2 || true

if [[ "$FALLBACK" != "none" && "$TARGET" != "$FALLBACK" ]]; then
  if needs_fallback "$RC" "$ABS_OUT" "$ERR_LOG"; then
    ORIG_HARNESS="$RES_HARNESS"
    ORIG_MODEL="$RES_MODEL"
    resolve_target "$FALLBACK"
    if ! is_target_disabled "$FALLBACK" "$RES_HARNESS" && [[ "${RES_HARNESS}:${RES_MODEL}" != "${ORIG_HARNESS}:${ORIG_MODEL}" ]]; then
      FAILED_OUT="${ABS_OUT%.json}.failed-${TARGET}.json"
      cp "$ABS_OUT" "$FAILED_OUT" 2>/dev/null || true
      echo "[FALLBACK] Target '${TARGET}' (${ORIG_HARNESS}:${ORIG_MODEL}) failed (rc=${RC}) or hit quota/API error; saved failure output to ${FAILED_OUT}. Retrying with '${FALLBACK}' (${RES_HARNESS}:${RES_MODEL})..." >&2
      set +e
      run_resolved "$RES_HARNESS" "$RES_MODEL" "$RES_MODE" "$RES_BASE_URL" "$RES_API_KEY_ENV" "" "$ABS_OUT" "$ERR_LOG"
      RC=$?
      set -e
      cat "$ERR_LOG" >&2 || true
    fi
  fi
fi

rm -f "$ERR_LOG"
exit "$RC"
