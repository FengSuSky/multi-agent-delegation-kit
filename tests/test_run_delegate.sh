#!/usr/bin/env bash
# End-to-end behavior of the delegation script (scripts/run_delegate.sh) against stub CLIs.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_fake_home
DELEGATE="${SKILL_DIR}/scripts/run_delegate.sh"
WORK="${FAKE_HOME}/work/repo"
LOGS="${FAKE_HOME}/logs"
BRIEF="${WORK}/brief.md"
OUT="${WORK}/out.json"
SERVER_PID=""
ENSURE_PID=""

mkdir -p "$WORK" "$LOGS"
printf '## 目标\ndo the thing\n' > "$BRIEF"
cp "${KIT_DIR}/tests/stubs/claude" "${KIT_DIR}/tests/stubs/agy" "${FAKE_HOME}/bin/"
cp "${KIT_DIR}/tests/stubs/ensure_proxy.py" "${FAKE_HOME}/ensure_proxy.py"
chmod +x "${FAKE_HOME}/bin/claude" "${FAKE_HOME}/bin/agy"
export STUB_LOG_DIR="${LOGS}"

cleanup() {
  [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null
  [[ -n "${ENSURE_PID}" ]] && kill "${ENSURE_PID}" 2>/dev/null
  return 0
}
trap cleanup EXIT

RUN_ENV=()
RUN_RC=0
run_delegate() { # <args...> -> exit status in RUN_RC (and as return value); extra env comes from RUN_ENV
  local rc
  # Never depend on the proxy the real shell happens to export.
  [[ ${#RUN_ENV[@]} -eq 0 ]] && only_proxy_env ""
  rm -f "${LOGS}"/claude.argv "${LOGS}"/claude.calls "${LOGS}"/claude.stdin "${LOGS}"/claude.proxyenv "${LOGS}"/agy.argv "${LOGS}"/agy.calls "${OUT}" "${WORK}"/out.failed-*.json
  [[ -n "${KEEP_EVENTS:-}" ]] || rm -f "${OUT}.events.jsonl"
  rm -f "${OUT}.pid"
  env ${RUN_ENV[@]+"${RUN_ENV[@]}"} bash "$DELEGATE" --dir "$WORK" --brief "$BRIEF" --out "$OUT" "$@" > "${LOGS}/run.log" 2>&1
  rc=$?
  RUN_ENV=()
  RUN_RC="$rc"
  return "$rc"
}

run_log() { cat "${LOGS}/run.log" 2>/dev/null; }
claude_argv() { cat "${LOGS}/claude.argv" 2>/dev/null; }
agy_argv() { cat "${LOGS}/agy.argv" 2>/dev/null; }

budget_value_passed_to_claude() { # -> the value following --max-budget-usd, or empty when the flag is absent
  grep -A1 -x -- '--max-budget-usd' "${LOGS}/claude.argv" 2>/dev/null | tail -n 1
}

free_port() { # -> a TCP port nothing is listening on
  python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# Take over the proxy environment completely: the real shell may export live proxies and a NO_PROXY
# covering 127.0.0.1, which would let curl sidestep the proxy a test wants to be dead.
only_proxy_env() { # <proxy url or empty>
  local upper="$1" lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  RUN_ENV=("HTTP_PROXY=${upper}" "HTTPS_PROXY=${upper}" "ALL_PROXY=" "http_proxy=${lower}" "https_proxy=${lower}" "all_proxy=" "NO_PROXY=" "no_proxy=")
}

proxy_vars_seen_by_claude() { # -> every proxy variable except NO_PROXY that reached the stub Claude Code
  grep -i -E '^(https?_proxy|all_proxy)=' "${LOGS}/claude.proxyenv" 2>/dev/null
  return 0
}

call_count() { # <claude|agy> -> how many times the stub CLI was launched
  [[ -e "${LOGS}/$1.calls" ]] || { printf '0'; return 0; }
  wc -l < "${LOGS}/$1.calls" | tr -d ' '
  return 0
}

report() { # <field or index>... -> that value of the run's failure report, or nothing when there is none
  python3 -I -c '
import json, sys
try:
    value = json.load(open(sys.argv[1]))
    for key in sys.argv[2:]:
        value = value[int(key)] if key.isdigit() else value[key]
except (OSError, ValueError, KeyError, IndexError, TypeError):
    sys.exit(0)
print(value if not isinstance(value, (list, dict)) else json.dumps(value, ensure_ascii=False))
' "$OUT" "$@" 2>/dev/null
  return 0
}

# A real local HTTP endpoint, standing in for the model API the stub Claude Code would talk to.
start_local_http_server() {
  python3 -I - "${LOGS}/server.port" <<'PY' &
import http.server
import socketserver
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass

server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
PY
  SERVER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "${LOGS}/server.port" ]] && break
    sleep 0.2
  done
  LIVE_PORT="$(cat "${LOGS}/server.port")"
}

echo "budget flag"
it "omits --max-budget-usd when the budget is 'none'"
run_delegate --role coder --max-budget none
assert_eq "exit status" "0" "$RUN_RC"
assert_eq "budget flag passed to claude" "" "$(budget_value_passed_to_claude)"

it "omits --max-budget-usd when the budget is '0'"
run_delegate --role coder --max-budget 0
assert_eq "budget flag passed to claude" "" "$(budget_value_passed_to_claude)"

it "passes a numeric budget through to Claude Code"
run_delegate --role coder --max-budget 1.50
assert_eq "budget value passed to claude" "1.50" "$(budget_value_passed_to_claude)"

it "reads a numeric budget from the user config"
printf '%s\n' 'DELEGATE_DEFAULT_MAX_BUDGET=0.75' | write_user_config
run_delegate --role coder
assert_eq "budget value passed to claude" "0.75" "$(budget_value_passed_to_claude)"

it "treats a configured 'none  # comment' budget as no cap"
printf '%s\n' 'DELEGATE_DEFAULT_MAX_BUDGET=none  # no hard cap' | write_user_config
run_delegate --role coder
assert_eq "budget flag passed to claude" "" "$(budget_value_passed_to_claude)"

it "rejects a budget that is neither a positive number nor 'none'"
run_delegate --role coder --max-budget abc
assert_eq "exit status" "2" "$RUN_RC"
assert_contains "error names the setting" "DELEGATE_DEFAULT_MAX_BUDGET" "$(run_log)"
assert_eq "claude is never launched" "" "$(claude_argv)"

echo "preflight"
start_local_http_server
DEAD_PORT="$(free_port)"
printf '%s\n' "DELEGATE_ROLE_CODER_BASE_URL=http://127.0.0.1:${LIVE_PORT}" 'DELEGATE_PREFLIGHT_TIMEOUT=5' | write_user_config

it "runs Claude Code unchanged when the endpoint answers"
only_proxy_env ""
run_delegate --role coder
assert_eq "exit status" "0" "$RUN_RC"
assert_contains "claude is launched" "--model" "$(claude_argv)"
assert_not_contains "no preflight warning" "[PREFLIGHT]" "$(run_log)"

it "drops an inherited proxy that points at a dead local port and connects directly"
only_proxy_env "http://127.0.0.1:${DEAD_PORT}"
run_delegate --role coder
assert_eq "exit status" "0" "$RUN_RC"
assert_contains "claude is launched" "--model" "$(claude_argv)"
assert_eq "dead proxy no longer exported to claude" "" "$(proxy_vars_seen_by_claude)"
assert_contains "explains the fallback" "[PREFLIGHT]" "$(run_log)"

it "fails fast instead of launching Claude Code when the endpoint is unreachable with and without the proxy"
printf '%s\n' "DELEGATE_ROLE_CODER_BASE_URL=http://127.0.0.1:${DEAD_PORT}" 'DELEGATE_PREFLIGHT_TIMEOUT=2' | write_user_config
only_proxy_env "http://127.0.0.1:$(free_port)"
run_delegate --role coder
assert_eq "exit status" "1" "$RUN_RC"
assert_eq "claude is never launched" "" "$(claude_argv)"
assert_contains "reason mentions the unreachable endpoint" "unreachable" "$(run_log)"

it "reads the endpoint from Claude Code settings when the role has no base URL"
mkdir -p "${HOME}/.claude"
printf '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:%s"}}\n' "${DEAD_PORT}" > "${HOME}/.claude/settings.json"
: > "${XDG_CONFIG_HOME}/multi-agent-delegation/config.env"
run_delegate --role coder --fallback none
assert_eq "exit status" "1" "$RUN_RC"
assert_eq "claude is never launched" "" "$(claude_argv)"

it "skips the reachability check when the preflight timeout is 0"
printf '%s\n' 'DELEGATE_PREFLIGHT_TIMEOUT=0' | write_user_config
only_proxy_env ""
run_delegate --role coder
assert_eq "exit status" "0" "$RUN_RC"
assert_contains "claude is launched" "--model" "$(claude_argv)"

it "refuses to start a nested agy run while an inherited loopback proxy is down"
rm -f "${HOME}/.claude/settings.json"
: > "${XDG_CONFIG_HOME}/multi-agent-delegation/config.env"
only_proxy_env "http://127.0.0.1:${DEAD_PORT}"
run_delegate --role fast
assert_eq "exit status" "1" "$RUN_RC"
assert_eq "agy is never launched" "" "$(agy_argv)"
assert_contains "reason names the dead proxy" "127.0.0.1:${DEAD_PORT}" "$(run_log)"

it "brings a down loopback proxy back with the configured ensure command before starting agy"
ENSURE_PORT="$(free_port)"
printf '%s\n' "DELEGATE_PROXY_ENSURE_CMD=python3 -I ${FAKE_HOME}/ensure_proxy.py ${ENSURE_PORT} ${LOGS}/ensure.pid" | write_user_config
only_proxy_env "http://127.0.0.1:${ENSURE_PORT}"
run_delegate --role fast
assert_eq "exit status" "0" "$RUN_RC"
assert_contains "agy is launched after the proxy is back" "--model" "$(agy_argv)"
assert_file_exists "ensure command ran" "${LOGS}/ensure.pid"
[[ -s "${LOGS}/ensure.pid" ]] && ENSURE_PID="$(cat "${LOGS}/ensure.pid")"

echo "fallback chain and failure report"
USER_CFG_FILE="${XDG_CONFIG_HOME}/multi-agent-delegation/config.env"

it "walks a comma-separated fallback chain until a channel succeeds"
: > "$USER_CFG_FILE"
export STUB_CLAUDE_MODE=error_json STUB_AGY_FAIL_CALLS=1
run_delegate --role coder --fallback fast,scout
unset STUB_CLAUDE_MODE STUB_AGY_FAIL_CALLS
assert_eq "exit status" "0" "$RUN_RC"
assert_contains "the output is the successful channel's own result" "done by agy" "$(cat "${OUT}")"
assert_contains "the last agy call uses the scout model" "gemini-4-hydrogen-low" "$(agy_argv)"
assert_contains "the second hop is reported" "Retrying with 'scout'" "$(run_log)"

it "writes a structured failure report when every channel fails"
: > "$USER_CFG_FILE"
export STUB_CLAUDE_MODE=error_json STUB_AGY_FAIL_CALLS=99
run_delegate --role coder --fallback fast
unset STUB_CLAUDE_MODE STUB_AGY_FAIL_CALLS
assert_eq "exit status" "1" "$RUN_RC"
assert_eq "report status" "failed" "$(report status)"
assert_eq "first attempt named" "coder" "$(report attempts 0 target)"
assert_contains "first attempt reason comes from the harness result" "Connection refused" "$(report attempts 0 reason)"
assert_eq "second attempt named" "fast" "$(report attempts 1 target)"
assert_contains "second attempt reason carries the exit code" "exit code 1" "$(report attempts 1 reason)"
assert_contains "report offers the native subagent the guard allows by default" "invoke_subagent" "$(report next)"
assert_file_exists "raw failed output kept for debugging" "${WORK}/out.failed-coder.json"

it "stops advising a native subagent once the guard refuses those"
printf '%s\n' "DELEGATE_INHERIT_SUBAGENT=deny" | write_user_config
export STUB_CLAUDE_MODE=error_json STUB_AGY_FAIL_CALLS=99
run_delegate --role coder --fallback fast
unset STUB_CLAUDE_MODE STUB_AGY_FAIL_CALLS
assert_eq "report status" "failed" "$(report status)"
assert_contains "report points at the main session instead" "main session" "$(report next)"
assert_not_contains "no advice the guard would refuse" "invoke_subagent" "$(report next)"

it "treats agy's headless no-output run as a failure"
: > "$USER_CFG_FILE"
export STUB_AGY_MODE=headless
run_delegate --role fast --fallback none
unset STUB_AGY_MODE
assert_eq "exit status" "1" "$RUN_RC"
assert_eq "report status" "failed" "$(report status)"
assert_contains "reason names the headless denial" "headless" "$(report attempts 0 reason)"

it "carries the preflight reason into the failure report"
printf '%s\n' "DELEGATE_ROLE_CODER_BASE_URL=http://127.0.0.1:${DEAD_PORT}" | write_user_config
run_delegate --role coder --fallback none
assert_eq "exit status" "1" "$RUN_RC"
assert_contains "reason names the unreachable endpoint" "unreachable" "$(report attempts 0 reason)"

it "does not launch the same harness and model twice in one chain"
: > "$USER_CFG_FILE"
export STUB_CLAUDE_MODE=error_json
# `glm` is the legacy preset for coder's channel, `coder` repeats the primary target by name.
run_delegate --role coder --fallback glm,coder,fast
unset STUB_CLAUDE_MODE
assert_eq "exit status" "0" "$RUN_RC"
assert_eq "claude launched once" "1" "$(call_count claude)"
assert_eq "agy launched once" "1" "$(call_count agy)"

it "routes a disabled primary target to the first enabled fallback"
printf '%s\n' 'DELEGATE_DISABLED_HARNESSES=claude' | write_user_config
run_delegate --role coder --fallback fast,scout
assert_eq "exit status" "0" "$RUN_RC"
assert_eq "claude is never launched" "0" "$(call_count claude)"
assert_contains "routing is explained" "routing directly to 'fast'" "$(run_log)"
assert_contains "the first enabled fallback is used" "gemini-4-hydrogen-medium" "$(agy_argv)"

it "fails up front when the primary target and every fallback are disabled"
printf '%s\n' 'DELEGATE_DISABLED_HARNESSES=claude,agy' | write_user_config
run_delegate --role coder --fallback fast
assert_eq "exit status" "1" "$RUN_RC"
assert_contains "error names the disabled target" "'coder'" "$(run_log)"
assert_eq "no CLI is launched" "0" "$(( $(call_count claude) + $(call_count agy) ))"
: > "$USER_CFG_FILE"

agy_prompt() { # -> the prompt argument of the last agy call (everything after -p)
  sed -n '/^-p$/,$p' "${LOGS}/agy.argv" 2>/dev/null | tail -n +2
  return 0
}

echo "test command prefixes"
it "grants each prefix of a comma-separated test command instead of one broad one"
: > "$USER_CFG_FILE"
run_delegate --role coder --test-cmd "npm test,npm run" --fallback none
assert_contains "claude gets one narrow rule per prefix" "Bash(npm test:*,npm run:*)" "$(claude_argv)"

it "still grants a single test command as before"
run_delegate --role coder --test-cmd pytest --fallback none
assert_contains "single prefix rule" "Bash(pytest:*)" "$(claude_argv)"

echo "headless plan mode"
it "tells a headless agy plan run not to call tools, because nobody can approve them"
: > "$USER_CFG_FILE"
run_delegate --preset opus-plan --fallback none
assert_eq "exit status" "0" "$RUN_RC"
assert_contains "the plan mode flag is passed" "--mode" "$(agy_argv)"
assert_contains "the constraint precedes the brief" "Do not call any tools" "$(agy_prompt)"

it "leaves a normal agy run's brief untouched"
run_delegate --role fast --fallback none
assert_eq "exit status" "0" "$RUN_RC"
assert_eq "prompt is exactly the brief" "## 目标" "$(agy_prompt | head -n 1)"

echo "hardening"
it "lets a module planted in the work directory neither break nor silence result checking"
: > "${XDG_CONFIG_HOME}/multi-agent-delegation/config.env"
printf 'raise ImportError("shadowed stdlib json")\n' > "${WORK}/json.py"
export STUB_CLAUDE_MODE=error_json
run_delegate --role coder
unset STUB_CLAUDE_MODE
assert_contains "a failed Claude Code result still triggers the fallback" "--model" "$(agy_argv)"
rm -f "${WORK}/json.py"

output_format_value_passed_to_claude() { # -> the value following --output-format
  grep -A1 -x -- '--output-format' "${LOGS}/claude.argv" 2>/dev/null | tail -n 1
}

echo "progress heartbeat"
EVENTS="${OUT}.events.jsonl"

it "streams Claude Code events to a sidecar file and still writes the result to the output file"
: > "$USER_CFG_FILE"
export KEEP_EVENTS=1
printf '%s\n' '{"type":"result","result":"stale"}' > "${EVENTS}"
run_delegate --role coder --fallback none
unset KEEP_EVENTS
assert_eq "exit status" "0" "$RUN_RC"
assert_eq "claude streams its events" "stream-json" "$(output_format_value_passed_to_claude)"
assert_contains "streaming needs the verbose flag in print mode" "--verbose" "$(claude_argv)"
assert_eq "the output file holds the result event" "done by claude" "$(json_field result "$OUT")"
assert_contains "the brief still reaches Claude Code on stdin" "do the thing" "$(cat "${LOGS}/claude.stdin")"
assert_contains "the event stream is kept beside the output" '"type":"assistant"' "$(cat "$EVENTS")"
assert_not_contains "events of an earlier run are not mixed in" "stale" "$(cat "$EVENTS")"
assert_contains "the start line says where progress will be reported" "[DELEGATE] coder (claude:sonnet) started" "$(run_log)"

it "reports the coder's progress on stderr while it works"
printf '%s\n' 'DELEGATE_HEARTBEAT_INTERVAL=1' | write_user_config
export STUB_CLAUDE_SLEEP=3
run_delegate --role coder --fallback none
unset STUB_CLAUDE_SLEEP
assert_eq "exit status" "0" "$RUN_RC"
assert_match "a heartbeat carries the elapsed time and the last tool call" '\[DELEGATE\] coder \(claude:sonnet\) [0-9]+s, 1 tool call, last: Read src/app\.py' "$(run_log)"
assert_contains "the run still ends with the streamed result" "done by claude" "$(json_field result "$OUT")"

it "falls back to the elapsed time alone for a harness without a progress stream"
printf '%s\n' 'DELEGATE_HEARTBEAT_INTERVAL=1' | write_user_config
export STUB_AGY_SLEEP=3
run_delegate --role fast --fallback none
unset STUB_AGY_SLEEP
assert_contains "the heartbeat still shows the run is alive" "[DELEGATE] fast (agy:gemini-4-hydrogen-medium) " "$(run_log)"
assert_contains "and says there is no finer progress" "no progress stream" "$(run_log)"

it "leads the failure reason with the error line, not the warnings printed before it"
: > "$USER_CFG_FILE"
export STUB_CLAUDE_MODE=warn_then_fail
run_delegate --role coder --fallback none
unset STUB_CLAUDE_MODE
assert_eq "report status" "failed" "$(report status)"
assert_contains "reason names the error" "exit code 1: Error: Input must be provided" "$(report attempts 0 reason)"

it "stays silent when heartbeats are turned off"
printf '%s\n' 'DELEGATE_HEARTBEAT_INTERVAL=0' | write_user_config
export STUB_CLAUDE_SLEEP=1.5
run_delegate --role coder --fallback none
unset STUB_CLAUDE_SLEEP
assert_eq "exit status" "0" "$RUN_RC"
assert_not_contains "no progress lines are printed" "[DELEGATE]" "$(run_log)"

it "answers a progress query for a run in flight, whatever the caller does with stderr"
: > "$USER_CFG_FILE"
: > "${LOGS}/claude.calls"
rm -f "${OUT}.pid"
export STUB_CLAUDE_SLEEP=3
only_proxy_env ""
env ${RUN_ENV[@]+"${RUN_ENV[@]}"} bash "$DELEGATE" --dir "$WORK" --brief "$BRIEF" --out "$OUT" --role coder --fallback none > /dev/null 2>&1 &
DELEGATE_PID=$!
sleep 1
QUERY="$(bash "$DELEGATE" --progress "$OUT" 2>&1)"
wait "${DELEGATE_PID}" || true
unset STUB_CLAUDE_SLEEP
assert_contains "the in-flight run is reported alive" "coder (claude:sonnet): running (pid " "${QUERY}"
assert_contains "with how far it has got" "1 tool call, last: Read src/app.py" "${QUERY}"
assert_eq "the query itself launches nothing" "1" "$(call_count claude)"
AFTER="$(bash "$DELEGATE" --progress "$OUT" 2>&1)"
assert_contains "nothing claims to be running once the run has finished" "not running; a result was written" "${AFTER}"

it "stops a cancelled run without walking on to the fallback chain"
: > "$USER_CFG_FILE"
: > "${LOGS}/claude.calls"
: > "${LOGS}/agy.calls"
rm -f "${OUT}.pid"
export STUB_CLAUDE_SLEEP=4
only_proxy_env ""
env ${RUN_ENV[@]+"${RUN_ENV[@]}"} bash "$DELEGATE" --dir "$WORK" --brief "$BRIEF" --out "$OUT" --role coder > /dev/null 2>&1 &
DELEGATE_PID=$!
sleep 1
kill -TERM "${DELEGATE_PID}"
wait "${DELEGATE_PID}" && CANCEL_RC=0 || CANCEL_RC=$?
unset STUB_CLAUDE_SLEEP
assert_eq "the cancelled script exits with the status of the signal" "143" "${CANCEL_RC}"
assert_eq "no fallback is started for a run the orchestrator cancelled" "0" "$(call_count agy)"
assert_eq "the pid file goes with it" "" "$(ls "${OUT}.pid" 2>/dev/null)"

finish
