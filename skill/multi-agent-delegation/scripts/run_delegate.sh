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
  --test-cmd <cmd>       Test command prefixes Claude Code may run, comma-separated (default: from config or python3)
  --effort <level>       Claude Code reasoning effort: low|medium|high|xhigh|max (default: from config or high)
  --max-budget <usd>     Claude Code max budget in USD; 'none' or '0' disables the cap (default: from config or 1.00)
  --timeout <dur>        AGY print timeout (default: from config or 300s)
  --resume <session_id>  Resume an existing session/conversation ID to reuse context & cache
  --keep-session         Keep Claude Code session on disk so follow-up turns can use --resume
  --fallback <targets>   Channels to try next on error/quota/disabled, comma-separated in order
                         (default: from config or fast; 'none' to disable)
  --show-config          Print effective merged config (project > user > defaults) for --dir (default: .) and exit
  --resolve-only         Resolve target (--role/--preset) to harness/model/endpoint as JSON without executing
  --progress <out.json>  Report whether the run behind <out.json> is still alive and how far it has got, then exit
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
PROGRESS_OUT=""

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
    --progress) PROGRESS_OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$SHOW_CONFIG" == "1" ]]; then
  exec bash "$LOAD_CONFIG" --show --dir "${WORKDIR:-.}"
fi

format_elapsed() { # <seconds> -> 45s | 3m05s | 1h02m03s
  local total="$1"
  if (( total < 60 )); then
    printf '%ss' "$total"
  elif (( total < 3600 )); then
    printf '%dm%02ds' "$((total / 60))" "$((total % 60))"
  else
    printf '%dh%02dm%02ds' "$((total / 3600))" "$((total % 3600 / 60))" "$((total % 60))"
  fi
}

progress_summary() { # <events path> -> "N tool calls, last: <tool> <target>", from whole lines of a Claude Code stream
  python3 -I - "$1" <<'PY'
import json, sys

count, last = 0, ""


def show(text):
    print(text)
    raise SystemExit(0)


try:
    handle = open(sys.argv[1], encoding="utf-8", errors="ignore")
except OSError:
    show("waiting for the first event")

with handle:
    for line in handle:
        try:
            event = json.loads(line)
        except ValueError:
            continue  # the last line is still being written
        if not isinstance(event, dict) or event.get("type") != "assistant":
            continue
        content = (event.get("message") or {}).get("content")
        for block in content if isinstance(content, list) else []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                args = block.get("input") if isinstance(block.get("input"), dict) else {}
                count += 1
                target = next((str(args[key]) for key in ("file_path", "command", "pattern", "path", "prompt") if args.get(key)), "")
                last = " ".join("{} {}".format(block.get("name"), target).split())[:90]
if not count:
    show("started, no tool calls yet")
show("{} tool call{}, last: {}".format(count, "" if count == 1 else "s", last))
PY
}

# The caller of a background command decides what happens to its stderr, so the heartbeat alone
# cannot be relied on. The same facts are kept on disk: <out>.pid while the run is alive and
# <out>.events.jsonl as the harness reports its tool calls.
show_progress() { # <out path> -> one line: whether the run is alive, for how long, and how far it has got
  local out_path="$1"
  local label="" pid="" started=""
  if [[ -f "${out_path}.pid" ]]; then
    IFS=$'\t' read -r label pid started < "${out_path}.pid"
  fi
  local state=""
  if [[ -n "$pid" ]]; then
    local elapsed=""
    [[ "$started" =~ ^[0-9]+$ ]] && elapsed=" for $(format_elapsed $(( $(date +%s) - started )))"
    if kill -0 "$pid" 2>/dev/null; then
      state="running (pid ${pid})${elapsed}"
    else
      state="started (pid ${pid}) but no longer running${elapsed}; wait for the script to write its report"
    fi
  elif [[ -s "$out_path" ]]; then
    state="not running; a result was written to ${out_path}"
  else
    state="not running; no result was written to ${out_path}"
  fi
  local progress="no event stream found"
  [[ ! -f "${out_path}.events.jsonl" ]] || progress="$(progress_summary "${out_path}.events.jsonl")"
  printf '[DELEGATE] %s%s; %s\n' "${label:+${label}: }" "$state" "$progress"
}

if [[ -n "$PROGRESS_OUT" ]]; then
  show_progress "$PROGRESS_OUT"
  exit 0
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
TIMEOUT="${CLI_TIMEOUT:-${DELEGATE_DEFAULT_TIMEOUT:-300s}}"
PREFLIGHT_TIMEOUT="${DELEGATE_PREFLIGHT_TIMEOUT:-5}"
PROXY_ENSURE_CMD="${DELEGATE_PROXY_ENSURE_CMD:-}"
# Seconds between progress lines while a harness runs; 0 turns them off.
HEARTBEAT_INTERVAL="${DELEGATE_HEARTBEAT_INTERVAL:-30}"
[[ "$HEARTBEAT_INTERVAL" =~ ^[0-9]+$ ]] || HEARTBEAT_INTERVAL=30
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

is_budget_positive() {
  local v="$1"
  # A bare regex match cannot compare magnitudes, so let awk do the numeric check.
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v v="$v" 'BEGIN { exit !(v + 0 > 0) }'
}

# Claude Code only accepts a positive amount: `none` and `0` mean "no hard cap".
BUDGET_RAW="${CLI_MAX_BUDGET:-${DELEGATE_DEFAULT_MAX_BUDGET:-1.00}}"
MAX_BUDGET=""
if [[ -z "$BUDGET_RAW" || "$BUDGET_RAW" =~ ^[Nn]one$ || "$BUDGET_RAW" =~ ^0+([.]0+)?$ ]]; then
  :
elif is_budget_positive "$BUDGET_RAW"; then
  MAX_BUDGET="$BUDGET_RAW"
else
  echo "Error: invalid budget '${BUDGET_RAW}' for --max-budget / DELEGATE_DEFAULT_MAX_BUDGET (expected a positive number, 'none' or '0')." >&2
  exit 2
fi

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

trim_whitespace() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

split_csv() { # <csv> -> SPLIT_ITEMS holding the trimmed, non-empty entries
  local item
  local raw=()
  SPLIT_ITEMS=()
  [[ -z "$1" ]] && return 0
  IFS=',' read -r -a raw <<< "$1"
  for item in "${raw[@]}"; do
    item="$(trim_whitespace "$item")"
    [[ -n "$item" ]] && SPLIT_ITEMS+=("$item")
  done
  return 0
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

# Channels to try, in order: the primary target first, then each fallback of the chain.
CANDIDATES=("$TARGET")
if [[ "$FALLBACK" != "none" ]]; then
  split_csv "$FALLBACK"
  for item in ${SPLIT_ITEMS[@]+"${SPLIT_ITEMS[@]}"}; do
    [[ "$item" != "none" && "$item" != "$TARGET" ]] && CANDIDATES+=("$item")
  done
fi

# Drop disabled channels up front so a disabled primary never costs an attempt.
ROUTED_FROM=""
ORIG_HARNESS="$RES_HARNESS"
ENABLED=()
for candidate in "${CANDIDATES[@]}"; do
  resolve_target "$candidate" || exit 2
  is_target_disabled "$candidate" "$RES_HARNESS" && continue
  ENABLED+=("$candidate")
done
if [[ ${#ENABLED[@]} -eq 0 ]]; then
  echo "Error: target '${TARGET}' (harness=${ORIG_HARNESS}) is disabled and so is every fallback (${FALLBACK})." >&2
  exit 1
fi
if [[ "${ENABLED[0]}" != "$TARGET" ]]; then
  echo "[CONFIG] Target '${TARGET}' (harness=${ORIG_HARNESS}) is disabled; routing directly to '${ENABLED[0]}'." >&2
  ROUTED_FROM="$TARGET"
  TARGET="${ENABLED[0]}"
  RESUME_ID=""
fi
resolve_target "$TARGET"

if [[ "$RESOLVE_ONLY" == "1" ]]; then
  python3 -I - "$TARGET" "$ROUTED_FROM" "$RES_HARNESS" "$RES_MODEL" "$RES_MODE" "$RES_BASE_URL" "$RES_API_KEY_ENV" "$FALLBACK" "$TEST_CMD" "$EFFORT" "$MAX_BUDGET" "$TIMEOUT" <<'PY'
import json, sys
keys = [
    "target", "routed_from", "harness", "model", "mode",
    "base_url", "api_key_env", "fallback", "test_cmd", "effort", "max_budget", "timeout",
]
print(json.dumps(dict(zip(keys, sys.argv[1:])), ensure_ascii=False, indent=2))
PY
  exit 0
fi

# ---- Preflight: fail fast on a broken network path instead of letting a CLI retry for minutes ----
# Both spellings matter: an AGY session exports the upper-case pair, a shell profile often the lower-case one.
PROXY_VARS=(HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy)
PREFLIGHT_REASON=""
CLAUDE_DROP_PROXY=0

set_proxy_vars() { # -> NAME=value for every proxy variable that is set
  local v
  for v in "${PROXY_VARS[@]}"; do
    [[ -n "${!v:-}" ]] && printf '%s=%s\n' "$v" "${!v}"
  done
  return 0
}

tcp_listening() { # <host> <port> -> 0 when something accepts connections there
  (exec 3<>"/dev/tcp/$1/$2") >/dev/null 2>&1
}

loopback_proxy_address() { # <proxy url> -> host:port when the proxy is a tunnel or local proxy on this machine
  local url="$1"
  local p="${url#*://}"
  p="${p#*@}"
  p="${p%%/*}"
  case "${p%%:*}" in
    127.*|localhost|0.0.0.0) ;;
    *) return 0 ;;
  esac
  [[ "$p" == *:* ]] || p="${p}:80"
  printf '%s' "$p"
}

# Nothing can reach the network through a loopback port nobody listens on (a dropped SSH tunnel,
# a stopped local proxy). DELEGATE_PROXY_ENSURE_CMD may bring it back before giving up.
ensure_loopback_proxy() { # -> 0 when no loopback proxy is down, otherwise 1 with PREFLIGHT_REASON set
  local v address host port waited=0
  PREFLIGHT_REASON=""
  for v in "${PROXY_VARS[@]}"; do
    address="$(loopback_proxy_address "${!v:-}")"
    [[ -z "$address" ]] && continue
    host="${address%%:*}"
    port="${address##*:}"
    if ! tcp_listening "$host" "$port"; then
      if [[ -z "$PROXY_ENSURE_CMD" ]]; then
        PREFLIGHT_REASON="proxy ${address} (from ${v}) is not listening"
        return 1
      fi
      echo "[PREFLIGHT] proxy ${address} (from ${v}) is down; running DELEGATE_PROXY_ENSURE_CMD." >&2
      bash -c "${PROXY_ENSURE_CMD}" >/dev/null 2>&1 &
      until tcp_listening "$host" "$port"; do
        if [[ "$waited" -ge 80 ]]; then
          PREFLIGHT_REASON="proxy ${address} (from ${v}) is still down after DELEGATE_PROXY_ENSURE_CMD"
          return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
      done
      echo "[PREFLIGHT] proxy ${address} is back up." >&2
    fi
  done
  return 0
}

endpoint_reachable() { # <url> -> 0 when the endpoint answered, 1 when it certainly did not, 2 when inconclusive
  local rc=0
  curl -s -o /dev/null -m "$PREFLIGHT_TIMEOUT" "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    5|6|7|28) return 1 ;; # proxy unreachable, name resolution failed, connection refused, timed out
    *) return 2 ;;
  esac
}

# -> the endpoint Claude Code talks to, or nothing when it cannot be told without launching Claude Code
detect_claude_base_url() { # <role base url>
  local settings url
  [[ -n "$1" ]] && { printf '%s' "$1"; return 0; }
  [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && { printf '%s' "$ANTHROPIC_BASE_URL"; return 0; }
  for settings in "${ABS_WORKDIR}/.claude/settings.json" "${HOME}/.claude/settings.json"; do
    [[ -f "$settings" ]] || continue
    url="$(python3 -I - "$settings" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        print(json.load(handle).get("env", {}).get("ANTHROPIC_BASE_URL") or "")
except (OSError, ValueError):
    pass
PY
)"
    if [[ -n "$url" ]]; then
      printf '%s' "$url"
      return 0
    fi
  done
  return 0
}

preflight_agy() { # -> 0 to start agy, otherwise 1 with PREFLIGHT_REASON set
  PREFLIGHT_REASON=""
  [[ "$PREFLIGHT_TIMEOUT" == "0" ]] && return 0
  ensure_loopback_proxy
}

preflight_claude() { # <endpoint url> -> 0 to launch Claude Code, otherwise 1 with PREFLIGHT_REASON set
  local url="$1"
  local rc=0
  CLAUDE_DROP_PROXY=0
  PREFLIGHT_REASON=""
  [[ "$PREFLIGHT_TIMEOUT" == "0" ]] && return 0
  if ! command -v curl >/dev/null 2>&1; then
    echo "[PREFLIGHT] curl not found; skipping the endpoint check." >&2
    return 0
  fi
  if [[ -z "$url" ]]; then
    echo "[PREFLIGHT] Claude Code endpoint unknown; skipping the reachability check." >&2
    return 0
  fi
  # A down loopback proxy is not fatal here (Claude Code may connect directly), so its reason must
  # not survive to be mistaken for why a later launch failed.
  ensure_loopback_proxy || true
  PREFLIGHT_REASON=""
  endpoint_reachable "$url"
  rc=$?
  [[ "$rc" -eq 0 ]] && return 0
  if [[ "$rc" -eq 2 ]]; then
    echo "[PREFLIGHT] endpoint check inconclusive; proceeding anyway." >&2
    return 0
  fi
  # The caller's proxy settings (an AGY session routes every request through its own tunnel) may be
  # what is broken: try once more without them before giving up.
  if [[ -n "$(set_proxy_vars)" ]]; then
    rc=0
    (
      for v in "${PROXY_VARS[@]}"; do unset "$v"; done
      endpoint_reachable "$url"
    ) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      CLAUDE_DROP_PROXY=1
      echo "[PREFLIGHT] ${url} is unreachable through the inherited proxy settings; Claude Code will connect directly." >&2
      return 0
    fi
    PREFLIGHT_REASON="endpoint unreachable with and without the inherited proxy settings: ${url}"
  else
    PREFLIGHT_REASON="endpoint unreachable: ${url}"
  fi
  return 1
}

check_agy_dir() {
  if [[ "$ABS_WORKDIR" != "$HOME"* ]]; then
    echo "Error: AGY requires --dir to be under \$HOME ($HOME), got: $ABS_WORKDIR" >&2
    exit 1
  fi
}

BRIEF_CONTENT="$(cat "$ABS_BRIEF")"

extract_result() { # <events path> -> the last result event of a Claude Code stream, as one line of JSON
  python3 -I - "$1" <<'PY'
import json, sys

result = None
try:
    with open(sys.argv[1], encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict) and event.get("type") == "result":
                result = event
except OSError:
    pass
if result is not None:
    json.dump(result, sys.stdout, ensure_ascii=False)
PY
}

# Runs a harness in the background and reports its progress on stderr while it works. The output
# file stays empty until the very end, and an orchestrator watching only that file has killed a
# coder that was still reading the codebase six minutes into a multi-file task.
run_with_progress() { # <label> <events path or empty> <stdin path> <stdout path> <stderr path> <pid path> <command> [args...]
  local label="$1"
  local events="${2:-}"
  local input="$3"
  local out="$4"
  local err="$5"
  local pid_path="$6"
  shift 6
  # The background job of a non-interactive shell gets /dev/null for stdin, so it is wired up here.
  "$@" < "$input" > "$out" 2> "$err" &
  local child=$!
  printf '%s\t%s\t%s\n' "$label" "$child" "$(date +%s)" > "$pid_path"
  # A cancelled run must stop here rather than walk on to the fallback chain.
  trap 'rm -f "${pid_path}"; kill "${child}" 2>/dev/null; exit 143' TERM INT
  local rc=0
  if (( HEARTBEAT_INTERVAL <= 0 )); then
    wait "${child}" || rc=$?
    rm -f "$pid_path"
    trap - TERM INT
    return "$rc"
  fi
  local started=$SECONDS due=$((SECONDS + HEARTBEAT_INTERVAL)) progress
  echo "[DELEGATE] ${label} started; its output file stays empty until the end, progress is reported here every ${HEARTBEAT_INTERVAL}s." >&2
  [[ -z "$events" ]] || echo "[DELEGATE] full event stream: ${events}" >&2
  # Poll often so a quick run is not held for a whole interval; report only when the interval is up.
  while kill -0 "${child}" 2>/dev/null; do
    sleep 0.2
    kill -0 "${child}" 2>/dev/null || break
    (( SECONDS >= due )) || continue
    progress="still running; this harness has no progress stream"
    [[ -z "$events" ]] || progress="$(progress_summary "$events")"
    echo "[DELEGATE] ${label} $(format_elapsed $((SECONDS - started))), ${progress}" >&2
    due=$((SECONDS + HEARTBEAT_INTERVAL))
  done
  wait "${child}" || rc=$?
  rm -f "$pid_path"
  trap - TERM INT
  return "$rc"
}

run_resolved() {
  local harness="$1"
  local model="$2"
  local mode="$3"
  local base_url="$4"
  local api_key_env="$5"
  local resume_id="$6"
  local out_path="$7"
  local err_log="$8"
  local name="$9"

  cd "$ABS_WORKDIR"

  case "$harness" in
    agy)
      check_agy_dir
      if ! preflight_agy; then
        echo "[PREFLIGHT] ${PREFLIGHT_REASON}; not starting agy." >&2
        return 1
      fi
      local args=(--model "$model" --output-format json --print-timeout "$TIMEOUT")
      local prompt="$BRIEF_CONTENT"
      if [[ "$mode" == "plan" ]]; then
        args+=(--mode plan)
        # Nobody is there to approve a tool call in print mode: one denied call costs the whole run.
        prompt="> **Headless run constraint**: this prompt runs unattended and no one can approve tool permissions; any tool call is auto-denied and the run yields nothing. Do not call any tools (no commands, no file reads or searches, no plan files). Answer in plain Markdown only, based on the material below.

${prompt}"
      fi
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      run_with_progress "${name} (agy:${model})" "" /dev/null "$out_path" "$err_log" "${out_path}.pid" /usr/bin/time -p agy "${args[@]}" -p "$prompt"
      ;;
    claude)
      local perm_mode="acceptEdits"
      # Each comma-separated prefix gets its own rule: `npm test,npm run` covers both without
      # opening up every npm subcommand.
      split_csv "$TEST_CMD"
      local tool_rules=""
      local prefix
      for prefix in ${SPLIT_ITEMS[@]+"${SPLIT_ITEMS[@]}"}; do
        tool_rules+="${tool_rules:+,}${prefix}:*"
      done
      if [[ -z "$tool_rules" ]]; then
        echo "Error: the test command is empty; set --test-cmd or DELEGATE_DEFAULT_TEST_CMD." >&2
        return 2
      fi
      local allowed_tools="Read,Edit,Write,Bash(${tool_rules})"
      if [[ "$mode" == "plan" ]]; then
        perm_mode="plan"
        allowed_tools="Read,Glob,Grep"
      fi
      local args=(
        -p --model "$model"
        --effort "$EFFORT"
        --exclude-dynamic-system-prompt-sections
        --permission-mode "$perm_mode"
        --permission-prompts none
        # `--output-format json` prints nothing until the very end, so the events are streamed to a
        # sidecar file instead and the result is extracted once Claude Code has exited.
        --output-format stream-json --verbose
      )
      [[ -n "$MAX_BUDGET" ]] && args+=(--max-budget-usd "$MAX_BUDGET")
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

      if ! preflight_claude "$(detect_claude_base_url "$base_url")"; then
        echo "[PREFLIGHT] ${PREFLIGHT_REASON}; not launching Claude Code." >&2
        return 1
      fi

      local launch=(env)
      if [[ "$CLAUDE_DROP_PROXY" == "1" ]]; then
        local v
        for v in "${PROXY_VARS[@]}"; do launch+=(-u "$v"); done
      fi
      launch+=(${env_prefix[@]+"${env_prefix[@]}"})

      # The brief goes in on stdin so variadic --allowedTools never consumes the prompt argument
      local events_path="${out_path}.events.jsonl"
      rm -f "$events_path"
      run_with_progress "${name} (claude:${model})" "$events_path" "$ABS_BRIEF" "$events_path" "$err_log" "${out_path}.pid" \
        /usr/bin/time -p "${launch[@]}" claude "${args[@]}" --allowedTools "$allowed_tools"
      local rc=$?
      extract_result "$events_path" > "$out_path"
      return "$rc"
      ;;
    cursor)
      local args=(-p --trust --model "$model" --output-format json)
      [[ "$mode" == "plan" ]] && args+=(--mode plan)
      [[ -n "$resume_id" ]] && args+=(--resume "$resume_id")
      run_with_progress "${name} (cursor:${model})" "" /dev/null "$out_path" "$err_log" "${out_path}.pid" /usr/bin/time -p agent "${args[@]}" "$BRIEF_CONTENT"
      ;;
    *)
      echo "Error: unsupported harness '${harness}' (supported: agy, claude, cursor)." >&2
      return 2
      ;;
  esac
}

# -> prints why a finished attempt must not be trusted (status 0), or returns 1 when the result is acceptable
result_problem() { # <exit code> <out path> <stderr log>
  local rc="$1"
  local out_path="$2"
  local err_log="$3"
  local problem=""
  local checker_rc=0
  problem="$(python3 -I - "$rc" "$out_path" "$err_log" "${PREFLIGHT_REASON:-}" <<'PY'
import json, re, sys

rc, out_path, err_path, preflight = sys.argv[1:5]
quota_pat = re.compile(
    r"(quota|rate.?limit|insufficient|balance|credit|429|402|overloaded|exhausted|usage.?limit|billing|unauthorized)",
    re.I,
)
headless_pat = re.compile(r"no output produced|headless mode cannot prompt|auto-denied", re.I)
time_pat = re.compile(r"^(real|user|sys)\s.*$", re.M)
error_pat = re.compile(r"^(error|fatal|panic)\b", re.I)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as handle:
            return handle.read()
    except OSError:
        return ""


def squeeze(text, limit=300):
    return " ".join(text.split())[:limit]


def error_line(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    # Warnings can come first; the reason is the last line that states an error.
    for line in reversed(lines):
        if error_pat.match(line) or "Error:" in line:
            return line
    return lines[-1] if lines else ""


problem = preflight
raw = read(out_path).strip()
try:
    data = json.loads(raw) if raw else None
except ValueError:
    data = None
if not isinstance(data, dict):
    data = None
if data:
    detail = " ".join(str(data.get(k, "")) for k in ("api_error", "error", "result", "response"))
    error_text = " ".join(str(data.get(k, "")) for k in ("api_error", "error"))
    result_text = " ".join(str(data.get(k, "")) for k in ("error", "result", "response", "subtype", "api_error_status"))
else:
    detail = error_text = result_text = ""
err_text = time_pat.sub("", read(err_path))

if not problem and int(rc) != 0:
    problem = "exit code {}: {}".format(rc, squeeze(detail) or squeeze(error_line(err_text)))
if not problem and data is None:
    if not raw:
        problem = "empty output"
    elif headless_pat.search(raw):
        problem = "agy headless mode auto-denied a tool permission and produced no output"
    else:
        problem = "non-JSON output: " + squeeze(raw)
if not problem and (bool(data.get("is_error")) or str(data.get("status", "")).upper() in {"ERROR", "FAILED"}):
    problem = "the harness reported an error: " + (squeeze(error_text) or squeeze(detail) or "is_error")
if not problem and quota_pat.search(result_text) and len(result_text) < 600:
    problem = "quota or API error: " + squeeze(result_text)
if not problem and quota_pat.search(err_text):
    problem = "quota or API error on stderr: " + squeeze(err_text[-300:])

if problem:
    print(problem)
    sys.exit(0)
sys.exit(3)  # acceptable: distinct from 1 so a crash of this checker is never read as success
PY
)" || checker_rc=$?
  case "$checker_rc" in
    0)
      printf '%s' "$problem"
      return 0
      ;;
    3)
      return 1
      ;;
    *)
      printf 'could not inspect the result (checker exit code %s)' "$checker_rc"
      return 0
      ;;
  esac
}

# The output file is the contract with the calling agent: when every channel fails it is still valid
# JSON, naming each attempt and what to do next instead of leaving the reason on stderr only.
# Attempts arrive as argv (the script itself already occupies stdin): target, harness, model, exit code, reason.
write_failure_report() { # <out path> <target> <guard policy> <attempt field>...
  local out_path="$1"
  local target="$2"
  local policy="$3"
  shift 3
  python3 -I - "$out_path" "$target" "$policy" "$@" <<'PY'
import json, sys

out_path, target, policy, fields = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
attempts = []
for offset in range(0, len(fields) - len(fields) % 5, 5):
    name, harness, model, exit_code, reason = fields[offset:offset + 5]
    attempts.append(
        {"target": name, "harness": harness, "model": model, "exit_code": int(exit_code), "reason": reason}
    )
# The guard hook refuses a native worker under "deny": advice to start one would only be denied.
if policy == "deny":
    next_step = "Run the task in the main session or report these reasons to the user."
else:
    next_step = (
        "Inside an AGY session fall back to its native subagent "
        '(invoke_subagent with Model="flash" and Workspace="share", same brief); otherwise run the '
        "task in the main session or report these reasons to the user."
    )
report = {
    "status": "failed",
    "target": target,
    "attempts": attempts,
    "next": "Every channel failed. " + next_step + " Fix the channel and rerun the same command to retry.",
}
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
}

ERR_LOG="${ABS_OUT}.stderr"
# Each attempt is five tab-separated fields so the report writer receives them as plain arguments.
ATTEMPT_FIELDS=()
TRIED_CHANNELS=()
LAST_RC=0
SUCCEEDED=0
for candidate in "${ENABLED[@]}"; do
  resolve_target "$candidate"
  # A chain may name one channel twice (a role and its legacy preset): never pay for it twice.
  if printf '%s\n' ${TRIED_CHANNELS[@]+"${TRIED_CHANNELS[@]}"} | grep -q -x -- "${RES_HARNESS}:${RES_MODEL}"; then
    echo "[FALLBACK] Skipping '${candidate}': ${RES_HARNESS}:${RES_MODEL} was already tried." >&2
    continue
  fi
  [[ ${#TRIED_CHANNELS[@]} -gt 0 ]] && echo "[FALLBACK] Retrying with '${candidate}' (${RES_HARNESS}:${RES_MODEL})..." >&2
  TRIED_CHANNELS+=("${RES_HARNESS}:${RES_MODEL}")
  PREFLIGHT_REASON=""
  set +e
  run_resolved "$RES_HARNESS" "$RES_MODEL" "$RES_MODE" "$RES_BASE_URL" "$RES_API_KEY_ENV" "$RESUME_ID" "$ABS_OUT" "$ERR_LOG" "$candidate"
  LAST_RC=$?
  set -e
  # Only the primary target may resume an earlier session; a fallback starts fresh.
  RESUME_ID=""
  cat "$ERR_LOG" >&2 || true

  # A non-zero status means the result is acceptable; otherwise the function printed the reason.
  if ! PROBLEM="$(result_problem "$LAST_RC" "$ABS_OUT" "$ERR_LOG")"; then
    PROBLEM=""
  fi
  if [[ -z "$PROBLEM" ]]; then
    SUCCEEDED=1
    break
  fi
  note=""
  if cp "$ABS_OUT" "${ABS_OUT%.json}.failed-${candidate}.json" 2>/dev/null; then
    note="; saved its raw output to ${ABS_OUT%.json}.failed-${candidate}.json"
  fi
  ATTEMPT_FIELDS+=("$candidate" "$RES_HARNESS" "$RES_MODEL" "$LAST_RC" "$PROBLEM")
  echo "[FALLBACK] Target '${candidate}' (${RES_HARNESS}:${RES_MODEL}) failed: ${PROBLEM}${note}" >&2
done

rm -f "$ERR_LOG"
if [[ "$SUCCEEDED" -eq 1 ]]; then
  exit 0
fi
write_failure_report "$ABS_OUT" "$TARGET" "${DELEGATE_INHERIT_SUBAGENT:-rewrite}" ${ATTEMPT_FIELDS[@]+"${ATTEMPT_FIELDS[@]}"}
echo "[FALLBACK] Every channel failed; a report was written to ${ABS_OUT}." >&2
[[ "$LAST_RC" -ne 0 ]] || LAST_RC=1
exit "$LAST_RC"
