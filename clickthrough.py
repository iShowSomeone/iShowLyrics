#!/usr/bin/env python3
"""
clickthrough.py - make the iShowLyrics window ignore the mouse.
Author: iShowSomeone    Version: 1.0.1

Conky windows normally swallow every click in their area. That is harmless while
the widget sits below all other windows, but when it is pinned on top you could no
longer use whatever is underneath it. This helper gives the widget window an EMPTY
input region (the X11 "Shape" extension), so mouse clicks fall straight through.

Only needs libX11 and libXext (already present wherever Conky runs). Works on X11
and on Wayland sessions through XWayland.

Usage:
  python3 clickthrough.py apply [--wait SECONDS]   find the window and make it click-through
  python3 clickthrough.py check                    report whether the window is click-through
  python3 clickthrough.py ready                    exit 0 when the X display can be opened
Exit status: 0 = ok / click-through, 1 = window found but NOT click-through, 2 = window / display not found
"""
__author__ = "iShowSomeone"
__version__ = "1.0.1"

import ctypes, ctypes.util, os, sys, time

WINDOW_NAME = "iShowLyrics"      # set by own_window_title / own_window_class in lyrics.conf
SHAPE_INPUT, SHAPE_SET, UNSORTED = 2, 0, 0


class XClassHint(ctypes.Structure):
    # raw pointers (not c_char_p): ctypes would hand us Python copies, which must not be XFree()d
    _fields_ = [("res_name", ctypes.c_void_p), ("res_class", ctypes.c_void_p)]


def load():
    x11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
    xext = ctypes.CDLL(ctypes.util.find_library("Xext") or "libXext.so.6")
    c_ulong, c_void_p, c_int, c_uint = ctypes.c_ulong, ctypes.c_void_p, ctypes.c_int, ctypes.c_uint

    x11.XOpenDisplay.restype = c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XDefaultRootWindow.restype = c_ulong
    x11.XDefaultRootWindow.argtypes = [c_void_p]
    x11.XQueryTree.restype = c_int
    x11.XQueryTree.argtypes = [c_void_p, c_ulong, ctypes.POINTER(c_ulong), ctypes.POINTER(c_ulong),
                               ctypes.POINTER(ctypes.POINTER(c_ulong)), ctypes.POINTER(c_uint)]
    x11.XFetchName.restype = c_int
    x11.XFetchName.argtypes = [c_void_p, c_ulong, ctypes.POINTER(c_void_p)]
    x11.XGetClassHint.restype = c_int
    x11.XGetClassHint.argtypes = [c_void_p, c_ulong, ctypes.POINTER(XClassHint)]
    x11.XFree.argtypes = [c_void_p]
    x11.XSync.argtypes = [c_void_p, c_int]
    x11.XCloseDisplay.argtypes = [c_void_p]
    x11.XSetErrorHandler.restype = c_void_p

    xext.XShapeCombineRectangles.argtypes = [c_void_p, c_ulong, c_int, c_int, c_int, c_void_p, c_int, c_int, c_int]
    xext.XShapeGetRectangles.restype = c_void_p
    xext.XShapeGetRectangles.argtypes = [c_void_p, c_ulong, c_int, ctypes.POINTER(c_int), ctypes.POINTER(c_int)]
    return x11, xext


def find_windows(x11, dpy, win, depth=0, found=None):
    """All windows (any depth <= 4) whose WM_NAME or WM_CLASS is iShowLyrics."""
    found = [] if found is None else found
    if depth > 4:
        return found
    root, parent = ctypes.c_ulong(), ctypes.c_ulong()
    children, n = ctypes.POINTER(ctypes.c_ulong)(), ctypes.c_uint()
    if not x11.XQueryTree(dpy, win, ctypes.byref(root), ctypes.byref(parent),
                          ctypes.byref(children), ctypes.byref(n)):
        return found
    for i in range(n.value):
        child = children[i]
        name = ctypes.c_void_p()
        hit = False
        if x11.XFetchName(dpy, child, ctypes.byref(name)) and name.value:
            hit = ctypes.string_at(name.value).decode(errors="replace") == WINDOW_NAME
            x11.XFree(name.value)
        if not hit:
            hint = XClassHint()
            if x11.XGetClassHint(dpy, child, ctypes.byref(hint)):
                names = []
                for ptr in (hint.res_name, hint.res_class):
                    if ptr:
                        names.append(ctypes.string_at(ptr).decode(errors="replace"))
                        x11.XFree(ptr)
                hit = WINDOW_NAME in names
        if hit:
            found.append(child)
        find_windows(x11, dpy, child, depth + 1, found)
    if children:
        x11.XFree(children)
    return found


def input_region_empty(xext, x11, dpy, win):
    count, ordering = ctypes.c_int(), ctypes.c_int()
    rects = xext.XShapeGetRectangles(dpy, win, SHAPE_INPUT, ctypes.byref(count), ctypes.byref(ordering))
    if rects:
        x11.XFree(rects)
    return count.value == 0


def run(mode, wait):
    x11, xext = load()
    dpy = x11.XOpenDisplay(None)
    if not dpy:
        print("clickthrough: cannot open the X display (is DISPLAY set?)", file=sys.stderr)
        return 2
    try:
        root = x11.XDefaultRootWindow(dpy)
        deadline = time.time() + (wait if mode == "apply" else 0)
        wins = []
        while True:
            wins = find_windows(x11, dpy, root)
            if wins or time.time() >= deadline:
                break
            time.sleep(0.3)
        if not wins:
            print("clickthrough: widget window not found")
            return 2
        status = 0
        for w in wins:
            if mode == "apply":
                # empty rectangle list as the INPUT shape = nothing in the window receives mouse input
                xext.XShapeCombineRectangles(dpy, w, SHAPE_INPUT, 0, 0, None, 0, SHAPE_SET, UNSORTED)
                x11.XSync(dpy, 0)
            empty = input_region_empty(xext, x11, dpy, w)
            print(f"window 0x{w:x}: {'click-through' if empty else 'NOT click-through'}")
            if not empty:
                status = 1
        return status
    finally:
        x11.XCloseDisplay(dpy)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "ready":                 # used to wait for the desktop at login
        x11, _ = load()
        d = x11.XOpenDisplay(None)
        if d:
            x11.XCloseDisplay(d)
        sys.exit(0 if d else 2)
    if mode not in ("apply", "check"):
        print(__doc__)
        sys.exit(0)
    wait = 0.0
    if "--wait" in sys.argv:
        wait = float(sys.argv[sys.argv.index("--wait") + 1])
    sys.exit(run(mode, wait))
