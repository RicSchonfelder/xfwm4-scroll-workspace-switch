# Draft — upstream issue for xfwm4 (Xfce GitLab)

**Where:** https://gitlab.xfce.org/xfce/xfwm4/-/issues/new
**Needs:** a gitlab.xfce.org account (GitHub does NOT accept xfwm4 PRs — the
GitHub repo is a read-only mirror: "PRs are not watched, please use Xfce's GitLab")

---

## Title

Switch workspace with the mouse wheel while moving a window (carry the window along)

## Description

### Feature

While moving a window (dragging the title bar, or Alt+drag "easy move"),
turning the mouse wheel should switch to the adjacent workspace and take the
window along with it — the same result as dragging the window to the screen
edge, but using the wheel.

* wheel down -> next workspace
* wheel up   -> previous workspace
* the window stays attached to the dragged window and lands on the new
  workspace when the button is released.

### Rationale

* The wheel already switches workspaces over the desktop background
  (`/general/scroll_workspaces`) and over the panel pager.
* Today the only *mouse* way to move a window to another workspace is dragging
  it to the screen edge (`/general/wrap_windows`). That conflicts with edge
  tiling: with `tile_on_move` enabled the window is tiled instead of wrapping
  (see e.g. the "window snapping + wrap workspace" reports).
* A single, consistent gesture (hold the window, scroll) is faster and avoids
  the tiling/edge-wrapping ambiguity.

### Current behaviour (why it does not work)

1. `MOVERESIZE_POINTER_EVENT_MASK` in `src/moveresize.c` does not include
   `ButtonPressMask`, so wheel ButtonPress events are not delivered to xfwm4
   while a move is in progress.
2. Even if they were, `clientMoveEventFilter()` only acts on the release of a
   button; other button presses are ignored.
3. The release branch ends the move on *any* button release. Because the wheel
   also generates a release (Button4/5), a single notch would abort the drag.

### Proposed change (3 small edits in `src/moveresize.c`)

1. Add `ButtonPressMask` to `MOVERESIZE_POINTER_EVENT_MASK`.
2. In `clientMoveEventFilter()`, handle `Button4`/`Button5` press by calling
   `workspaceMove(screen_info, 0, +/-1, c, timestamp)` — the very call
   `clientMoveWarp()` uses for edge wrapping — so the window is carried along.
3. In the same filter, only end the move on release of the button that started
   the drag (ignore wheel releases).

Patch (taken against the 4.20.0 source; line numbers may shift on master):

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

### Notes / testing

* Built and tested the patch on xfwm4 4.20.0 (Debian 13, X11). The wheel
  switches workspace and the window follows, in both directions, while the
  drag stays active. Desktop-background scrolling is unaffected.
* Happy to make this opt-in behind a new xfconf option (e.g.
  `/general/scroll_workspace_on_move`) if you'd rather not change the default
  behaviour.
* I can send it as a Merge Request if preferred.

Related: #6 (mouse wheel workspace cycling), and the "wrap workspaces when
dragging a window" feature (`/general/wrap_windows`).
