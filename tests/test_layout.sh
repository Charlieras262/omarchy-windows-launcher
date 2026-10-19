#!/bin/bash
# Spec US3: geometry of the floating window spanning all monitors.
cd "$(dirname "$0")/.." || exit 1
source tests/lib.sh
source lib/layout.sh

echo "span geometry"
assert_eq "this machine: portrait left + ultrawide right → 4880x1440 from the top-left" \
  "0 0 4880 1440" "$(owl_span_geometry < tests/fixtures/monitors-two.json)"
assert_eq "one monitor: just that monitor, at its own origin" \
  "1440 0 3440 1440" "$(owl_span_geometry < tests/fixtures/monitors-one.json)"
assert_eq "scale divides to logical pixels, disabled outputs are ignored" \
  "0 0 3904 1152" "$(owl_span_geometry < tests/fixtures/monitors-scaled.json)"
assert_eq "no monitors gives nothing instead of garbage" "" "$(echo '[]' | owl_span_geometry)"

finish
