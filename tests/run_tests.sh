#!/usr/bin/env bash
# Run every bash and Python test under tests/. Exits non-zero when any test file fails.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=()

for t in "${TESTS_DIR}"/test_*.sh; do
  echo "== $(basename "$t")"
  if ! bash "$t"; then
    FAILED+=("$(basename "$t")")
  fi
done

for t in "${TESTS_DIR}"/test_*.py; do
  [[ -e "$t" ]] || continue
  echo "== $(basename "$t")"
  if ! python3 -I "$t" -v 2>&1 | sed 's/^/  /'; then
    FAILED+=("$(basename "$t")")
  fi
done

echo
if [[ "${#FAILED[@]}" -eq 0 ]]; then
  echo "All test files passed."
else
  echo "FAILED: ${FAILED[*]}" >&2
  exit 1
fi
