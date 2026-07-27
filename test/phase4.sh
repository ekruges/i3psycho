#!/usr/bin/env bash
# Phase 4 smoke test: daily-driver correctness.
# App-initiated iconify (fork patch 0004), EWMH hidden state, ICCCM WM_STATE,
# and psychod surviving an in-place i3 restart.
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
i3 -c dist/psycho.config >/tmp/i3psycho-p4-log 2>&1 &
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

xterm -T alpha & sleep 1.5
WID=$(xdotool search --name '^alpha$' | head -1)
BEFORE=$(rect alpha)
echo "window $WID at $BEFORE"

echo "--- 1. app-initiated iconify lands in the scratchpad"
sleep 0.7   # let the psychod poller record the rect for retro-save
xdotool windowminimize "$WID"; sleep 1.0
V=$(visible); echo "visible after app minimize: $V (want 0)"; [ "$V" -eq 0 ]

echo "--- 2. EWMH + ICCCM state while iconified"
xprop -id "$WID" _NET_WM_STATE | grep -q _NET_WM_STATE_HIDDEN || { echo "FAIL: HIDDEN not set"; exit 1; }
echo "_NET_WM_STATE_HIDDEN set"
xprop -id "$WID" WM_STATE | grep -qi iconic || { echo "FAIL: WM_STATE not Iconic"; xprop -id "$WID" WM_STATE; exit 1; }
echo "WM_STATE Iconic set"

echo "--- 3. restore returns in place, state cleared"
i3-msg -t send_tick psycho:restore >/dev/null; sleep 1.0
AFTER=$(rect alpha)
echo "rect $BEFORE -> $AFTER"
[ "$BEFORE" = "$AFTER" ]
xprop -id "$WID" _NET_WM_STATE | grep -q _NET_WM_STATE_HIDDEN && { echo "HIDDEN still set"; exit 1; } || echo "_NET_WM_STATE_HIDDEN cleared"
xprop -id "$WID" WM_STATE | grep -qi normal || { echo "FAIL: WM_STATE not Normal"; exit 1; }
echo "WM_STATE Normal restored"

echo "--- 4. psychod survives i3 restart in place"
PSYPID=$(pgrep -f "bin/psychod$" | head -1)
i3-msg -q restart; sleep 3
PSYPID2=$(pgrep -f "bin/psychod$" | head -1)
COUNT=$(pgrep -f "bin/psychod$" | wc -l | tr -d " ")
echo "psychod pid $PSYPID -> $PSYPID2, instances: $COUNT (want 1 running instance)"
[ -n "$PSYPID2" ] && [ "$COUNT" -eq 1 ]
OK=""
for i in $(seq 1 10); do
  i3-msg -t send_tick psycho:snap:left >/dev/null 2>&1 || true
  sleep 0.8
  GOT=$(rect alpha)
  read -r SX SY SW _ <<<"$GOT"
  if [ "$SX" = "0" ] && [ "$SY" = "0" ] && [ "$SW" -ge 624 ] && [ "$SW" -le 640 ]; then OK=1; break; fi
done
echo "post-restart snap-left: $GOT after $i tries (want x=0 y=0 w~640)"
[ -n "$OK" ]

echo PASS
