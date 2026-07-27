#!/usr/bin/env bash
# Phase 3 smoke test: QoL layer. Expose grid, MRU cycle, native drag-snap with
# preview (fork patch 3), hot corners, multi-output snapping via fake-outputs.
set -euo pipefail
cd "$(dirname "$0")/.."

ln -sf "$PWD/psychod/psychod.py" /usr/local/bin/psychod
ln -sf "$PWD/psychod/psychod-status" /usr/local/bin/psychod-status
chmod +x psychod/psychod.py psychod/psychod-status

pkill -f "bin/psychod" 2>/dev/null || true
export DISPLAY=:99
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB=$!
cleanup() {
  DISPLAY=:98 i3-msg exit >/dev/null 2>&1 || true
  i3-msg exit >/dev/null 2>&1 || true
  kill "$XVFB" 2>/dev/null || true
  pkill -f "Xvfb :98" 2>/dev/null || true
  pkill -f "bin/psychod" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

i3 -C -c dist/psycho.config
i3 -c dist/psycho.config >/tmp/i3psycho-p3-log 2>&1 &
sleep 2

tick() { i3-msg -t send_tick "$1" >/dev/null; sleep 0.6; }
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
all_rects() {
  for t in alpha beta gamma; do rect "$t"; done
}
focused_name() {
  i3-msg -t get_tree | jq -r '.. | objects | select(.focused? == true) | .name'
}

xterm -T alpha & sleep 0.4; xterm -T beta & sleep 0.4; xterm -T gamma &
sleep 1.5

echo "--- 1. expose: grid arrange, then restore"
BEFORE=$(all_rects)
tick psycho:expose
sleep 0.6
GRID=$(all_rects)
echo "$GRID" | python3 -c '
import sys
rects = [tuple(map(int, ln.split())) for ln in sys.stdin if ln.strip()]
assert len(rects) == 3, rects
def overlap(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
for i in range(3):
    for j in range(i + 1, 3):
        assert not overlap(rects[i], rects[j]), (rects[i], rects[j])
    x, y, w, h = rects[i]
    assert x >= 0 and y >= 0 and x + w <= 1280 and y + h <= 777, rects[i]
print("grid: 3 non-overlapping rects inside the workarea")'
scrot /tmp/i3psycho-p3-expose.png
tick psycho:expose
sleep 0.8
AFTER=$(all_rects)
[ "$BEFORE" = "$AFTER" ] && echo "restore: all rects identical"

echo "--- 2. mru cycle walks the stack"
i3-msg -q '[title="alpha"] focus'; sleep 0.3
i3-msg -q '[title="beta"] focus'; sleep 0.3
i3-msg -q '[title="gamma"] focus'; sleep 0.3
tick psycho:cycle
F1=$(focused_name)
tick psycho:cycle
F2=$(focused_name)
echo "cycle: gamma -> $F1 -> $F2 (want beta, alpha)"
[ "$F1" = "beta" ] && [ "$F2" = "alpha" ]

echo "--- 3. native drag to edge: preview + exact snap (fork)"
i3-msg -q '[title="gamma"] focus'; sleep 0.3
read -r GX GY GW GH <<<"$(rect gamma)"
TX=$((GX + GW / 2)); TY=$((GY + 9))
xdotool mousemove "$TX" "$TY" mousedown 1
xdotool mousemove --sync $((TX - 60)) 400; sleep 0.2
xdotool mousemove --sync 5 400; sleep 0.4
scrot /tmp/i3psycho-p3-preview.png
xdotool mouseup 1; sleep 0.8
GOT=$(rect gamma)
echo "after drop: $GOT (want 0 0 640 777 exact)"
[ "$GOT" = "0 0 640 777" ]

echo "--- 4. hot corner br = show desktop"
xdotool mousemove 1279 799; sleep 3.0
V=$(visible); echo "after corner dwell: $V visible (want 0)"; [ "$V" -eq 0 ]
xdotool mousemove 640 400; sleep 0.5
xdotool mousemove 1279 799; sleep 3.0
V=$(visible); echo "after second dwell: $V visible (want 3)"; [ "$V" -eq 3 ]
xdotool mousemove 640 400

echo "--- 5. multi-output: fake-outputs cascade + snap on second output"
cat dist/psycho.config > /tmp/fo.config
echo "fake-outputs 640x800+0+0,640x800+640+0" >> /tmp/fo.config
Xvfb :98 -screen 0 1280x800x24 >/dev/null 2>&1 &
sleep 1
DISPLAY=:98 i3 -c /tmp/fo.config >/tmp/i3psycho-p3-fo-log 2>&1 &
sleep 2
DISPLAY=:98 i3-msg -q 'workspace number 1'; sleep 0.3   # Xvfb pointer starts at center = output 2
DISPLAY=:98 xterm -T one & sleep 1.2
DISPLAY=:98 i3-msg -q 'workspace number 2'; sleep 0.4
DISPLAY=:98 xterm -T two & sleep 1.2
R2=$(DISPLAY=:98 i3-msg -t get_tree | jq -r '[.. | objects | select(.type? == "floating_con") | select(any(recurse(.nodes[]?); .name? == "two")) | .rect] | first | "\(.x) \(.y) \(.width) \(.height)"')
read -r X2 _ _ _ <<<"$R2"
echo "second-output cascade rect: $R2 (want x >= 640)"
[ "$X2" -ge 640 ]
DISPLAY=:98 i3-msg -q '[title="two"] focus'; sleep 0.3
DISPLAY=:98 i3-msg -t send_tick psycho:snap:left >/dev/null; sleep 0.8
R2=$(DISPLAY=:98 i3-msg -t get_tree | jq -r '[.. | objects | select(.type? == "floating_con") | select(any(recurse(.nodes[]?); .name? == "two")) | .rect] | first | "\(.x) \(.y) \(.width)"')
read -r SX SY SW <<<"$R2"
echo "second-output snap-left rect: $R2 (want 640 0 ~320, size hints tolerated)"
[ "$SX" -eq 640 ] && [ "$SY" -eq 0 ] && [ "$SW" -ge 304 ] && [ "$SW" -le 320 ]

echo PASS
