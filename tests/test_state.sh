#!/bin/bash
# Plan §4: session state machine, atomic state file, single-session lock.
cd "$(dirname "$0")/.." || exit 1
source tests/lib.sh
source lib/state.sh

export OWL_RUNTIME_DIR=$(mktemp -d)
trap 'rm -rf "$OWL_RUNTIME_DIR"' EXIT

echo "state file"
owl_state_init
assert_eq "init starts idle at 0%" "idle 0" "$(owl_state_get stage) $(owl_state_get percent)"
assert_eq "runtime dir is private" "700" "$(stat -c %a "$OWL_RUNTIME_DIR")"

owl_state_stage authorizing "Waiting for authorization…"
owl_state_stage starting "Starting the VM…"
assert_eq "stage and message are recorded" "starting|Starting the VM…" "$(owl_state_get stage)|$(owl_state_get message)"
assert_eq "percent follows the stage" "35" "$(owl_state_get percent)"

owl_state_progress 70 "Booting Windows…"
assert_eq "progress refines inside a stage" "70" "$(owl_state_get percent)"
owl_state_progress 40
assert_eq "progress never goes backwards" "70" "$(owl_state_get percent)"
owl_state_progress 250
assert_eq "progress is capped below 100 until the final stage" "99" "$(owl_state_get percent)"
owl_state_stage connecting "Connecting…"
assert_eq "a later stage never lowers the percent" "99" "$(owl_state_get percent)"
owl_state_stage running "Windows is ready"
assert_eq "running reaches 100" "100" "$(owl_state_get percent)"

owl_state_init
owl_state_stage starting "Starting…"
owl_state_stage failed "Could not start" "Docker is not running"
assert_eq "failure keeps the last percent so the bar shows where it stopped" \
  "failed 35 Docker is not running" "$(owl_state_get stage) $(owl_state_get percent) $(owl_state_get error)"

owl_state_init
owl_state_stage running "ready"
owl_state_stage closing "Closing…"
assert_eq "shutdown mode starts its own scale" "shutdown 10" "$(owl_state_get mode) $(owl_state_get percent)"
owl_state_stage stopped "Windows stopped"
assert_eq "stopped reaches 100" "100" "$(owl_state_get percent)"
owl_state_stage bogus "x" 2>/dev/null
assert_eq "unknown stages are rejected" "1" "$?"

echo "robustness"
owl_state_init
owl_state_stage starting 'quote " and $dollar and \ backslash'
assert_eq "messages with quotes/dollars survive intact" \
  'quote " and $dollar and \ backslash' "$(owl_state_get message)"
assert_eq "state file is always valid JSON" "ok" "$(jq -e . "$(owl_state_file)" >/dev/null && echo ok)"
assert_eq "no temp files are left behind" "0" "$(find "$OWL_RUNTIME_DIR" -name '.state.*' | wc -l)"
assert_eq "no credential fields exist in a fresh state" "0" \
  "$(owl_state_read | jq '[paths(scalars) | map(tostring) | join(".") | select(test("pass|secret|token|credential"; "i"))] | length')"

echo "single-session lock"
owl_lock_acquire
assert_eq "first session gets the lock" "0" "$?"
( source lib/state.sh; owl_lock_acquire; echo $? ) > "$OWL_RUNTIME_DIR/second" 2>/dev/null
assert_eq "a second session is refused while the first holds it" "1" "$(cat "$OWL_RUNTIME_DIR/second")"
owl_lock_release
( source lib/state.sh; owl_lock_acquire; echo $? ) > "$OWL_RUNTIME_DIR/third" 2>/dev/null
assert_eq "the lock is available again after release" "0" "$(cat "$OWL_RUNTIME_DIR/third")"

finish
