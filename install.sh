#!/usr/bin/env bash
#
#  xfwm4-scroll-workspace-switch — installer
#  ------------------------------------------------------------------
#  Makes xfwm4 switch workspaces with the mouse wheel WHILE a window is
#  being dragged, carrying the window along.
#
#  One-liner:
#     curl -fsSL https://raw.githubusercontent.com/RicSchonfelder/xfwm4-scroll-workspace-switch/main/install.sh | sudo bash
#
#  Options (when piping, pass them after `bash -s --`):
#     --check         Only check the installed version / compatibility. No changes.
#     --uninstall     Restore the original xfwm4.
#     --force         Continue even if the version is not in the tested range.
#     --version X.Y.Z Build the patch against this upstream version (override autodetect).
#     --no-restart    Do not restart xfwm4 after installing.
#     -h, --help      Show this help.
#
#  Example:
#     curl -fsSL .../install.sh | sudo bash -s -- --check
#     curl -fsSL .../install.sh | sudo bash -s -- --uninstall
#
set -Eeuo pipefail

RAW_BASE="https://raw.githubusercontent.com/RicSchonfelder/xfwm4-scroll-workspace-switch/main"
TESTED_REGEX='^4\.20\.[0-9]+$'
TESTED_NOTE="4.20.x"
MARKER_DIR="/var/lib/xfwm4-scroll-workspace-switch"
MARKER="${MARKER_DIR}/installed"
BACKUP_SUFFIX=".scroll-workspace.bak"

ACTION="install"
FORCE=0
DO_RESTART=1
TARGET_OVERRIDE=""

# ------------------------------------------------------------------ helpers
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
else
  C_RESET=""; C_BLUE=""; C_YEL=""; C_RED=""; C_GRN=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Never restart xfwm4 as root: it must run as the desktop user, and with the
# session environment (DISPLAY, XAUTHORITY, DBUS_SESSION_BUS_ADDRESS, ...),
# otherwise xfconf fails to initialise. We reuse the environment of the xfwm4
# that is currently running.
restart_wm() {
  [ "$DO_RESTART" -eq 1 ] || { log "Skipping xfwm4 restart (--no-restart)."; return 0; }
  local pid duser val envs v
  pid="$(pgrep -x xfwm4 | head -n1 || true)"
  if [ -z "$pid" ]; then
    warn "No running xfwm4 found; the new binary will be used on the next login."
    return 0
  fi
  duser="$(stat -c '%U' "/proc/$pid" 2>/dev/null || true)"
  [ -z "$duser" ] && duser="$(ps -o user= -p "$pid" 2>/dev/null | awk '{print $1}')"
  { [ -z "$duser" ] || [ "$duser" = "root" ]; } && duser="${SUDO_USER:-}"
  if [ -z "$duser" ] || [ "$duser" = "root" ]; then
    warn "Could not detect the desktop user; not restarting xfwm4."
    warn "Log out and back in, or run as your user:  xfwm4 --replace &"
    return 0
  fi
  envs=""
  for v in DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_DATA_DIRS LANG; do
    val="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n "s/^${v}=//p" | head -n1)"
    [ -n "$val" ] && envs="$envs $v=$val"
  done
  if [ -z "$envs" ]; then
    warn "Could not read the session environment; log out/in to apply."
    return 0
  fi
  log "Restarting xfwm4 as user '$duser'..."
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$duser" -- env $envs sh -c 'setsid xfwm4 --replace >/dev/null 2>&1 </dev/null &'
  elif command -v su >/dev/null 2>&1; then
    su "$duser" -c "env $envs sh -c 'setsid xfwm4 --replace >/dev/null 2>&1 </dev/null &'"
  else
    warn "Neither runuser nor su available; log out/in to apply."
  fi
}

usage() {
  cat <<'EOF'
xfwm4-scroll-workspace-switch — installer

Makes xfwm4 switch workspaces with the mouse wheel WHILE a window is being
dragged, carrying the window along.

Usage:
  curl -fsSL <RAW_URL>/install.sh | sudo bash
  curl -fsSL <RAW_URL>/install.sh | sudo bash -s -- [options]

Options:
  --check         Only check the installed version / compatibility. No changes.
  --uninstall     Restore the original xfwm4.
  --force         Continue even if the version is not in the tested range (4.20.x).
  --version X.Y.Z Build the patch against this upstream version (override autodetect).
  --no-restart    Do not restart xfwm4 after installing.
  -h, --help      Show this help.
EOF
}

# ------------------------------------------------------------------ args
while [ $# -gt 0 ]; do
  case "$1" in
    --check)      ACTION="check" ;;
    --uninstall|--revert) ACTION="uninstall" ;;
    --force)      FORCE=1 ;;
    --no-restart) DO_RESTART=0 ;;
    --version)    shift; TARGET_OVERRIDE="${1:-}" ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Must run as root. Use: curl -fsSL ${RAW_BASE}/install.sh | sudo bash"
}
need_root

WORK="$(mktemp -d /tmp/xfwm4-scroll.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ------------------------------------------------------------------ detect
BIN="$(command -v xfwm4 2>/dev/null || true)"
[ -n "$BIN" ] || die "xfwm4 not found in PATH. Is Xfce installed?"
BIN="$(readlink -f "$BIN")"
BACKUP="${BIN}${BACKUP_SUFFIX}"

detect_version() {
  local out
  out="$("$BIN" --version 2>/dev/null | head -n1 || true)"
  if [[ "$out" =~ version[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"; return 0
  fi
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Version}\n' xfwm4 2>/dev/null \
      | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1 && return 0
  fi
  if command -v rpm >/dev/null 2>&1; then
    rpm -q --qf '%{VERSION}\n' xfwm4 2>/dev/null | head -n1 && return 0
  fi
  return 1
}

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

INSTALLED="$(detect_version || true)"
[ -n "$INSTALLED" ] || die "Could not determine the installed xfwm4 version."
TARGET="${TARGET_OVERRIDE:-$INSTALLED}"

log "xfwm4 binary .......: $BIN"
log "Installed version ..: $INSTALLED"
log "Target version .....: $TARGET"

# ------------------------------------------------------------------ already patched?
if [ "$ACTION" != "uninstall" ] && [ -f "$MARKER" ]; then
  M_SHA="$(sed -nE 's/^sha256=(.*)$/\1/p' "$MARKER")"
  if [ -n "$M_SHA" ] && [ "$M_SHA" = "$(sha256_of "$BIN")" ]; then
    ok "Already installed (marker matches the current binary, version $(sed -nE 's/^version=(.*)$/\1/p' "$MARKER"))."
    if [ "$FORCE" -ne 1 ]; then
      log "Use --force to reinstall anyway."
      exit 0
    fi
  fi
fi

# ================================================================== UNINSTALL
if [ "$ACTION" = "uninstall" ]; then
  log "Uninstalling (restoring the original xfwm4)..."
  restored=0
  if command -v apt-get >/dev/null 2>&1; then
    if DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y xfwm4 >/dev/null 2>&1; then
      restored=1; ok "Reinstalled the distribution package (pristine original)."
    fi
  fi
  if [ "$restored" -eq 0 ] && command -v dnf >/dev/null 2>&1; then
    dnf reinstall -y xfwm4 >/dev/null 2>&1 && restored=1
  fi
  if [ "$restored" -eq 0 ] && command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install --force xfwm4 >/dev/null 2>&1 && restored=1
  fi
  if [ "$restored" -eq 0 ] && [ -f "$BACKUP" ]; then
    install -m 0755 "$BACKUP" "$BIN"
    restored=1; ok "Restored the backed-up binary from $BACKUP"
  fi
  [ "$restored" -eq 1 ] || die "Could not restore the original xfwm4. Reinstall the xfwm4 package manually."
  rm -f "$BACKUP"
  rm -rf "$MARKER_DIR"
  restart_wm
  exit 0
fi

# ------------------------------------------------------------------ version gate
version_ok=0
if [[ "$TARGET" =~ $TESTED_REGEX ]]; then
  version_ok=1
else
  warn "Version $TARGET is outside the tested range ($TESTED_NOTE)."
  if [ "$FORCE" -ne 1 ]; then
    warn "Refusing to change anything. Re-run with --force to try anyway (the patch is still checked against the source)."
    for t in curl tar patch gcc make pkg-config; do
      command -v "$t" >/dev/null 2>&1 && ok "tool present: $t" || warn "tool missing: $t"
    done
    exit 2
  fi
fi

# ------------------------------------------------------------------ download source
major_minor="${TARGET%.*}"
url_bz2="https://archive.xfce.org/src/xfce/xfwm4/${major_minor}/xfwm4-${TARGET}.tar.bz2"
url_xz="https://archive.xfce.org/src/xfce/xfwm4/${major_minor}/xfwm4-${TARGET}.tar.xz"

log "Downloading the matching source (xfwm4-$TARGET)..."
srcfile=""
for u in "$url_bz2" "$url_xz"; do
  if curl -fsSL --max-time 120 "$u" -o "$WORK/src.pkg" 2>/dev/null; then srcfile="$WORK/src.pkg"; break; fi
done
[ -n "$srcfile" ] || die "Could not download the source for $TARGET from archive.xfce.org.
   The exact version may not have an upstream tarball. Try --version <X.Y.Z> or use your distro's source package."
tar xf "$srcfile" -C "$WORK"
SRC="$WORK/xfwm4-$TARGET"
[ -d "$SRC" ] || SRC="$(find "$WORK" -maxdepth 1 -type d -name 'xfwm4-*' | head -n1)"
[ -d "$SRC" ] || die "Unexpected tarball layout."

# ------------------------------------------------------------------ embed patch
cat > "$WORK/patch.diff" <<'PATCH_EOF'
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
PATCH_EOF

log "Checking that the patch applies cleanly to xfwm4-$TARGET..."
if ! patch -p1 --dry-run -d "$SRC" -i "$WORK/patch.diff" >/dev/null 2>&1; then
  if [ "$FORCE" -eq 1 ]; then
    warn "Patch does not apply cleanly; continuing anyway because of --force."
  else
    die "The patch does not apply to this source tree.
   This usually means the version is not supported yet. Nothing was changed.
   Re-run with --force to attempt it anyway."
  fi
fi

# ------------------------------------------------------------------ CHECK mode
if [ "$ACTION" = "check" ]; then
  ok "Version $TARGET: source downloaded and the patch applies cleanly."
  missing=()
  for t in curl tar patch gcc make pkg-config; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  for p in gtk+-3.0 libxfce4ui-2 libxfce4util-1.0 libxfconf-0 libwnck-3.0 epoxy x11 xext xinerama; do
    pkg-config --exists "$p" 2>/dev/null || missing+=("pkg:$p")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "All build prerequisites look present."
  else
    warn "Missing build prerequisites: ${missing[*]}"
    warn "(the installer tries to install them automatically before building)"
  fi
  log "Check-only mode: nothing was changed."
  exit 0
fi

# ------------------------------------------------------------------ apply patch
log "Applying the patch to src/moveresize.c..."
patch -p1 -d "$SRC" -i "$WORK/patch.diff" >/dev/null 2>&1 || die "Failed to apply the patch."

# ------------------------------------------------------------------ build deps
install_build_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    if ! grep -rqs --include='*.list' --include='*.sources' -e '^deb-src' -e '^Types:.*deb-src' \
         /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
      log "Enabling source repositories (deb-src)..."
      codename="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")"
      if [ -n "$codename" ]; then
        cat > /etc/apt/sources.list.d/xfwm4-scroll-workspace-src.list <<EOF
deb-src http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware
EOF
        apt-get update -o Acquire::Languages=none
      fi
    fi
    log "Installing build dependencies (apt-get build-dep xfwm4)..."
    DEBIAN_FRONTEND=noninteractive apt-get build-dep -y xfwm4 \
      || warn "apt-get build-dep failed; will try explicit -dev packages."
    # explicit fallback (harmless if already present)
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential pkg-config gettext autopoint intltool patch \
      libgtk-3-dev libxfce4ui-2-dev libxfce4util-dev libxfconf-0-dev \
      libwnck-3-dev libx11-dev libxinerama-dev libxi-dev libxres-dev libxext-dev \
      libepoxy-dev libstartup-notification0-dev libxrender-dev libxcomposite-dev \
      libxdamage-dev libxfixes-dev libxrandr-dev libxpresent-dev libpng-dev >/dev/null 2>&1 || true
  else
    warn "Non-apt system: make sure the xfwm4 build dependencies are installed."
    for t in curl tar patch gcc make pkg-config meson ninja; do
      command -v "$t" >/dev/null 2>&1 || warn "missing tool: $t"
    done
  fi
}
install_build_deps

# ------------------------------------------------------------------ build
log "Building xfwm4-$TARGET (with the patch)..."
BUILT=""
cd "$SRC"
if [ -x ./configure ]; then
  ./configure --prefix=/usr --enable-xpresent CFLAGS="-O2" >"$WORK/configure.log" 2>&1 \
    || { err "configure failed. See $WORK/configure.log"; tail -n20 "$WORK/configure.log" >&2; die "configure failed"; }
  make -j"$(nproc 2>/dev/null || echo 2)" >"$WORK/build.log" 2>&1 \
    || { err "build failed. See $WORK/build.log"; tail -n20 "$WORK/build.log" >&2; die "make failed"; }
  BUILT="$SRC/src/xfwm4"
elif [ -f meson.build ]; then
  command -v meson >/dev/null 2>&1 || die "meson is required to build this version."
  meson setup build -Dbuildtype=release >"$WORK/configure.log" 2>&1 \
    || { err "meson setup failed."; tail -n20 "$WORK/configure.log" >&2; die "meson setup failed"; }
  meson compile -C build >"$WORK/build.log" 2>&1 \
    || { err "build failed. See $WORK/build.log"; tail -n20 "$WORK/build.log" >&2; die "meson build failed"; }
  BUILT="$SRC/build/src/xfwm4"
else
  die "Unknown build system in the source tree."
fi
[ -x "$BUILT" ] || die "Build produced no xfwm4 binary."

# ------------------------------------------------------------------ install
log "Installing the patched binary..."
if [ ! -f "$BACKUP" ]; then
  cp -a "$BIN" "$BACKUP"
  log "Original binary backed up to $BACKUP"
fi
install -m 0755 "$BUILT" "$BIN"
mkdir -p "$MARKER_DIR"
{
  printf 'version=%s\n' "$TARGET"
  printf 'sha256=%s\n' "$(sha256_of "$BIN")"
  printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MARKER"
ok "Installed. Restart xfwm4 (or log out/in) for it to take effect."

# ------------------------------------------------------------------ restart
restart_wm

cat <<EOF

${C_GRN}Done.${C_RESET} Now, while dragging a window, use the mouse wheel to switch workspace
and carry the window along (wheel down = next, wheel up = previous).

  Uninstall : curl -fsSL ${RAW_BASE}/install.sh | sudo bash -s -- --uninstall
  Check     : curl -fsSL ${RAW_BASE}/install.sh | sudo bash -s -- --check
EOF
