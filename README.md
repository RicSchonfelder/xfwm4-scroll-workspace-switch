# xfwm4 — switch workspace with the mouse wheel while moving a window

A small patch for [xfwm4](https://gitlab.xfce.org/xfce/xfwm4) (the Xfce window
manager) that lets you **switch workspaces with the mouse wheel while you are
dragging a window**, taking the window along with you.

* wheel **down** → next workspace
* wheel **up** → previous workspace
* the dragged window stays attached and lands on the new workspace when you
  release the button

## Why

The wheel already switches workspaces over the desktop background
(`/general/scroll_workspaces`) and over the panel pager. The only *mouse* way to
move a window to another workspace today is to drag it to the screen edge
(`/general/wrap_windows`), which conflicts with edge tiling (`tile_on_move`):
with tiling enabled the window gets tiled instead of wrapping. A single,
consistent gesture (hold the window, scroll) is faster and avoids that
ambiguity.

## Files

* `xfwm4-scroll-workspace-switch.patch` — the patch (taken against 4.20.0;
  applies to `master` with a bit of fuzz)
* `upstream-issue.md` — the write-up used for the upstream request

## What the patch changes (`src/moveresize.c`)

1. Adds `ButtonPressMask` to `MOVERESIZE_POINTER_EVENT_MASK`, so wheel
   `ButtonPress` events are delivered to xfwm4 while a move is in progress.
2. In `clientMoveEventFilter()`, handles `Button4`/`Button5` press by calling
   `workspaceMove(screen_info, 0, ±1, c, timestamp)` — the very call
   `clientMoveWarp()` uses for edge wrapping — so the window is carried along.
3. Only ends the move on release of the button that started the drag (otherwise
   the wheel's own release, `Button4/5`, would abort the drag).

```diff
--- a/src/moveresize.c
+++ b/src/moveresize.c
@@ -55,6 +55,7 @@
 
 #define MOVERESIZE_POINTER_EVENT_MASK \
     PointerMotionMask | \
+    ButtonPressMask | \
     ButtonMotionMask | \
     ButtonReleaseMask | \
     LeaveWindowMask
@@ -996,10 +997,25 @@
     }
     else if (event->meta.type == XFWM_EVENT_BUTTON && !event->button.pressed)
     {
-        moving = FALSE;
-        passdata->released = (passdata->use_keys ||
-                              passdata->button == AnyButton ||
-                              passdata->button == event->button.button);
+        /* Only release of the button that started the drag ends the move.
+         * Ignore other buttons (e.g. the wheel Button4/5) so that a single
+         * scroll notch does not abort the drag. */
+        if (passdata->use_keys ||
+            passdata->button == AnyButton ||
+            passdata->button == event->button.button)
+        {
+            moving = FALSE;
+            passdata->released = TRUE;
+        }
+    }
+    else if (event->meta.type == XFWM_EVENT_BUTTON && event->button.pressed &&
+             (event->button.button == Button4 || event->button.button == Button5))
+    {
+        /* Mouse wheel while dragging a window: switch workspace and take the
+         * window along (same mechanism used when dragging to the screen edge). */
+        workspaceMove (screen_info, 0,
+                       (event->button.button == Button5) ? 1 : -1,
+                       c, event->button.time);
     }
     else if (event->meta.type == XFWM_EVENT_MOTION)
     {
```

## Apply & build

```sh
# from a source tree of xfwm4 (4.20.x release or master)
patch -p1 < xfwm4-scroll-workspace-switch.patch

# autotools (4.20.x release tarball)
./configure --prefix=/usr --enable-compositor && make -j"$(nproc)"
sudo make install

# or meson (current master)
meson setup build && meson compile -C build && sudo meson install -C build

# reload the window manager
xfwm4 --replace &
```

Tested on xfwm4 4.20.0 (Debian 13, X11): the wheel switches workspace and the
window follows, in both directions, while the drag stays active.

## Upstream

Please use **Xfce's GitLab** — the GitHub `xfce-mirror/xfwm4` repository is a
read-only mirror and does not watch PRs:

* New issue / merge request: <https://gitlab.xfce.org/xfce/xfwm4/-/issues/new>
* Project: <https://gitlab.xfce.org/xfce/xfwm4>

## License

xfwm4 is distributed under the GPL-2.0-or-later; this patch is provided under
the same terms.
