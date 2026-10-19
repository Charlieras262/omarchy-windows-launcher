#!/bin/bash
# Window geometry for "use all monitors" (spec US3, FR-004). Instead of asking
# FreeRDP for a multi-monitor session, the Windows window is made floating and
# stretched across every monitor: Hyprland lets a floating window straddle
# outputs, and /dynamic-resolution resizes the remote desktop to match.
#
# Sourced; no side effects at source time. Requires jq.

# Bounding box shared by all monitors, as "x y width height" in layout pixels:
# from the left edge of the leftmost monitor to the right edge of the rightmost,
# top-aligned, as tall as the shortest monitor so no part hangs off a screen.
# Stdin: `hyprctl monitors -j`. Rotated monitors (odd transform) swap width/height;
# scale divides to logical pixels.
owl_span_geometry() {
  jq -r '
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
        | (map(.h) | min) as $h
        | "\($x0 | floor) \($y0 | floor) \(($x1 - $x0) | floor) \($h | floor)"
      end'
}
