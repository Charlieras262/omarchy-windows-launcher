#!/bin/bash
# Window geometry for "use all monitors" (spec US3, FR-004). Instead of asking
# FreeRDP for a multi-monitor session, the Windows window is made floating and
# stretched across every monitor: Hyprland lets a floating window straddle
# outputs, and /dynamic-resolution resizes the remote desktop to match.
#
# Sourced; no side effects at source time. Requires jq.

# Bounding box of all monitors, as "x y width height" in layout pixels: from the left edge
# of the leftmost monitor to the right edge of the rightmost, top-aligned. This is also the
# canvas FreeRDP's multi-monitor session paints (every monitor is part of one remote
# desktop), so the window must cover the whole box; parts beyond a shorter monitor are
# simply outside the screens. Argument "min" instead limits the height to the shortest
# monitor. Stdin: `hyprctl monitors -j`. Rotated monitors (odd transform) swap
# width/height; scale divides to logical pixels.
owl_span_geometry() {
  local mode="${1:-max}"
  jq -r --arg mode "$mode" '
    def logical:
      (.scale // 1) as $s
      | (if (.transform % 2) == 1 then {w: .height, h: .width} else {w: .width, h: .height} end)
      | {w: (.w / $s), h: (.h / $s)};
    [ .[] | select(.disabled | not)
      | . as $m | ($m | logical) as $l
      | {x: $m.x, y: $m.y, w: $l.w, h: $l.h} ]
    | if length == 0 then empty else
        (map(.x) | min) as $x0
        | (map(.y) | min) as $y0
        | (map(.x + .w) | max) as $x1
        | (if $mode == "min" then (map(.h) | min) else (map(.y + .h) | max) - $y0 end) as $h
        | "\($x0 | floor) \($y0 | floor) \(($x1 - $x0) | floor) \($h | floor)"
      end'
}
