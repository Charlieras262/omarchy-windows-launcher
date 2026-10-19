#!/bin/bash
# Minimal assertion helpers; no test framework to install (constitution I).
PASS=0 FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; [[ -n ${2:-} ]] && printf '       %s\n' "$2" >&2; }

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}

finish() {
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  ((FAIL == 0))
}
