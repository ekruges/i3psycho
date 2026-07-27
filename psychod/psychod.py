#!/usr/bin/env python3
"""psychod — i3psycho Phase 1 companion daemon.

Cascade placement, exact-workarea snapping, geometry-remembering minimize,
drag-beyond-edge snapping, MRU toggle, show-desktop. Pure i3 IPC, no X calls.

Triggers: `bindsym ... nop psycho:<action>` in the i3 config (binding events)
or `i3-msg -t send_tick psycho:<action>` from scripts. Actions:
  snap:left|right|max|center|tl|tr|bl|br   minimize (min) / restore[:conid]
  cycle (MRU alt-tab) / showdesktop / expose (real-window grid overview)
"""
import argparse
import collections
import math
import subprocess
import sys
import threading
import time

from i3ipc import Connection, Event

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument("--cascade-step", type=int, default=30)
ap.add_argument("--edge-margin", type=int, default=25,
                help="px beyond the workarea edge that triggers drop-snap")
ap.add_argument("--drop-debounce", type=float, default=0.25)
ap.add_argument("--hot-corners", default="tl=expose,br=showdesktop",
                help='corner=action pairs ("tl=expose,br=showdesktop"), or "none"')
ARGS = ap.parse_args()

HOT_CORNERS = {}
if ARGS.hot_corners != "none":
    for _pair in ARGS.hot_corners.split(","):
        _k, _, _v = _pair.partition("=")
        if _k.strip() in ("tl", "tr", "bl", "br") and _v.strip():
            HOT_CORNERS[_k.strip()] = _v.strip()

conn = Connection(auto_reconnect=True)
mru = collections.deque(maxlen=64)          # focus history, most recent last
saved = {}                                  # con_id -> (x, y, w, h) container rect
min_stack = []                              # LIFO of minimized con_ids
desktop_stash = collections.defaultdict(list)  # ws name -> [con_ids]
expose_stash = {}                           # ws name -> {con_id: rect}
cycle_state = {"order": [], "idx": 0, "t": 0.0}
cascade_n = collections.defaultdict(int)    # ws name -> spawn counter
cascaded = {}                               # con_id -> cascade slot
suppress = {}                               # con_id -> ignore moves until (monotonic)
moving_hint = {}                            # con_id -> last move event (from IPC)


def floating_parent(con):
    if con is None:
        return None
    if con.type == "floating_con":
        return con
    if con.parent is not None and con.parent.type == "floating_con":
        return con.parent
    return None


def scratch_leaves(tree):
    sp = tree.scratchpad()
    return [leaf for f in sp.floating_nodes for leaf in f.leaves()]


def workarea(con):
    ws = con.workspace()
    return ws.rect if ws else None


def place(c, con, x, y, w, h):
    """Move/size a floating container so its OUTER rect is exactly x,y,w,h.
    Since i3 4.21, `resize set ... px` on floating containers includes the
    decorations, so no chrome math is needed."""
    suppress[con.id] = time.monotonic() + 0.5
    c.command(f'[con_id="{con.id}"] resize set {int(w)} px {int(h)} px, '
              f'move absolute position {int(x)} px {int(y)} px')


def region_rect(wa, region):
    x, y, w, h = wa.x, wa.y, wa.width, wa.height
    return {
        "left":   (x, y, w // 2, h),
        "right":  (x + w // 2, y, w - w // 2, h),
        "max":    (x, y, w, h),
        "center": (x + int(w * 0.19), y + int(h * 0.19), int(w * 0.62), int(h * 0.62)),
        "tl":     (x, y, w // 2, h // 2),
        "tr":     (x + w // 2, y, w - w // 2, h // 2),
        "bl":     (x, y + h // 2, w // 2, h - h // 2),
        "br":     (x + w // 2, y + h // 2, w - w // 2, h - h // 2),
    }.get(region)


def focused_float(c):
    tree = c.get_tree()
    f = tree.find_focused()
    if f is None or f.workspace() is None or f.workspace().name.startswith("__"):
        return None
    if floating_parent(f) is None:
        c.command(f'[con_id="{f.id}"] floating enable')
        f = c.get_tree().find_by_id(f.id)
    return f


def do_snap(region):
    f = focused_float(conn)
    if f is None:
        return
    wa = workarea(f)
    r = region_rect(wa, region) if wa else None
    if r:
        place(conn, f, *r)


def do_minimize():
    f = focused_float(conn)
    if f is None:
        return
    fc = floating_parent(f)
    saved[f.id] = (fc.rect.x, fc.rect.y, fc.rect.width, fc.rect.height)
    min_stack.append(f.id)
    conn.command(f'[con_id="{f.id}"] move scratchpad')


def do_restore(cid=None):
    if cid is None:
        cid = min_stack.pop() if min_stack else None
    else:
        cid = int(cid)
        if cid in min_stack:
            min_stack.remove(cid)
    if cid is None:
        return
    conn.command(f'[con_id="{cid}"] scratchpad show')
    con = conn.get_tree().find_by_id(cid)
    if con is not None and cid in saved:
        place(conn, con, *saved.pop(cid))


def do_cycle():
    """MRU alt-tab: repeated presses walk the stack; after 1.2s of quiet the
    walk commits and the focused window becomes most-recent again."""
    now = time.monotonic()
    tree = conn.get_tree()
    if now - cycle_state["t"] > 1.2 or not cycle_state["order"]:
        seen, order = set(), []
        for cid in reversed(mru):
            if cid not in seen and tree.find_by_id(cid) is not None:
                seen.add(cid)
                order.append(cid)
        if len(order) < 2:
            return
        cycle_state["order"] = order
        cycle_state["idx"] = 0
    cycle_state["t"] = now
    cycle_state["idx"] = (cycle_state["idx"] + 1) % len(cycle_state["order"])
    conn.command(f'[con_id="{cycle_state["order"][cycle_state["idx"]]}"] focus')


def expose_restore(tree, ws_name):
    for cid, rect in expose_stash.pop(ws_name, {}).items():
        con = tree.find_by_id(cid)
        if con is not None:
            place(conn, con, *rect)


def do_expose():
    """Mission Control with real windows: arrange all floats in a grid;
    focusing any window (click, cycle) or toggling again restores them all.
    No compositor, no new UI surfaces, just the windows themselves."""
    tree = conn.get_tree()
    f = tree.find_focused()
    ws = f.workspace() if f else None
    if ws is None or ws.name.startswith("__"):
        return
    if ws.name in expose_stash:
        expose_restore(tree, ws.name)
        return
    floats = [(next(iter(fc.leaves()), None), fc) for fc in ws.floating_nodes]
    floats = [(leaf, fc) for leaf, fc in floats if leaf is not None]
    if len(floats) < 2:
        return
    cols = math.ceil(math.sqrt(len(floats)))
    rows = math.ceil(len(floats) / cols)
    gap = 24
    wa = ws.rect
    cell_w = (wa.width - gap * (cols + 1)) // cols
    cell_h = (wa.height - gap * (rows + 1)) // rows
    stash = {}
    for i, (leaf, fc) in enumerate(floats):
        stash[leaf.id] = (fc.rect.x, fc.rect.y, fc.rect.width, fc.rect.height)
        row, col = divmod(i, cols)
        place(conn, leaf,
              wa.x + gap + col * (cell_w + gap),
              wa.y + gap + row * (cell_h + gap),
              cell_w, cell_h)
    expose_stash[ws.name] = stash


def do_showdesktop():
    tree = conn.get_tree()
    f = tree.find_focused()
    ws = f.workspace() if f else None
    if ws is None:
        return
    if desktop_stash[ws.name]:
        for cid in desktop_stash.pop(ws.name):
            do_restore(cid)
        return
    for fc in ws.floating_nodes:
        for leaf in fc.leaves():
            saved[leaf.id] = (fc.rect.x, fc.rect.y, fc.rect.width, fc.rect.height)
            desktop_stash[ws.name].append(leaf.id)
            conn.command(f'[con_id="{leaf.id}"] move scratchpad')


def dispatch(payload):
    if not payload.startswith("psycho:"):
        return
    try:
        _dispatch(payload)
    except Exception as exc:
        print(f"psychod: {payload} failed: {exc}", file=sys.stderr)


def _dispatch(payload):
    parts = payload.split(":")
    action = parts[1]
    if action == "snap" and len(parts) > 2:
        do_snap(parts[2])
    elif action == "min":
        do_minimize()
    elif action == "restore":
        do_restore(parts[2] if len(parts) > 2 else None)
    elif action in ("cycle", "mru"):
        do_cycle()
    elif action == "showdesktop":
        do_showdesktop()
    elif action == "expose":
        do_expose()


def cascade(con, force=False):
    if con.id in cascaded and not force:
        return
    tree = conn.get_tree()
    c = tree.find_by_id(con.id)
    if c is None or floating_parent(c) is None:
        return
    # i3ipc's Con class never maps window_type, so getattr() always returned
    # None here and this skip was dead code: dialogs and splashes got yanked
    # into the cascade instead of being left where the app put them. The
    # field is only in the raw IPC dict.
    wtype = c.ipc_data.get("window_type")
    if wtype in ("dialog", "utility", "splash", "notification", "dock"):
        return
    ws = c.workspace()
    if ws is None or ws.name.startswith("__"):
        return
    if con.id in cascaded:
        n = cascaded[con.id]        # re-placing the same window: same slot,
    else:                           # or the visible step doubles
        if len(cascaded) > 512:
            cascaded.clear()
        n = cascade_n[ws.name] % 8
        cascade_n[ws.name] += 1
    cascaded[con.id] = n
    step = ARGS.cascade_step
    fc = floating_parent(c)
    x = ws.rect.x + 40 + n * step
    y = ws.rect.y + 36 + n * step
    x = min(x, ws.rect.x + ws.rect.width - fc.rect.width - 8)
    y = min(y, ws.rect.y + ws.rect.height - fc.rect.height - 8)
    suppress[con.id] = time.monotonic() + 0.5
    conn.command(f'[con_id="{con.id}"] move absolute position {int(x)} px {int(y)} px')


def on_new(_, e):
    # `floating enable` from a for_window rule fires window::floating mid-way
    # through the assignment batch, so on_floating cascades before the rest of
    # the batch runs -- and a later `move position center` rule then overwrites
    # it. window::new is emitted after the whole batch, so it is the
    # authoritative placement point, so force past the spent guard.
    cascade(e.container, force=True)


def on_floating(_, e):
    if e.change == "floating_on" or getattr(e.container, "floating", "") in ("auto_on", "user_on"):
        cascade(e.container)


def on_focus(_, e):
    mru.append(e.container.id)
    # focusing a window while its workspace is in expose mode exits expose,
    # restoring every window (macOS click-to-select behavior)
    if expose_stash:
        tree = conn.get_tree()
        con = tree.find_by_id(e.container.id)
        ws = con.workspace() if con else None
        if ws is not None and ws.name in expose_stash:
            expose_restore(tree, ws.name)


def on_close(_, e):
    saved.pop(e.container.id, None)
    if e.container.id in min_stack:
        min_stack.remove(e.container.id)
    tree = conn.get_tree()
    for ws in tree.workspaces():
        if ws.name in cascade_n and not ws.floating_nodes:
            cascade_n[ws.name] = 0


def on_move(_, e):
    # patched i3 emits these for floating repositions; stock i3 does not.
    # Either way the poller below verifies geometry, this just wakes it fast.
    if suppress.get(e.container.id, 0) <= time.monotonic():
        moving_hint[e.container.id] = time.monotonic()


def on_binding(_, e):
    cmd = (e.binding.command or "").strip()
    if cmd.startswith("nop "):
        dispatch(cmd[4:].strip())


def on_tick(_, e):
    if getattr(e, "first", False):
        return
    dispatch(e.payload or "")


def drop_worker():
    """Poll floating rects; when one settles beyond a workarea edge, snap it.
    Stock i3 emits no window::move events for floating repositions, so we
    poll; the patched i3 emits them (patch 0001) and the poll doubles as
    settle detection either way."""
    wconn = Connection(auto_reconnect=True)
    prev = {}      # leaf id -> outer rect tuple
    moving = {}    # leaf id -> last time the rect changed
    hidden = set()  # leaf ids currently in the scratchpad
    hot = {"corner": None, "since": 0.0, "armed": True}
    interval = 0.6
    failures = 0
    while True:
        time.sleep(interval)
        try:
            tree = wconn.get_tree()
            failures = 0
        except Exception:
            failures += 1
            if failures >= 4:             # i3 restarted: re-resolve the socket
                try:
                    wconn = Connection(auto_reconnect=True)
                except Exception:
                    pass
                failures = 0
            continue
        now = time.monotonic()
        if HOT_CORNERS:
            poll_hot_corner(wconn, hot, tree.rect, now)
        # butter: poll fast only while something is (or just was) moving
        active = bool(moving) or any(now - t < 1.0 for t in moving_hint.values())
        interval = 0.15 if active else 0.6
        if len(moving_hint) > 64:
            moving_hint.clear()
        seen = set()
        for ws in tree.workspaces():
            if ws.name.startswith("__"):
                continue
            for fc in ws.floating_nodes:
                leaf = next(iter(fc.leaves()), None)
                if leaf is None:
                    continue
                cid = leaf.id
                seen.add(cid)
                pos = (fc.rect.x, fc.rect.y, fc.rect.width, fc.rect.height)
                if prev.get(cid) != pos:
                    prev[cid] = pos
                    if suppress.get(cid, 0) > now:
                        moving.pop(cid, None)     # our own placement
                    else:
                        moving[cid] = now
                elif cid in moving and now - moving[cid] >= ARGS.drop_debounce:
                    moving.pop(cid)
                    evaluate_drop(wconn, fc, leaf, ws.rect)
        for cid in [c for c in prev if c not in seen]:
            # iconified by any path: save the last visible rect
            con = tree.find_by_id(cid)
            if (con is not None and con.workspace() is not None
                    and con.workspace().name.startswith("__")):
                hidden.add(cid)
                if cid not in saved:
                    saved[cid] = prev[cid]
                    min_stack.append(cid)
            prev.pop(cid)
            moving.pop(cid, None)
        # restored by any path: put it back at the saved rect
        for cid in [c for c in hidden if c in seen]:
            hidden.discard(cid)
            if cid in saved:
                con = tree.find_by_id(cid)
                if con is not None:
                    place(wconn, con, *saved.pop(cid))
                if cid in min_stack:
                    min_stack.remove(cid)


def poll_hot_corner(wconn, st, root_rect, now):
    # xdotool subprocess per poll; swap for python-xlib if it ever matters
    try:
        out = subprocess.run(["xdotool", "getmouselocation", "--shell"],
                             capture_output=True, text=True, timeout=1).stdout
        pos = dict(ln.split("=", 1) for ln in out.strip().splitlines() if "=" in ln)
        x, y = int(pos["X"]), int(pos["Y"])
    except Exception:
        return
    m = 1
    at_l, at_t = x <= m, y <= m
    at_r = x >= root_rect.width - 1 - m
    at_b = y >= root_rect.height - 1 - m
    corner = ("tl" if at_l and at_t else "tr" if at_r and at_t else
              "bl" if at_l and at_b else "br" if at_r and at_b else None)
    if corner is None:
        st.update(corner=None, since=0.0, armed=True)
        return
    if corner != st["corner"]:
        st.update(corner=corner, since=now)
        return
    if st["armed"] and now - st["since"] >= 0.5 and corner in HOT_CORNERS:
        st["armed"] = False          # re-arms when the pointer leaves
        wconn.send_tick(f"psycho:{HOT_CORNERS[corner]}")


def evaluate_drop(wconn, fc, leaf, wa):
    m = ARGS.edge_margin
    over_l = (wa.x - m) - fc.rect.x
    over_r = (fc.rect.x + fc.rect.width) - (wa.x + wa.width + m)
    over_t = (wa.y - m) - fc.rect.y
    over_b = (fc.rect.y + fc.rect.height) - (wa.y + wa.height + m)
    horiz = max(over_l, over_r, 0)
    vert = max(over_t, over_b, 0)
    # A window as tall as the workarea overhangs the cross axis by a few px on
    # any sideways drag, which read as a corner and snapped it to a quarter.
    # Only call it a corner when both axes overflow comparably; otherwise the
    # dominant axis wins and a half stays a half.
    if horiz and vert:
        if vert * 2 < horiz:
            vert = 0
        elif horiz * 2 < vert:
            horiz = 0
    left = bool(horiz) and over_l >= over_r
    right = bool(horiz) and over_r > over_l
    top = bool(vert) and over_t >= over_b
    bottom = bool(vert) and over_b > over_t
    region = None
    if top and left:
        region = "tl"
    elif top and right:
        region = "tr"
    elif bottom and left:
        region = "bl"
    elif bottom and right:
        region = "br"
    elif top:
        region = "max"
    elif left:
        region = "left"
    elif right:
        region = "right"
    if region:
        place(wconn, leaf, *region_rect(wa, region))


def register_handlers(c):
    c.on(Event.WINDOW_NEW, on_new)
    c.on(Event.WINDOW_FLOATING, on_floating)
    c.on(Event.WINDOW_FOCUS, on_focus)
    c.on(Event.WINDOW_CLOSE, on_close)
    c.on(Event.WINDOW_MOVE, on_move)
    c.on(Event.BINDING, on_binding)
    c.on(Event.TICK, on_tick)


def main():
    global conn
    threading.Thread(target=drop_worker, daemon=True).start()
    register_handlers(conn)
    while True:
        try:
            conn.main()
        except Exception as exc:
            print(f"psychod: event loop interrupted: {exc}", file=sys.stderr)
        # i3 went away (restart, crash, replace). Rebuild the connection from
        # scratch so the socket path is re-resolved from the X root window;
        # retrying a dead Connection can spin on a stale path forever.
        while True:
            time.sleep(0.5)
            try:
                conn = Connection(auto_reconnect=True)
                register_handlers(conn)
                print("psychod: reconnected to i3", file=sys.stderr)
                break
            except Exception:
                continue


if __name__ == "__main__":
    main()
