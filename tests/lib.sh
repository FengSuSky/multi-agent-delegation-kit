#!/usr/bin/env bash
# Shared assertion helpers for the kit's bash tests (sourced by tests/test_*.sh).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="${KIT_DIR}/skill/multi-agent-delegation"

TEST_PASS=0
TEST_FAIL=0
TEST_CURRENT=""

it() { TEST_CURRENT="$1"; echo "  - $1"; }

# Failure details are a hint, not a transcript: keep them to a handful of lines.
_brief() {
  printf '%s' "$1" | head -n 12 | cut -c1-400
}

_fail() {
  TEST_FAIL=$((TEST_FAIL + 1))
  echo "    FAIL [$TEST_CURRENT] $1" >&2
  echo "         got:      $(_brief "$2")" >&2
  echo "         expected: $(_brief "$3")" >&2
}

assert_eq() { # <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    TEST_PASS=$((TEST_PASS + 1))
  else
    _fail "$1" "$3" "$2"
  fi
}

assert_match() { # <description> <extended regex> <text>
  if [[ "$3" =~ $2 ]]; then
    TEST_PASS=$((TEST_PASS + 1))
  else
    _fail "$1" "$3" "text matching /$2/"
  fi
}

assert_contains() { # <description> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then
    TEST_PASS=$((TEST_PASS + 1))
  else
    _fail "$1" "$3" "text containing '$2'"
  fi
}

assert_not_contains() { # <description> <forbidden needle> <haystack>
  if [[ "$3" != *"$2"* ]]; then
    TEST_PASS=$((TEST_PASS + 1))
  else
    _fail "$1" "$3" "text NOT containing '$2'"
  fi
}

assert_file_exists() { # <description> <path>
  if [[ -e "$2" ]]; then
    TEST_PASS=$((TEST_PASS + 1))
  else
    _fail "$1" "(missing)" "existing file $2"
  fi
}

# Point HOME at an empty directory so user config and state never leak into a test.
make_fake_home() {
  FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/madk-test.XXXXXX")"
  FAKE_HOME="$(cd "$FAKE_HOME" && pwd -P)"
  export HOME="${FAKE_HOME}"
  export XDG_CONFIG_HOME="${FAKE_HOME}/.config"
  mkdir -p "${XDG_CONFIG_HOME}/multi-agent-delegation" "${FAKE_HOME}/bin" "${FAKE_HOME}/work"
  # Stub binaries put into ~/bin shadow the real claude / agy / agent CLIs.
  PATH="${FAKE_HOME}/bin:${PATH}"
}

write_user_config() { # <config lines on stdin>
  cat > "${XDG_CONFIG_HOME}/multi-agent-delegation/config.env"
}

json_field() { # <field> <json file> -> prints the field's scalar value
  python3 -I -c 'import json, sys; print(json.load(open(sys.argv[2])).get(sys.argv[1], ""))' "$1" "$2"
}

finish() {
  echo "  => ${TEST_PASS} passed, ${TEST_FAIL} failed"
  [[ "$TEST_FAIL" -eq 0 ]]
}
