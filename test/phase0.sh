#!/usr/bin/env bash
# Phase 0 smoke test: floating-by-default + snapping, headless under Xvfb.
# Run from repo root inside the build CT. Screenshots land in /tmp/i3psycho-*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

export DISPLAY=:99
Xvfb :99 -screen 0 1280x800x24 &
XVFB=$!
cleanup() { i3-msg exit >/dev/null 2>&1 || true; kill "$XVFB" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

i3 -C -c dist/psycho.config          # validate config before running it
i3 -c dist/psycho.config >/tmp/i3psycho-log 2>&1 &
sleep 1.5

xterm -T alpha & xterm -T beta & xterm -T gamma &
sleep 1.5

# floating_cons outside the __i3 scratch output = visible floaters
count_visible() {
  i3-msg -t get_tree | jq '[.nodes[] | select(.name != "__i3") | .. | objects | select(.type? == "floating_con")] | length'
}

floating=$(count_visible)
echo "floating containers: $floating (want 3)"
[ "$floating" -eq 3 ]
scrot /tmp/i3psycho-floating.png

# snap alpha to left half, beta to bottom-right quarter
i3-msg '[title="alpha"] resize set 50 ppt 100 ppt, move position 0 ppt 0 ppt' >/dev/null
i3-msg '[title="beta"] resize set 50 ppt 50 ppt, move position 50 ppt 50 ppt' >/dev/null
sleep 0.5
i3-msg -t get_tree | jq -r '.nodes[] | select(.name != "__i3") | .. | objects | select(.type? == "floating_con") | .rect | "rect \(.x),\(.y) \(.width)x\(.height)"'
scrot /tmp/i3psycho-snapped.png

# minimize = scratchpad: hide gamma, visible count drops to 2
i3-msg '[title="gamma"] move scratchpad' >/dev/null
sleep 0.5
visible=$(count_visible)
echo "after minimize: $visible visible (want 2)"
[ "$visible" -eq 2 ]
scrot /tmp/i3psycho-minimized.png

echo PASS
