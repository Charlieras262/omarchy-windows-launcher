#!/bin/bash
# Session state shared between the orchestrator (writer) and the shell plugin
# (reader). Plan §4. The state file never holds credentials (NFR-003): callers
# can only set the fields below, and message/error are plain progress text.
#
# Sourced; no side effects at source time. Requires jq and flock (util-linux).

OWL_RUNTIME_DIR="${OWL_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/omarchy-windows-launcher}"

# Launch stages and the overall percentage each one starts at. "booting" may be
# refined between its start and the next stage's start with owl_state_progress.
declare -A OWL_STAGE_PERCENT=(
  [idle]=0 [dialog]=0 [authorizing]=8 [preparing-disks]=20 [starting]=35
  [booting]=55 [connecting]=92 [running]=100
  # shutdown mode
  [closing]=10 [stopping]=35 [releasing]=75 [stopped]=100
  # terminal
  [failed]=-1 [cancelled]=0
)
OWL_LAUNCH_STAGES=(authorizing preparing-disks starting booting connecting running)
OWL_SHUTDOWN_STAGES=(closing stopping releasing stopped)

owl_state_file() { printf '%s/state.json' "$OWL_RUNTIME_DIR"; }

owl_state_init() {
  mkdir -p -- "$OWL_RUNTIME_DIR" && chmod 0700 -- "$OWL_RUNTIME_DIR" || return 1
  owl_state_write '{"stage":"idle","mode":"launch","percent":0,"message":"","error":"","keepAlive":true,"allMonitors":false,"disks":[],"hidBar":false,"unclean":[],"updatedAt":0}'
}

# Atomic write: readers never see a half-written file.
owl_state_write() {
  local file tmp
  file=$(owl_state_file)
  tmp=$(mktemp "$OWL_RUNTIME_DIR/.state.XXXXXX") || return 1
  if ! jq -c --argjson now "$(date +%s)" '.updatedAt = $now' <<<"$1" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -fT -- "$tmp" "$file"
}

owl_state_read() { cat -- "$(owl_state_file)" 2>/dev/null || echo '{}'; }

owl_state_get() { owl_state_read | jq -r --arg k "$1" '.[$k] // empty'; }

# Apply a jq filter to the state (e.g. '.keepAlive = false'). Arguments after
# the filter are passed through to jq (--arg / --argjson).
owl_state_patch() {
  local filter="$1"
  shift
  owl_state_write "$(owl_state_read | jq -c "$@" "$filter")"
}

# owl_state_stage <stage> <message> [error]
# Moves to a stage. Percentages never go backwards inside a mode; "failed"
# keeps the last percentage so the bar shows where it stopped.
owl_state_stage() {
  local stage="$1" message="${2:-}" error="${3:-}" mode pct prev
  [[ -v OWL_STAGE_PERCENT[$stage] ]] || { echo "owl_state_stage: unknown stage '$stage'" >&2; return 1; }
  case "$stage" in
  closing | stopping | releasing | stopped) mode=shutdown ;;
  failed | cancelled) mode=$(owl_state_get mode) ;;
  *) mode=launch ;;
  esac
  prev=$(owl_state_get percent)
  prev=${prev:-0}
  [[ $(owl_state_get mode) != "$mode" ]] && prev=0
  pct=${OWL_STAGE_PERCENT[$stage]}
  if ((pct < 0)); then pct=$prev; fi
  if ((pct < prev)); then pct=$prev; fi
  owl_state_patch '.stage = $s | .mode = $m | .percent = $p | .message = $msg | .error = $e' \
    --arg s "$stage" --arg m "$mode" --argjson p "$pct" --arg msg "$message" --arg e "$error"
}

# owl_state_progress <percent> [message]: refine progress inside the current
# stage (never backwards, never past 99 before "running"/"stopped").
owl_state_progress() {
  local pct="$1" message="${2-}" prev
  [[ $pct =~ ^[0-9]+$ ]] || return 1
  ((pct > 99)) && pct=99
  prev=$(owl_state_get percent)
  prev=${prev:-0}
  ((pct < prev)) && pct=$prev
  if [[ -n $message ]]; then
    owl_state_patch '.percent = $p | .message = $msg' --argjson p "$pct" --arg msg "$message"
  else
    owl_state_patch '.percent = $p' --argjson p "$pct"
  fi
}

# --- single-session lock (FR-015) -------------------------------------------

# Returns 0 and keeps the lock for the life of this process, or 1 if another
# session holds it. The lock is released automatically when the process dies.
owl_lock_acquire() {
  mkdir -p -- "$OWL_RUNTIME_DIR" && chmod 0700 -- "$OWL_RUNTIME_DIR" || return 1
  exec {OWL_LOCK_FD}>"$OWL_RUNTIME_DIR/session.lock" || return 1
  flock -n "$OWL_LOCK_FD" || { exec {OWL_LOCK_FD}>&-; return 1; }
}

owl_lock_release() {
  [[ -n ${OWL_LOCK_FD:-} ]] || return 0
  flock -u "$OWL_LOCK_FD" 2>/dev/null
  exec {OWL_LOCK_FD}>&-
  unset OWL_LOCK_FD
}
