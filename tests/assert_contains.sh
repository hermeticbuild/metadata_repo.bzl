#!/usr/bin/env bash
# Usage: assert_contains.sh RLOCATIONPATH... -- PATTERN...
# A pattern prefixed with "!" must NOT appear. All files are concatenated.
set -euo pipefail

paths=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
  paths+=("$1")
  shift
done
shift
content=""
for p in "${paths[@]}"; do
  f="${TEST_SRCDIR}/${p}"
  [[ -f "$f" ]] || { echo "missing file: $f" >&2; exit 1; }
  content+="$(cat "$f")"$'\n'
done

status=0
for pattern in "$@"; do
  if [[ "$pattern" == '!'* ]]; then
    if grep -qF -- "${pattern:1}" <<<"$content"; then
      echo "FAIL: unexpected: ${pattern:1}" >&2
      status=1
    fi
  elif ! grep -qF -- "$pattern" <<<"$content"; then
    echo "FAIL: expected: $pattern" >&2
    status=1
  fi
done
if [[ $status -ne 0 ]]; then
  echo "--- content ---" >&2
  echo "$content" >&2
fi
exit $status
