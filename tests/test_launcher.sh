#!/bin/bash
# Orchestrator behaviour against fake omarchy commands (no real VM, no shell).
cd "$(dirname "$0")/.." || exit 1
source tests/lib.sh
ROOT=$PWD
ORIG_PATH=$PATH

setup() {
  T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/realbin" "$T/run"
  : >"$T/calls"
  cat >"$T/bin/omarchy-shell" <<FAKE
#!/bin/bash
echo "shell \$*" >> "$T/calls"
[[ -n \${FAKE_NO_SHELL:-} ]] && exit 1
if [[ \$1 == shell && \$2 == summon ]]; then
  af=\$(jq -r '.answersFile // empty' <<<"\$4")
  [[ -n \$af && -n \${TEST_ANSWER:-} ]] && printf '%s\n' "\$TEST_ANSWER" > "\$af"
fi
exit 0
FAKE
  cat >"$T/bin/omarchy-windows-vm" <<FAKE
#!/bin/bash
echo "vm \$*" >> "$T/calls"
case "\$1" in
  launch)
    echo "Starting Windows VM..."
    [[ -n \${FAKE_VM_FAIL:-} ]] && { echo "Failed to start Windows VM!"; exit 1; }
    sleep 0.5
    xfreerdp3 /u:x /v:127.0.0.1
    sleep "\${FAKE_VM_HOLD:-0}"
    exit 0 ;;
  stop) [[ -n \${FAKE_STOP_FAIL:-} ]] && exit 1; echo stopped; exit 0 ;;
esac
FAKE
  cat >"$T/realbin/xfreerdp3" <<FAKE
#!/bin/bash
echo "rdp \$*" >> "$T/calls"
FAKE
  cat >"$T/bin/hyprctl" <<FAKE
#!/bin/bash
case "\$1" in
  monitors) cat "$ROOT/tests/fixtures/monitors-two.json" ;;
  clients)
    pid=\$(cat "$T/run/rdp-started" 2>/dev/null); pid=\${pid:-0}
    n=\$(grep -c 'window.resize' "$T/calls" 2>/dev/null); n=\${n:-0}
    # The X11 client keeps resetting its size until we have asserted it twice.
    if (( n >= \${FAKE_STICK_AFTER:-1} )); then sz='[4880,2560]'; at='[0,0]'; else sz='[800,600]'; at='[300,200]'; fi
    # The /f client starts fullscreen and tiled; it only changes when we ask.
    fs=2; grep -q 'action = "unset"' "$T/calls" 2>/dev/null && fs=0
    fl=false; grep -q 'window.float' "$T/calls" 2>/dev/null && fl=true
    jq -n --argjson pid "\$pid" --argjson sz "\$sz" --argjson at "\$at" --argjson fs "\$fs" --argjson fl "\$fl" '[
      {address:"0xmain",  pid:\$pid, title:"Windows VM - Omarchy", workspace:{id:4}, size:\$sz, at:\$at, floating:\$fl, fullscreen:\$fs},
      {address:"0xpopup", pid:\$pid, title:"FreeRDP: dialog",      workspace:{id:1}, size:[300,200], at:[10,10], floating:true, fullscreen:0},
      {address:"0xother", pid:1,     title:"Terminal",              workspace:{id:1}, size:[1,1], at:[0,0], floating:false, fullscreen:0}]' ;;
  dispatch) echo "dsp \$2" >> "$T/calls" ;;
esac
FAKE
  mkdir -p "$T/toggles"
  cat >"$T/bin/bar" <<FAKE
#!/bin/bash
echo "bar \$*" >> "$T/calls"
case "\$1" in on) touch "$T/toggles/bar-off" ;; off) rm -f "$T/toggles/bar-off" ;; esac
FAKE
  printf '#!/bin/bash\necho "notify $*" >> "%s/calls"\n' "$T" >"$T/bin/notify"
  chmod +x "$T"/bin/* "$T"/realbin/*
  # Never let a test reach the real FreeRDP client (the user may have a VM running).
  export PATH="$T/realbin:$ORIG_PATH"
  export OWL_RUNTIME_DIR="$T/run" OWL_SHELL_CMD="$T/bin/omarchy-shell" OWL_VM_CMD="$T/bin/omarchy-windows-vm" \
         OWL_BAR_CMD="$T/bin/bar" OWL_NOTIFY_CMD="$T/bin/notify" OWL_REAL_PATH="$T/realbin:$PATH" \
         OWL_TOGGLES_DIR="$T/toggles" OWL_HYPRCTL="$T/bin/hyprctl" OWL_WATCH=0.1 OWL_LAUNCH_CMD_FILE="$T/none" OWL_TICK=0.2 OWL_LSBLK_JSON="$ROOT/tests/fixtures/this-machine.json" OWL_PROTECTED_DISKS=""
  unset FAKE_NO_SHELL FAKE_VM_FAIL FAKE_STOP_FAIL FAKE_VM_HOLD TEST_ANSWER
}
teardown() { rm -rf "$T"; }
calls() { cat "$T/calls"; }
has() { calls | grep -qE -- "$1"; }
run() { timeout 20 bin/omarchy-windows-launcher >"$T/out" 2>&1; echo $?; }

echo "cancel"
setup
export TEST_ANSWER='{"action":"cancel","closeOnExit":true,"allMonitors":false,"disks":[]}'
assert_eq "cancel exits 0" "0" "$(run)"
assert_eq "cancel never starts the VM" "no" "$(has '^vm ' && echo yes || echo no)"
assert_eq "cancel never touches the bar" "no" "$(has '^bar ' && echo yes || echo no)"
assert_eq "cancel leaves the state cancelled" "cancelled" "$(jq -r .stage "$T/run/state.json")"
teardown

echo "start, close on exit (default)"
setup
export TEST_ANSWER='{"action":"start","closeOnExit":true,"allMonitors":false,"disks":[]}'
assert_eq "exits 0" "0" "$(run)"
assert_eq "launches with --keep-alive so the stop decision is ours" "yes" "$(has '^vm launch --keep-alive' && echo yes || echo no)"
assert_eq "stops the VM afterwards" "yes" "$(has '^vm stop' && echo yes || echo no)"
assert_eq "RDP gets no extra flags" "no" "$(has 'multimon' && echo yes || echo no)"
assert_eq "bar is not touched without all-monitors" "no" "$(has '^bar ' && echo yes || echo no)"
assert_eq "final state is stopped at 100%" "stopped 100" "$(jq -r '"\(.stage) \(.percent)"' "$T/run/state.json")"
assert_eq "dialog was summoned before the progress window" "dialog progress" \
  "$(calls | grep -o 'summon [^ ]* {"view":"[a-z]*"' | grep -o '"view":"[a-z]*"' | cut -d'"' -f4 | uniq | head -2 | tr '\n' ' ' | sed 's/ $//')"
teardown

echo "start, keep running"
setup
export TEST_ANSWER='{"action":"start","closeOnExit":false,"allMonitors":false,"disks":[]}'
assert_eq "exits 0" "0" "$(run)"
assert_eq "does not stop the VM" "no" "$(has '^vm stop' && echo yes || echo no)"
assert_eq "tells the user it is still running" "yes" "$(has '^notify Windows VM Still running' && echo yes || echo no)"
assert_eq "state ends at running" "running" "$(jq -r .stage "$T/run/state.json")"
teardown

echo "all monitors"
setup
export TEST_ANSWER='{"action":"start","closeOnExit":true,"allMonitors":true,"disks":[]}'
assert_eq "exits 0" "0" "$(run)"
assert_eq "RDP is told about all the monitors so the remote desktop is one canvas" "yes" "$(has '^rdp .*/multimon:force /f' && echo yes || echo no)"
assert_eq "the bar flag is set while the session runs and cleared after (bar visible again)" "no" "$([[ -f $T/toggles/bar-off ]] && echo yes || echo no)"
assert_eq "bar is hidden then restored, in that order" "bar on|bar off" "$(calls | grep '^bar ' | paste -sd'|')"
assert_eq "bar flag is cleared in the state" "false" "$(jq -r .hidBar "$T/run/state.json")"
teardown

echo "window placement"
setup
export FAKE_VM_HOLD=2.5 FAKE_STICK_AFTER=2 TEST_ANSWER='{"action":"start","closeOnExit":true,"allMonitors":true,"disks":[]}'
assert_eq "exits 0" "0" "$(run)"
assert_eq "geometry is re-asserted when the client resets it" "yes" "$( (( $(calls | grep -c window.resize) >= 2 )) && echo yes || echo no)"
assert_eq "...and stops once the window holds the target (no endless fighting)" "yes" "$( (( $(calls | grep -c 'window.resize') <= 4 )) && echo yes || echo no)"
assert_eq "placement log records the target box" "yes" "$(grep -q 'target box: 0 0 4880 2560' "$T/run/placement.log" && echo yes || echo no)"
assert_eq "placement log records that it settled" "yes" "$(grep -q settled "$T/run/placement.log" && echo yes || echo no)"
assert_eq "the fullscreen state requested by /f is lifted before floating" "yes" "$(has 'dsp hl.dsp.window.fullscreen\(\{ mode = "fullscreen", action = "unset", window = "address:0xmain"' && echo yes || echo no)"
assert_eq "fullscreen is lifted first, then float, resize, move" "fullscreen float resize move" \
  "$(calls | grep '^dsp' | grep 0xmain | head -4 | grep -oE 'window\.(fullscreen|float|resize|move)' | sed 's/window\.//' | paste -sd' ')"
assert_eq "main window is made floating" "yes" "$(has 'dsp hl.dsp.window.float\(\{ action = "enable", window = "address:0xmain"' && echo yes || echo no)"
assert_eq "main window covers the whole 4880x2560 canvas" "yes" "$(has 'dsp hl.dsp.window.resize\(\{ x = 4880, y = 2560, window = "address:0xmain"' && echo yes || echo no)"
assert_eq "main window is moved to the top-left of the leftmost monitor" "yes" "$(has 'dsp hl.dsp.window.move\(\{ x = 0, y = 0, window = "address:0xmain"' && echo yes || echo no)"
assert_eq "a popup of the RDP client follows the main window to workspace 4" "yes" "$(has 'dsp hl.dsp.window.move\(\{ workspace = "4", follow = false, window = "address:0xpopup"' && echo yes || echo no)"
assert_eq "windows of other processes are never touched" "no" "$(has '0xother' && echo yes || echo no)"
assert_eq "the main window is not moved to a workspace (the user's own rule decides)" "no" "$(has 'workspace = "[0-9]*", follow = false, window = "address:0xmain"' && echo yes || echo no)"
teardown

setup
export FAKE_VM_HOLD=1.5 TEST_ANSWER='{"action":"start","closeOnExit":true,"allMonitors":false,"disks":[]}'
assert_eq "exits 0" "0" "$(run)"
assert_eq "single-monitor mode never floats or resizes the main window" "no" "$(has 'window.(float|resize)' && echo yes || echo no)"
assert_eq "popups still follow the main window in single-monitor mode" "yes" "$(has 'address:0xpopup' && echo yes || echo no)"
teardown

echo "bar already hidden"
setup
touch "$T/toggles/bar-off"
export TEST_ANSWER='{"action":"start","closeOnExit":true,"allMonitors":true,"disks":[]}'
assert_eq "exits 0" "0" "$(run)"
assert_eq "a bar the user had already hidden is not touched" "no" "$(has '^bar ' && echo yes || echo no)"
assert_eq "...and is still hidden afterwards" "yes" "$([[ -f $T/toggles/bar-off ]] && echo yes || echo no)"
teardown

echo "failures"
setup
export TEST_ANSWER='{"action":"start","closeOnExit":true,"allMonitors":true,"disks":[]}' FAKE_VM_FAIL=1
assert_eq "failed launch exits non-zero" "1" "$(run)"
assert_eq "state is failed with the reason" "failed|Failed to start Windows VM!" "$(jq -r '"\(.stage)|\(.error)"' "$T/run/state.json")"
assert_eq "bar is restored after a failed launch" "bar on|bar off" "$(calls | grep '^bar ' | paste -sd'|')"
assert_eq "a failed launch does not call stop" "no" "$(has '^vm stop' && echo yes || echo no)"
teardown

setup
export TEST_ANSWER='{"action":"start","closeOnExit":true,"allMonitors":false,"disks":[]}' FAKE_STOP_FAIL=1
assert_eq "a failed stop is reported" "1" "$(run)"
assert_eq "state says the VM could not be stopped" "failed" "$(jq -r .stage "$T/run/state.json")"
teardown

echo "user launch wrapper"
setup
cat >"$T/bin/my-wrapper" <<WRAP
#!/bin/bash
echo "wrapper \$*" >> "$T/calls"
exec "$T/bin/omarchy-windows-vm" launch "\$@"
WRAP
chmod +x "$T/bin/my-wrapper"
echo "$T/bin/my-wrapper" > "$T/launch-cmd"
export OWL_LAUNCH_CMD_FILE="$T/launch-cmd" TEST_ANSWER='{"action":"start","closeOnExit":true,"allMonitors":false,"disks":[]}'
assert_eq "exits 0" "0" "$(run)"
assert_eq "the user's wrapper is used, with --keep-alive" "yes" "$(has '^wrapper --keep-alive' && echo yes || echo no)"
assert_eq "stop still goes to the stock command" "yes" "$(has '^vm stop' && echo yes || echo no)"
teardown
unset OWL_LAUNCH_CMD_FILE

echo "environment"
setup
export FAKE_NO_SHELL=1
assert_eq "without the shell it falls back to the stock launcher" "0" "$(run)"
assert_eq "stock launcher is called without our flags" "vm launch" "$(calls | grep '^vm ' | head -1)"
teardown

setup
export TEST_ANSWER='{"action":"cancel"}'
( source lib/state.sh; export OWL_RUNTIME_DIR="$T/run"; owl_lock_acquire; sleep 4 ) &
holder=$!
sleep 0.5
assert_eq "a second launch while one is active exits cleanly" "0" "$(run)"
assert_eq "...without asking the dialog again" "no" "$(has 'view":"dialog' && echo yes || echo no)"
assert_eq "...and brings the progress window forward" "yes" "$(has 'view":"progress' && echo yes || echo no)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
teardown

finish
