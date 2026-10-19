#!/bin/bash
# Plan D6: real boot-progress signals (startup messages, guest curve, RDP handshake).
cd "$(dirname "$0")/.." || exit 1
source tests/lib.sh
source lib/boot.sh

echo "message → progress"
assert_eq "known steps map in the order the container runs them" "8 14 20 26 34 38" \
  "$(for m in 'Starting Windows for Docker' 'Initializing disks' 'Configuring display drivers' 'Initializing network' 'Configuring boot' 'Configuring QEMU'; do owl_boot_percent_for_message "$m"; done | paste -sd' ')"
assert_eq "the steps are strictly increasing" "yes" \
  "$(prev=0; ok=yes; for m in 'Starting Windows for Docker' 'Initializing disks' 'Configuring display drivers' 'Initializing network' 'Configuring boot' 'Configuring QEMU'; do p=$(owl_boot_percent_for_message "$m"); ((p > prev)) || ok=no; prev=$p; done; echo $ok)"
assert_eq "a download percentage is spread over the first part of the range" "23 38" \
  "$(owl_boot_percent_for_message 'Downloading Windows (50%)') $(owl_boot_percent_for_message 'Downloading Windows (100.0%)')"
assert_eq "an unknown message gives no progress (keep the current one)" "" "$(owl_boot_percent_for_message 'Something new')"
assert_eq "matching is case-insensitive" "26" "$(owl_boot_percent_for_message 'INITIALIZING NETWORK')"

echo "message cleaning"
assert_eq "the loading wrapper is stripped" "Initializing network" \
  "$(printf '<p class="loading">Initializing network</p>\n' | owl_boot_clean_message)"
assert_eq "entities are decoded and whitespace collapsed" "A & B <c> d" \
  "$(printf 'A &amp; B   &lt;c&gt;\n d' | owl_boot_clean_message)"

echo "guest boot curve"
assert_eq "starts at 45, then 67 after 25 s" "45 67" "$(owl_boot_guest_percent 0) $(owl_boot_guest_percent 25)"
assert_eq "never reaches the end on its own" "yes" "$( ((  $(owl_boot_guest_percent 100000) < 91 )) && echo yes || echo no)"
assert_eq "never goes backwards" "yes" \
  "$(prev=0; ok=yes; for t in 0 1 2 5 10 20 40 80 160 320; do p=$(owl_boot_guest_percent $t); ((p >= prev)) || ok=no; prev=$p; done; echo $ok)"
assert_eq "a negative time is treated as zero" "45" "$(owl_boot_guest_percent -5)"

echo "web endpoint"
if command -v python3 >/dev/null; then
  W=$(mktemp -d); PORT=$((RANDOM % 2000 + 41000))
  export OWL_WEB_BASE="http://127.0.0.1:$PORT" OWL_CREDENTIALS_FILE="$W/none"
  python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$W" >/dev/null 2>&1 &
  srv=$!; sleep 0.8
  printf '<p class="loading">Initializing network</p>' > "$W/msg.html"
  assert_eq "a published step is read and cleaned" "ok Initializing network" "$(owl_boot_message)"
  rm -f "$W/msg.html"
  assert_eq "a missing file (404) means QEMU is up" "gone" "$(owl_boot_message)"
  printf 'USERNAME=charlie\nPASSWORD=s3cr"et$x\n' > "$W/creds"; chmod 600 "$W/creds"
  printf 'Configuring boot' > "$W/msg.html"
  export OWL_CREDENTIALS_FILE="$W/creds"
  out=$(owl_boot_message)
  assert_eq "works with credentials configured" "ok Configuring boot" "$out"
  assert_eq "the password never shows up in the output" "no" "$([[ $out == *s3cr* ]] && echo yes || echo no)"
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  assert_eq "no server at all is 'unavailable', not an error" "unavailable" "$(owl_boot_message)"
  rm -rf "$W"
else
  echo "  skip (python3 not found)"
fi

echo "RDP handshake"
if command -v nc >/dev/null; then
  P=$((RANDOM % 2000 + 43000)); export OWL_RDP_PORT=$P
  # A guest that answers like RDP: TPKT header, then an X.224 connection confirm.
  (printf '\x03\x00\x00\x0b\x06\xd0\x00\x00\x12\x34\x00' | nc -l 127.0.0.1 "$P" >/dev/null 2>&1) &
  sleep 0.5
  owl_probe_rdp; assert_eq "a host that answers with a TPKT header is ready" "0" "$?"
  wait 2>/dev/null
  # A port that Docker maps while the guest is still down: accepts, then closes without a word.
  P=$((P + 1)); export OWL_RDP_PORT=$P
  (: | nc -l 127.0.0.1 "$P" >/dev/null 2>&1) &
  sleep 0.5
  owl_probe_rdp; assert_eq "accepting the connection without answering is not ready" "1" "$?"
  wait 2>/dev/null
  export OWL_RDP_PORT=$((P + 1))
  owl_probe_rdp; assert_eq "a closed port is not ready" "1" "$?"
else
  echo "  skip (nc not found)"
fi

finish
