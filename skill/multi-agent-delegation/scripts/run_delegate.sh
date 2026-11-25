#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run_delegate.sh --preset <preset> --dir <workdir> --brief <file> --out <out.json> [options]

Presets:
  hydrogen-low   AGY gemini-4-hydrogen-low (fast search/summary/extraction)
  hydrogen       AGY gemini-4-hydrogen-medium (small/medium edits, self-verifying, default fallback)
  glm            Claude Code glm-5.3-flash[1m] (standard implementation, self-verifying)
  glm-opus       Claude Code glm-5.4[1m] (heavier low-cost implementation)
  sonnet-agy     AGY claude-sonnet-5-5-medium (escalation, self-verifying)
  sonnet-cursor  Cursor claude-sonnet-5-5-medium (escalation, no shell self-verify)
  opus-plan      AGY claude-opus-5-5-medium --mode plan (read-only joint decision)

Options:
  --test-cmd <cmd>       Allowed test command prefix for Claude Code (default: python3)
  --effort <level>       Claude Code reasoning effort: low|medium|high|xhigh|max (default: high)
  --max-budget <usd>     Claude Code max budget in USD to stop runaway loops (default: 1.00)
  --timeout <dur>        AGY print timeout (default: 300s)
  --resume <session_id>  Resume an existing session/conversation ID to reuse context & cache
  --keep-session         Keep Claude Code session on disk so follow-up turns can use --resume
  --fallback <preset>    Auto-fallback preset on quota/rate-limit/API error (default: hydrogen; use 'none' to disable)
  -h, --help             Show this help
EOF
}

PRESET=""
WORKDIR=""
BRIEF_FILE=""
OUT_FILE=""
TEST_CMD="python3"
EFFORT="high"
MAX_BUDGET="1.00"
TIMEOUT="300s"
RESUME_ID=""
KEEP_SESSION="0"
FALLBACK="hydrogen"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset) PRESET="$2"; shift 2 ;;
    --dir) WORKDIR="$2"; shift 2 ;;
    --brief) BRIEF_FILE="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --test-cmd) TEST_CMD="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --max-budget) MAX_BUDGET="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; KEEP_SESSION="1"; shift 2 ;;
    --keep-session) KEEP_SESSION="1"; shift 1 ;;
    --fallback) FALLBACK="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$PRESET" || -z "$WORKDIR" || -z "$BRIEF_FILE" || -z "$OUT_FILE" ]]; then
  echo "Error: --preset, --dir, --brief, and --out are required." >&2
  usage >&2
  exit 2
fi

if [[ ! -d "$WORKDIR" ]]; then
  echo "Error: workdir does not exist: $WORKDIR" >&2
  exit 1
fi

if [[ ! -f "$BRIEF_FILE" ]]; then
  echo "Error: brief file does not exist: $BRIEF_FILE" >&2
  exit 1
fi

ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"
ABS_BRIEF="$(cd "$(dirname "$BRIEF_FILE")" && pwd)/$(basename "$BRIEF_FILE")"
mkdir -p "$(dirname "$OUT_FILE")"
ABS_OUT="$(cd "$(dirname "$OUT_FILE")" && pwd)/$(basename "$OUT_FILE")"

check_agy_dir() {
  if [[ "$ABS_WORKDIR" != "$HOME"* ]]; then
    echo "Error: AGY requires --dir to be under \$HOME ($HOME), got: $ABS_WORKDIR" >&2
    exit 1
  fi
}

if [[ "$PRESET" == hydrogen* || "$PRESET" == *-agy || "$PRESET" == opus-plan ]]; then
  check_agy_dir
fi

BRIEF_CONTENT="$(cat "$ABS_BRIEF")"

run_preset() {
  local target_preset="$1"
  local resume_id="$2"
  local out_path="$3"
  local err_log="$4"

  cd "$ABS_WORKDIR"

  case "$target_preset" in
    hydrogen-low)
      check_agy_dir
      local args=(--model gemini-4-hydrogen-low --output-format json --print-timeout "$TIMEOUT")
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      /usr/bin/time -p agy "${args[@]}" -p "$BRIEF_CONTENT" > "$out_path" 2> "$err_log"
      ;;
    hydrogen)
      check_agy_dir
      local args=(--model gemini-4-hydrogen-medium --output-format json --print-timeout "$TIMEOUT")
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      /usr/bin/time -p agy "${args[@]}" -p "$BRIEF_CONTENT" > "$out_path" 2> "$err_log"
      ;;
    glm|glm-opus)
      local model_alias="sonnet"
      [[ "$target_preset" == "glm-opus" ]] && model_alias="opus"
      local args=(
        -p --model "$model_alias"
        --effort "$EFFORT"
        --max-budget-usd "$MAX_BUDGET"
        --exclude-dynamic-system-prompt-sections
        --permission-mode acceptEdits
        --permission-prompts none
        --output-format json
      )
      [[ "$KEEP_SESSION" == "0" ]] && args+=(--no-session-persistence)
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      # Feed brief via stdin so variadic --allowedTools never consumes the prompt argument
      /usr/bin/time -p claude "${args[@]}" --allowedTools "Read,Edit,Write,Bash(${TEST_CMD}:*)" < "$ABS_BRIEF" > "$out_path" 2> "$err_log"
      ;;
    sonnet-agy)
      check_agy_dir
      local args=(--model claude-sonnet-5-5-medium --output-format json --print-timeout "$TIMEOUT")
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      /usr/bin/time -p agy "${args[@]}" -p "$BRIEF_CONTENT" > "$out_path" 2> "$err_log"
      ;;
    sonnet-cursor)
      local args=(-p --trust --model claude-sonnet-5-5-medium --output-format json)
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      /usr/bin/time -p agent "${args[@]}" "$BRIEF_CONTENT" > "$out_path" 2> "$err_log"
      ;;
    opus-plan)
      check_agy_dir
      local args=(--model claude-opus-5-5-medium --mode plan --output-format json --print-timeout "$TIMEOUT")
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      /usr/bin/time -p agy "${args[@]}" -p "$BRIEF_CONTENT" > "$out_path" 2> "$err_log"
      ;;
    *)
      echo "Error: unknown preset '$target_preset'" >&2
      usage >&2
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
run_preset "$PRESET" "$RESUME_ID" "$ABS_OUT" "$ERR_LOG"
RC=$?
set -e

cat "$ERR_LOG" >&2 || true

if [[ "$FALLBACK" != "none" && "$PRESET" != "$FALLBACK" && "$PRESET" != hydrogen* ]]; then
  if needs_fallback "$RC" "$ABS_OUT" "$ERR_LOG"; then
    FAILED_OUT="${ABS_OUT%.json}.failed-${PRESET}.json"
    cp "$ABS_OUT" "$FAILED_OUT" 2>/dev/null || true
    echo "[FALLBACK] Preset '${PRESET}' failed (rc=${RC}) or hit quota/API error; saved failure output to ${FAILED_OUT}. Retrying with '${FALLBACK}'..." >&2
    # Do not pass cross-CLI resume_id when falling back to a different backend
    set +e
    run_preset "$FALLBACK" "" "$ABS_OUT" "$ERR_LOG"
    RC=$?
    set -e
    cat "$ERR_LOG" >&2 || true
  fi
fi

rm -f "$ERR_LOG"
exit "$RC"
