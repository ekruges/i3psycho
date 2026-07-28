#!/usr/bin/env python3
"""Titlebar buttons for the focused window, as a polybar module.

A fullscreen window has no titlebar, so the close / iconify / maximize buttons
go with it and there is no way back out except a keybinding. Put the same three
buttons on an auto-hiding top bar and the way out is where you would look for
it: shove the pointer at the top edge and click.

Order and glyphs match the titlebar (close, iconify, maximize) so the muscle
memory carries over. Colors default to i3's client.focused so the cluster reads
as a piece of window chrome rather than a bar module; override with
PSYCHO_WC_BG / PSYCHO_WC_FG.

Put it in modules-right, not modules-left. A hot corner occupies the top-left
of the screen, and it fires on hover -- so a close button sitting there is one
slip away from killing a window you meant to expose. PSYCHO_WC_PAD widens the
targets; the default of two spaces is about a 60px button at Xft.dpi 192.

polybar module: type = custom/script with tail = true.
"""
import os
import sys
import time

from i3ipc import Connection, Event

BG = os.environ.get("PSYCHO_WC_BG", "#7fb2dd")
FG = os.environ.get("PSYCHO_WC_FG", "#ffffff")
IDLE = os.environ.get("PSYCHO_WC_IDLE", "#46525e")
PAD = " " * max(1, int(os.environ.get("PSYCHO_WC_PAD", "2")))

# (glyph, i3 command). maximize toggles, so it is also the way out of fullscreen.
BUTTONS = [
    ("×", "kill"),
    ("−", "-t send_tick psycho\\:min"),
    ("+", "fullscreen toggle"),
]


def focused_leaf(tree):
    f = tree.find_focused()
    if f is None or f.window is None:
        return None
    return f


def render(tree):
    con = focused_leaf(tree)
    if con is None:
        # nothing focused: draw the cluster greyed rather than collapsing the
        # bar, so the buttons do not move around under the pointer
        return "".join(f"%{{F{IDLE}}}{PAD}{g}{PAD}%{{F-}}" for g, _ in BUTTONS)
    out = []
    for glyph, cmd in BUTTONS:
        out.append(f"%{{A1:i3-msg {cmd}:}}%{{B{BG}}}%{{F{FG}}}{PAD}{glyph}{PAD}"
                   f"%{{F-}}%{{B-}}%{{A}}")
    return "".join(out)


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
            print(f"psycho-wincontrols: {exc}", file=sys.stderr)
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
