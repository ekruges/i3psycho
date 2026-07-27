#!/usr/bin/env python3
"""Minimized-window chips for polybar.

The patched i3 draws these inside i3bar (patch 0005), which does nothing for
the large share of i3 users running polybar. This renders the same taskbar
from the i3 tree instead: every window psychod parked in the scratchpad gets a
clickable chip, and the click sends the psycho:restore:<con_id> tick that puts
it back at its saved geometry.

Install:

    install -Dm755 contrib/psycho-chips-polybar.py \\
        ~/.config/polybar/scripts/psycho-chips.py

Then add the module and put `psychochips` in one of your modules- lines:

    [module/psychochips]
    type = custom/script
    exec = ~/.config/polybar/scripts/psycho-chips.py
    tail = true

`tail = true` matters: this is event-driven (it subscribes to window and tick
events), so polybar must stream its output rather than re-running it on a
poll interval.

Colors are read from POLYBAR_CHIP_FG / POLYBAR_CHIP_PREFIX if set, so you can
match your bar without editing this file.
"""
import os
import sys
import time

from i3ipc import Connection, Event

MAX_TITLE = int(os.environ.get("POLYBAR_CHIP_MAXLEN", "18"))
FG = os.environ.get("POLYBAR_CHIP_FG", "#8fa1b3")
PREFIX = os.environ.get("POLYBAR_CHIP_PREFIX", "▾ ")


def scratch_leaves(tree):
    sp = tree.scratchpad()
    return [leaf for f in sp.floating_nodes for leaf in f.leaves()]


def label(con):
    name = (con.name or con.window_class or "window").replace("\n", " ").strip()
    # polybar parses %{...}; defuse the only sequence that can start a tag, or
    # a window titled "%{o}" turns into bar formatting
    name = name.replace("%{", "% {")
    if len(name) > MAX_TITLE:
        name = name[:MAX_TITLE - 1].rstrip() + "…"
    return name


def render(tree):
    chips = []
    for con in scratch_leaves(tree):
        # a literal ':' inside a polybar click action has to be escaped, and
        # con ids are what psycho:restore takes
        cmd = f"i3-msg -t send_tick psycho\\:restore\\:{con.id}"
        chips.append(f"%{{A1:{cmd}:}}%{{F{FG}}}{PREFIX}{label(con)}%{{F-}}%{{A}}")
    return "  ".join(chips)


def main():
    conn = Connection(auto_reconnect=True)

    def refresh(i3=None, e=None):
        try:
            print(render(conn.get_tree()), flush=True)
        except Exception:
            pass

    while True:
        try:
            refresh()
            conn.on(Event.WINDOW, refresh)
            conn.on(Event.TICK, refresh)
            conn.main()
        except Exception as exc:
            print(f"psycho-chips: {exc}", file=sys.stderr)
        # i3 restarted: blank the module, then rebuild the connection so the
        # socket path is re-resolved from the X root window
        print("", flush=True)
        while True:
            time.sleep(0.5)
            try:
                conn = Connection(auto_reconnect=True)
                break
            except Exception:
                continue


if __name__ == "__main__":
    main()
