#!/usr/bin/env bash
# Behavior of the layered config resolver (scripts/load_config.sh).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_fake_home
LOADER="${SKILL_DIR}/scripts/load_config.sh"
USER_CFG="${XDG_CONFIG_HOME}/multi-agent-delegation/config.env"

exported() { # <key> -> exported assignment for the key
  bash "$LOADER" --export-env --dir "$FAKE_HOME" | grep "^$1="
}

it "strips an inline comment from a config value"
printf '%s\n' 'DELEGATE_DEFAULT_MAX_BUDGET=none  # no hard cap' > "$USER_CFG"
assert_eq "exported assignment" "DELEGATE_DEFAULT_MAX_BUDGET=none" "$(exported DELEGATE_DEFAULT_MAX_BUDGET)"

it "keeps a hash that is part of an unquoted value"
printf '%s\n' 'DELEGATE_SCRATCH_DIR=$HOME/work/a#b' > "$USER_CFG"
assert_contains "scratch dir keeps a#b" "work/a#b" "$(exported DELEGATE_SCRATCH_DIR)"

it "keeps a hash inside a quoted value and drops the comment after it"
printf '%s\n' 'DELEGATE_ROLE_SCOUT="agy:x #1"  # note' > "$USER_CFG"
assert_contains "role keeps the quoted hash" "agy:x #1" "$(exported DELEGATE_ROLE_SCOUT)"

it "keeps a quoted value that contains a spaced hash"
printf '%s\n' "DELEGATE_ROLE_FAST='claude:sonnet # primary' # note" > "$USER_CFG"
assert_contains "role keeps the single-quoted value" "claude:sonnet # primary" "$(exported DELEGATE_ROLE_FAST)"

it "still resolves a value without any comment"
printf '%s\n' 'DELEGATE_DEFAULT_MAX_BUDGET=1.50' > "$USER_CFG"
assert_eq "exported assignment" "DELEGATE_DEFAULT_MAX_BUDGET=1.50" "$(exported DELEGATE_DEFAULT_MAX_BUDGET)"

it "still resolves when the directory it runs from contains a module shadowing the standard library"
mkdir -p "$FAKE_HOME/untrusted"
printf 'raise ImportError("shadowed stdlib json")\n' > "$FAKE_HOME/untrusted/json.py"
out="$(cd "$FAKE_HOME/untrusted" && bash "$LOADER" --json --dir "$FAKE_HOME/untrusted")"
assert_contains "resolver still answers" '"DELEGATE_ROLE_CODER"' "$out"

it "exposes the preflight settings with their defaults"
out="$(bash "$LOADER" --json --dir "$FAKE_HOME")"
assert_contains "preflight timeout default" '"DELEGATE_PREFLIGHT_TIMEOUT": "5"' "$out"
assert_contains "proxy ensure command default" '"DELEGATE_PROXY_ENSURE_CMD": ""' "$out"

finish
