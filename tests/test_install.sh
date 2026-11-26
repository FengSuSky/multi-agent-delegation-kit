#!/usr/bin/env bash
# Behavior of the installer (install.sh) against a throwaway HOME.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_fake_home
INSTALL="${KIT_DIR}/install.sh"
HOOKS="${HOME}/.gemini/config/hooks.json"
INSTALLED_SKILL="${HOME}/.agents/skills/multi-agent-delegation"
LOG="${FAKE_HOME}/install.log"

install_kit() { # <options...> -> exit status in INSTALL_RC
  local rc
  bash "$INSTALL" "$@" > "${LOG}" 2>&1
  rc=$?
  INSTALL_RC="$rc"
  return "$rc"
}

guard_entry() { # -> the installed guard hook entry, or nothing
  python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])).get("multi-agent-delegation-guard"), sort_keys=True))' "$HOOKS" 2>/dev/null
  return 0
}

hook_names() { # -> top-level hook names, one per line
  python3 -I -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))))' "$HOOKS" 2>/dev/null
  return 0
}

echo "skill installation"
it "installs the skill without touching AGY hooks unless asked"
install_kit --skill-only
assert_eq "exit status" "0" "$INSTALL_RC"
assert_file_exists "skill installed" "${INSTALLED_SKILL}/scripts/run_delegate.sh"
assert_file_exists "guard script installed" "${INSTALLED_SKILL}/scripts/guard_subagent.py"
assert_eq "hooks file" "absent" "$([[ -e "$HOOKS" ]] && echo present || echo absent)"

echo "hook installation"
it "installs the guard hook for both guarded tools with --with-hooks"
install_kit --skill-only --with-hooks
assert_eq "exit status" "0" "$INSTALL_RC"
assert_contains "matcher covers subagents and commands" '"matcher": "invoke_subagent|run_command"' "$(guard_entry)"
assert_contains "runs the installed guard script" 'guard_subagent.py' "$(guard_entry)"

it "changes nothing when run a second time"
before="$(cat "$HOOKS")"
backups_before="$(ls "${HOOKS}".bak.* 2>/dev/null | wc -l | tr -d ' ')"
install_kit --skill-only --with-hooks
assert_eq "hooks file is byte-identical" "$before" "$(cat "$HOOKS")"
assert_eq "no extra backup" "$backups_before" "$(ls "${HOOKS}.bak."* 2>/dev/null | wc -l | tr -d ' ')"

it "upgrades a legacy guard entry and keeps unrelated hooks"
mkdir -p "$(dirname "$HOOKS")"
cat > "$HOOKS" <<'EOF'
{
  "my-own-hook": {
    "enabled": true,
    "PreToolUse": [
      {
        "matcher": "write_file",
        "hooks": [{"type": "command", "command": "echo hi"}]
      }
    ]
  },
  "multi-agent-delegation-guard": {
    "enabled": true,
    "PreToolUse": [
      {
        "matcher": "invoke_subagent",
        "hooks": [{"type": "command", "command": "python3 ~/.agents/skills/multi-agent-delegation/scripts/guard_subagent.py"}]
      }
    ]
  }
}
EOF
cp "$HOOKS" "${FAKE_HOME}/hooks.original.json"
install_kit --skill-only --with-hooks
assert_eq "exit status" "0" "$INSTALL_RC"
assert_contains "unrelated hook kept" "my-own-hook" "$(hook_names)"
assert_contains "legacy matcher upgraded" '"matcher": "invoke_subagent|run_command"' "$(guard_entry)"
assert_file_exists "previous hooks file backed up" "$(ls "${HOOKS}".bak.* 2>/dev/null | head -n 1)"
assert_eq "backup holds the previous content" "$(cat "${FAKE_HOME}/hooks.original.json")" "$(cat "$(ls -t "${HOOKS}".bak.* | head -n 1)")"

it "leaves the hooks file alone on a dry run"
cp "${FAKE_HOME}/hooks.original.json" "$HOOKS"
install_kit --skill-only --with-hooks --dry-run
assert_eq "exit status" "0" "$INSTALL_RC"
assert_eq "hooks file unchanged" "$(cat "${FAKE_HOME}/hooks.original.json")" "$(cat "$HOOKS")"

it "refuses to rewrite a hooks file that is not valid JSON"
printf '{ not json\n' > "$HOOKS"
install_kit --skill-only --with-hooks
assert_eq "exit status" "1" "$INSTALL_RC"
assert_eq "broken file left as it was" "{ not json" "$(cat "$HOOKS")"
assert_contains "explains why" "hooks.json" "$(cat "$LOG")"

it "installs a hook that answers with the default policy"
rm -f "$HOOKS" "${HOOKS}".bak.*
install_kit --skill-only --with-hooks
payload='{"conversationId":"c","workspacePaths":["'"${FAKE_HOME}"'"],"cwd":"'"${FAKE_HOME}"'","hookEventName":"PreToolUse","toolCall":{"id":"call_1","name":"invoke_subagent","args":{"TypeName":"self","Model":"inherit","Workspace":"inherit","Prompt":"implement it"}}}'
decision="$(printf '%s' "$payload" | python3 -I "${INSTALLED_SKILL}/scripts/guard_subagent.py")"
assert_eq "decision of the installed hook" '{"decision": "allow", "overwrite": {"Model": "flash"}}' "$decision"

finish
