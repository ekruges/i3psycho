#!/usr/bin/env bash
# Phase 1 smoke test: psychod features, headless under Xvfb.
# cascade, exact snap, minimize/restore geometry, showdesktop, mru, drop-snap,
# statusline dock. Screenshots in /tmp/i3psycho-p1-*.png.
set -euo pipefail
cd "$(dirname "$0")/.."

ln -sf "$PWD/psychod/psychod.py" /usr/local/bin/psychod
chmod +x psychod/psychod.py

pkill -f "bin/psychod" 2>/dev/null || true
export DISPLAY=:99
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB=$!
cleanup() { i3-msg exit >/dev/null 2>&1 || true; kill "$XVFB" 2>/dev/null || true; pkill -f "bin/psychod" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

i3 -C -c dist/psycho.config
i3 -c dist/psycho.config >/tmp/i3psycho-p1-log 2>&1 &
sleep 2

xterm -T alpha & sleep 0.4; xterm -T beta & sleep 0.4; xterm -T gamma &
sleep 1.5

tick() { i3-msg -t send_tick "$1" >/dev/null; sleep 0.5; }

rect() {  # outer rect of the floating container holding window titled $1
  i3-msg -t get_tree | jq -r --arg t "$1" \
    '[.nodes[] | select(.name != "__i3") | .. | objects
      | select(.type? == "floating_con")
      | select(any(recurse(.nodes[]?); .name? == $t)) | .rect]
     | first | "\(.x) \(.y) \(.width) \(.height)"'
}

visible() {
  i3-msg -t get_tree | jq '[.nodes[] | select(.name != "__i3") | .. | objects | select(.type? == "floating_con")] | length'
}

close_to() {  # close_to "x y w h" "x y w h" tolerance
  python3 -c '
import sys
a = [int(v) for v in sys.argv[1].split()]
b = [int(v) for v in sys.argv[2].split()]
tol = int(sys.argv[3])
sys.exit(0 if all(abs(x - y) <= tol for x, y in zip(a, b)) else 1)' "$1" "$2" "$3"
}

WA=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused) | .rect | "\(.x) \(.y) \(.width) \(.height)"')
read -r WX WY WW WH <<<"$WA"
echo "workarea: $WA"

echo "--- 1. cascade: three windows, three distinct positions"
XS=$(i3-msg -t get_tree | jq '[.nodes[] | select(.name != "__i3") | .. | objects | select(.type? == "floating_con") | .rect.x] | unique | length')
echo "distinct x positions: $XS (want 3)"
[ "$XS" -eq 3 ]
scrot /tmp/i3psycho-p1-cascade.png

echo "--- 2. exact snap left (focused window)"
tick psycho:snap:left
GOT=$(rect gamma)
WANT="$WX $WY $((WW / 2)) $WH"
echo "got: $GOT  want: $WANT (size-hint rounding tolerated)"
close_to "$GOT" "$WANT" 16

echo "--- 3. minimize / restore with geometry"
i3-msg '[title="beta"] focus' >/dev/null; sleep 0.3
BEFORE=$(rect beta)
tick psycho:min
V=$(visible); echo "after minimize: $V visible (want 2)"; [ "$V" -eq 2 ]
scrot /tmp/i3psycho-p1-minimized.png
tick psycho:restore
AFTER=$(rect beta)
V=$(visible); echo "after restore: $V visible (want 3), rect $BEFORE -> $AFTER"
[ "$V" -eq 3 ]
close_to "$BEFORE" "$AFTER" 1

echo "--- 4. show desktop toggle"
tick psycho:showdesktop
V=$(visible); echo "desktop shown: $V visible (want 0)"; [ "$V" -eq 0 ]
tick psycho:showdesktop
sleep 0.5
V=$(visible); echo "windows back: $V visible (want 3)"; [ "$V" -eq 3 ]

echo "--- 5. mru toggle"
i3-msg '[title="alpha"] focus' >/dev/null; sleep 0.3
i3-msg '[title="beta"] focus' >/dev/null; sleep 0.3
tick psycho:mru
F=$(i3-msg -t get_tree | jq -r '.. | objects | select(.focused? == true) | .name')
echo "focused after mru: $F (want alpha)"
[ "$F" = "alpha" ]

echo "--- 6. drop-snap: drag beyond left edge -> left half"
i3-msg '[title="alpha"] move absolute position -80 px 300 px' >/dev/null
sleep 1.2
GOT=$(rect alpha)
echo "got: $GOT  want: $WANT (size-hint rounding tolerated)"
close_to "$GOT" "$WANT" 16

echo "--- 7. native bar chips: list, render, click to restore"
i3-msg '[title="gamma"] focus' >/dev/null; sleep 0.3
BEFORE_CHIP=$(rect gamma)
tick psycho:min
sleep 1.0
SOCK=$(i3 --get-socketpath) python3 - <<'PYEOF2'
import socket, struct, os, json, sys
s = socket.socket(socket.AF_UNIX); s.connect(os.environ["SOCK"])
s.sendall(b"i3-ipc" + struct.pack("<II", 0, 13))
hdr = s.recv(14); ln, rt = struct.unpack("<II", hdr[6:])
items = json.loads(s.recv(ln))
assert any(i["name"] == "gamma" for i in items), items
print("GET_SCRATCHPAD lists gamma:", items)
PYEOF2
scrot /tmp/i3psycho-p1-dock.png
xdotool mousemove 45 789 click 1
sleep 1.2
AFTER_CHIP=$(rect gamma)
echo "chip click restore: $BEFORE_CHIP -> $AFTER_CHIP"
[ "$BEFORE_CHIP" = "$AFTER_CHIP" ]

echo PASS
