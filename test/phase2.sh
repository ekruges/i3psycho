#!/usr/bin/env bash
# Phase 2 smoke test: the fork patches, headless under Xvfb.
# window::move events for floating repositions, titlebar buttons
# (close / iconify / maximize), double-click-titlebar fullscreen.
set -euo pipefail
cd "$(dirname "$0")/.."

ln -sf "$PWD/psychod/psychod.py" /usr/local/bin/psychod
ln -sf "$PWD/psychod/psychod-status" /usr/local/bin/psychod-status
chmod +x psychod/psychod.py psychod/psychod-status

pkill -f "bin/psychod" 2>/dev/null || true
export DISPLAY=:99
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB=$!
cleanup() { i3-msg exit >/dev/null 2>&1 || true; kill "$XVFB" 2>/dev/null || true; pkill -f "bin/psychod" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

i3 -C -c dist/psycho.config
i3 -c dist/psycho.config >/tmp/i3psycho-p2-log 2>&1 &
sleep 2

visible() {
  i3-msg -t get_tree | jq '[.nodes[] | select(.name != "__i3") | .. | objects | select(.type? == "floating_con")] | length'
}
rect() {
  i3-msg -t get_tree | jq -r --arg t "$1" \
    '[.nodes[] | select(.name != "__i3") | .. | objects
      | select(.type? == "floating_con")
      | select(any(recurse(.nodes[]?); .name? == $t)) | .rect]
     | first | "\(.x) \(.y) \(.width) \(.height)"'
}
fullscreen_of() {
  i3-msg -t get_tree | jq -r --arg t "$1" '.. | objects | select(.name? == $t) | .fullscreen_mode' | head -1
}
button_xy() {  # window title, button index (0 close, 1 iconify, 2 maximize) -> "x y"
  i3-msg -t get_tree | jq -r --arg t "$1" --argjson i "$2" \
    '.. | objects | select(.type? == "floating_con")
     | select(any(recurse(.nodes[]?); .name? == $t))
     | (.nodes[0].deco_rect) as $d
     | "\(.rect.x + $d.x + ($i * $d.height) + ($d.height / 2 | floor)) \(.rect.y + $d.y + ($d.height / 2 | floor))"' | head -1
}

echo "--- 1. floating repositions now emit window::move (fork patch)"
xterm -T alpha & sleep 1.5
python3 - <<'EOF'
from i3ipc import Connection, Event
import threading, subprocess, time, sys
hits = []
c = Connection()
c.on(Event.WINDOW_MOVE, lambda conn, e: hits.append(e.container.id))
threading.Thread(target=c.main, daemon=True).start()
time.sleep(0.5)
subprocess.run(["i3-msg", "-q", '[title="alpha"] move position 300 px 200 px'])
time.sleep(0.8)
print(f"move events received: {len(hits)} (want >= 1)")
sys.exit(0 if hits else 1)
EOF

echo "--- 2. maximize button (+) toggles fullscreen"
read -r BX BY <<<"$(button_xy alpha 2)"
xdotool mousemove "$BX" "$BY" click 1; sleep 0.6
FS=$(fullscreen_of alpha)
echo "fullscreen_mode after + click: $FS (want 1)"
[ "$FS" = "1" ]
i3-msg -q '[title="alpha"] fullscreen disable'; sleep 0.5

echo "--- 3. iconify button (−) scratchpads, restore returns in place"
sleep 0.7   # let the poller record the current rect
BEFORE=$(rect alpha)
read -r BX BY <<<"$(button_xy alpha 1)"
xdotool mousemove "$BX" "$BY" click 1; sleep 1.0
V=$(visible); echo "after iconify: $V visible (want 0)"; [ "$V" -eq 0 ]
i3-msg -t send_tick psycho:restore >/dev/null; sleep 0.8
AFTER=$(rect alpha)
echo "rect $BEFORE -> $AFTER"
[ "$BEFORE" = "$AFTER" ]

echo "--- 4. double-click titlebar toggles fullscreen"
read -r BX BY <<<"$(button_xy alpha 2)"
TX=$((BX + 80))
xdotool mousemove "$TX" "$BY" click --repeat 2 --delay 150 1; sleep 0.6
FS=$(fullscreen_of alpha)
echo "fullscreen_mode after double-click: $FS (want 1)"
[ "$FS" = "1" ]
i3-msg -q '[title="alpha"] fullscreen disable'; sleep 0.5

echo "--- 5. close button (×) kills the window"
xterm -T beta & sleep 1.2   # second window so the shot is interesting
i3-msg -q '[title="alpha"] focus'; sleep 0.4   # raise alpha above beta
read -r BX BY <<<"$(button_xy alpha 0)"
scrot /tmp/i3psycho-p2-buttons.png
xdotool mousemove "$BX" "$BY" click 1; sleep 1.0
LEFT=$(i3-msg -t get_tree | jq '[.. | objects | select(.name? == "alpha")] | length')
echo "alpha windows left: $LEFT (want 0)"
[ "$LEFT" -eq 0 ]

echo PASS
