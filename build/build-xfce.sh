#!/bin/bash
# Tranche 4 of the XFCE add-on stack: XFCE 4.18 itself, built from
# source for bionic aarch64 into the add-on prefix. Same rules as
# the earlier tranches: resumable via done.txt, stop at first
# failure, per-package logs in $STACK/logs.
set -u
NB="$HOME/workspace/Agt-tools/native-build"
STACK="$NB/xfce-stack"
SRC="$STACK/src"
DEST="$STACK/dest"
LOGS="$STACK/logs"
DONE="$STACK/done.txt"
NDK="$HOME/workspace/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin"
XPREFIX="/data/data/com.novainc.agt/files/addons/xfce"
BPREFIX="/data/data/com.novainc.agt/files/usr"
XROOT="$DEST$XPREFIX"
BSTAGE="$NB/stage/usr"
export TMPDIR="$STACK/.tmp"
mkdir -p "$SRC" "$DEST" "$LOGS" "$TMPDIR" "$XROOT"

export CC="$NDK/aarch64-linux-android26-clang"
export CXX="$NDK/aarch64-linux-android26-clang++"
export AR="$NDK/llvm-ar"
export RANLIB="$NDK/llvm-ranlib"
export STRIP="$NDK/llvm-strip"
export CFLAGS="-O2 -fPIC"
export xorg_cv_malloc0_returns_null=no
# startup-notification's configure runs a realloc(NULL) test program,
# which cannot run while cross compiling; bionic's realloc behaves
# like malloc on NULL, so preset the cache answer.
export lf_cv_sane_realloc=yes
export CXXFLAGS="-O2 -fPIC"
export CPPFLAGS="-I$XROOT/include -I$BSTAGE/include"
export LDFLAGS="-L$XROOT/lib -L$BSTAGE/lib -L$STACK/stublib -Wl,-rpath,$XPREFIX/lib -Wl,-rpath,$BPREFIX/lib -ldl"
# -ldl: libX11.so carries undefined dlopen/dlsym (it was linked against
# the old empty stub libdl.a, now removed so -ldl finds the NDK sysroot
# libdl.so). Every later link must pull it in or lld refuses the
# executable with --no-allow-shlib-undefined.
export PKG_CONFIG_PATH="$STACK/buildpc:$XROOT/lib/pkgconfig:$XROOT/share/pkgconfig:$BSTAGE/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
if [ -x "$STACK/hosttools/bin/pkg-config" ]; then
  export PKG_CONFIG="$STACK/hosttools/bin/pkg-config"
else
  export PKG_CONFIG="$STACK/hostbin/pkg-config"
fi
export PATH="$STACK/hosttools/bin:$STACK/pylibs/bin:$STACK/hostbin:$XROOT/bin:$PATH"
# meson only runs with PYTHONPATH pointing at the pip-installed libs.
export PYTHONPATH="$STACK/pylibs${PYTHONPATH:+:$PYTHONPATH}"
# Build-time code generators must be the host's native tools. The
# target prefix holds aarch64 binaries that cannot run on this
# machine, and Meson/autotools would otherwise pick them up through
# $XROOT/bin on PATH and fail with "Exec format error".
# Host packages that provide them: libglib2.0-bin, libgdk-pixbuf2.0-bin,
# libxml2-utils (apt install them on a fresh build machine).
mkdir -p "$STACK/hostbin"
for _t in glib-compile-resources glib-genmarshal glib-mkenums gdbus-codegen gdk-pixbuf-pixdata gdk-pixbuf-csource gdk-pixbuf-thumbnailer xmllint; do
  if [ -x "/usr/bin/$_t" ] && [ ! -e "$STACK/hostbin/$_t" ]; then
    ln -s "/usr/bin/$_t" "$STACK/hostbin/$_t"
  fi
done


sync_buildpc() {
  mkdir -p "$STACK/buildpc"
  local pc la
  for pc in "$XROOT"/lib/pkgconfig/*.pc "$XROOT"/share/pkgconfig/*.pc; do
    [ -f "$pc" ] && sed "s|$XPREFIX|$XROOT|g" "$pc" > "$STACK/buildpc/$(basename "$pc")"
  done
  # Code generators run on the build machine: point the .pc tool
  # variables at the host's native tools, never the aarch64 ones
  # (Meson reads these variables first and bakes the path in).
  for _tool in glib_compile_resources glib_compile_schemas gio_querymodules gdbus_codegen glib_genmarshal glib_mkenums gdk_pixbuf_pixdata gdk_pixbuf_csource; do
    _bin="/usr/bin/${_tool//_/-}"
    if [ -x "$_bin" ]; then
      sed -i "s|^${_tool}=.*|${_tool}=${_bin}|" "$STACK/buildpc"/gio-2.0.pc "$STACK/buildpc"/glib-2.0.pc "$STACK/buildpc"/gdk-pixbuf-2.0.pc 2>/dev/null
    fi
  done
  for la in "$XROOT"/lib/*.la; do
    [ -f "$la" ] && sed -i -e "s|$XROOT|@@AGT_XROOT@@|g" -e "s|$XPREFIX|$XROOT|g" -e "s|@@AGT_XROOT@@|$XROOT|g" "$la"
  done
}

sync_buildpc

fetch() {
  local f="$SRC/$1"
  if [ -s "$f" ]; then
    case "$f" in
      *.tar.*) tar -tf "$f" >/dev/null 2>&1 && return 0 ;;
      *.zip) unzip -t -q "$f" >/dev/null 2>&1 && return 0 ;;
      *) return 0 ;;
    esac
    echo "fetch: discarding truncated $1"
    rm -f "$f"
  fi
  for i in 1 2 3 4 5 6 7 8; do
    curl -L --fail --retry 3 -C - -o "$f" "$2" && return 0
    echo "fetch retry $i for $1" ; sleep 10
  done
  echo "FETCH FAILED: $1" ; return 1
}

is_done() { grep -qx "$1" "$DONE" 2>/dev/null; }
mark_done() { echo "$1" >> "$DONE"; }

build_at() {
  local name="$1" tb="$2" url="$3"; shift 3
  if is_done "$name"; then echo "skip $name (done)"; return 0; fi
  echo "=== $name ==="
  fetch "$tb" "$url" || return 1
  cd "$SRC" || return 1
  rm -rf "$name-src"
  mkdir "$name-src"
  tar xf "$tb" -C "$name-src" --strip-components=1 || return 1
  cd "$name-src" || return 1
  # Old tarballs ship a config.sub that predates Android triplets
  # (startup-notification 0.12: "machine aarch64 not recognized").
  # Refresh from the known-good pair vendored at $NB/config.sub.
  for _cs in config.sub config.guess; do
    [ -f "$_cs" ] && [ -f "$NB/$_cs" ] && cp "$NB/$_cs" "$_cs"
  done
  ./configure --host=aarch64-linux-android --build=x86_64-pc-linux-gnu \
    --prefix="$XPREFIX" "$@" > "$LOGS/$name.log" 2>&1 || { echo "CONFIGURE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make -j3 >> "$LOGS/$name.log" 2>&1 || { echo "MAKE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make install DESTDIR="$DEST" >> "$LOGS/$name.log" 2>&1 || { echo "INSTALL FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  sync_buildpc
  mark_done "$name"
  echo "done $name"
}

# libwnck 3.36 is Meson-only (no configure script), so it needs the
# Meson builder from the GTK tranche, not build_at.
prep_src() {
  local name="$1" tb="$2" url="$3"
  fetch "$tb" "$url" || return 1
  cd "$SRC" || return 1
  rm -rf "$name-src"
  mkdir "$name-src"
  tar xf "$tb" -C "$name-src" --strip-components=1 || return 1
  cd "$name-src" || return 1
}

build_meson() {
  local name="$1" tb="$2" url="$3"; shift 3
  if is_done "$name"; then echo "skip $name (done)"; return 0; fi
  echo "=== $name ==="
  prep_src "$name" "$tb" "$url" || return 1
  meson setup build --cross-file "$STACK/android-cross.txt" \
    --prefix="$XPREFIX" --libdir=lib --libexecdir=libexec \
    --buildtype=release "$@" > "$LOGS/$name.log" 2>&1 || { echo "MESON SETUP FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  meson compile -C build -j3 >> "$LOGS/$name.log" 2>&1 || { echo "MESON COMPILE FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  DESTDIR="$DEST" meson install -C build --no-rebuild >> "$LOGS/$name.log" 2>&1 || { echo "MESON INSTALL FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  sync_buildpc
  mark_done "$name"
  echo "done $name"
}

# Like build_at but for a prerequisite that is not one of the 68
# counted packages: installs into the prefix, never touches done.txt.
build_prereq() {
  local name="$1" tb="$2" url="$3" pcname="${4:-$1}"; shift 3
  if [ -f "$XROOT/lib/pkgconfig/$pcname.pc" ]; then echo "prereq $name present"; return 0; fi
  echo "=== prereq $name ==="
  fetch "$tb" "$url" || return 1
  cd "$SRC" || return 1
  rm -rf "$name-src"
  mkdir "$name-src"
  tar xf "$tb" -C "$name-src" --strip-components=1 || return 1
  cd "$name-src" || return 1
  for _cs in config.sub config.guess; do
    [ -f "$_cs" ] && [ -f "$NB/$_cs" ] && cp "$NB/$_cs" "$_cs"
  done
  ./configure --host=aarch64-linux-android --build=x86_64-pc-linux-gnu \
    --prefix="$XPREFIX" "$@" > "$LOGS/$name.log" 2>&1 || { echo "CONFIGURE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make -j3 >> "$LOGS/$name.log" 2>&1 || { echo "MAKE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make install DESTDIR="$DEST" >> "$LOGS/$name.log" 2>&1 || { echo "INSTALL FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  sync_buildpc
  echo "done prereq $name"
}

XFCE="https://archive.xfce.org/src/xfce"
GNOME="https://download.gnome.org/sources"

# startup-notification needs libxcb-aux, which no earlier tranche
# built. Build xcb-util as an uncounted prerequisite first.
build_prereq xcb-util xcb-util-0.4.1.tar.xz \
  "https://xcb.freedesktop.org/dist/xcb-util-0.4.1.tar.xz" xcb-aux || exit 1
# Like build_prereq but for a program that installs no .pc file
# (iceauth): the installed binary itself is the present marker.
build_prereq_prog() {
  local name="$1" tb="$2" url="$3"; shift 3
  if [ -x "$XROOT/bin/$name" ]; then echo "prereq $name present"; return 0; fi
  echo "=== prereq $name ==="
  fetch "$tb" "$url" || return 1
  cd "$SRC" || return 1
  rm -rf "$name-src"
  mkdir "$name-src"
  tar xf "$tb" -C "$name-src" --strip-components=1 || return 1
  cd "$name-src" || return 1
  for _cs in config.sub config.guess; do
    [ -f "$_cs" ] && [ -f "$NB/$_cs" ] && cp "$NB/$_cs" "$_cs"
  done
  ./configure --host=aarch64-linux-android --build=x86_64-pc-linux-gnu \
    --prefix="$XPREFIX" "$@" > "$LOGS/$name.log" 2>&1 || { echo "CONFIGURE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make -j3 >> "$LOGS/$name.log" 2>&1 || { echo "MAKE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make install DESTDIR="$DEST" >> "$LOGS/$name.log" 2>&1 || { echo "INSTALL FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  sync_buildpc
  echo "done prereq $name"
}

build_at startup-notification startup-notification-0.12.tar.gz \
  "https://www.freedesktop.org/software/startup-notification/releases/startup-notification-0.12.tar.gz" || exit 1
build_at libxfce4util libxfce4util-4.18.2.tar.bz2 "$XFCE/libxfce4util/4.18/libxfce4util-4.18.2.tar.bz2" \
  --disable-introspection || exit 1
build_at xfconf xfconf-4.18.3.tar.bz2 "$XFCE/xfconf/4.18/xfconf-4.18.3.tar.bz2" \
  --disable-introspection || exit 1
build_at libxfce4ui libxfce4ui-4.18.4.tar.bz2 "$XFCE/libxfce4ui/4.18/libxfce4ui-4.18.4.tar.bz2" \
  --disable-introspection --disable-gladeui || exit 1
build_at exo exo-4.18.0.tar.bz2 "$XFCE/exo/4.18/exo-4.18.0.tar.bz2" \
  --disable-introspection || exit 1
build_at garcon garcon-4.18.2.tar.bz2 "$XFCE/garcon/4.18/garcon-4.18.2.tar.bz2" \
  --disable-introspection || exit 1
build_meson libwnck libwnck-3.36.0.tar.xz "$GNOME/libwnck/3.36/libwnck-3.36.0.tar.xz" \
  -Dintrospection=disabled || exit 1
build_at thunar thunar-4.18.8.tar.bz2 "$XFCE/thunar/4.18/thunar-4.18.8.tar.bz2" \
  --disable-introspection --disable-gudev --disable-notifications || exit 1
build_at xfce4-panel xfce4-panel-4.18.4.tar.bz2 "$XFCE/xfce4-panel/4.18/xfce4-panel-4.18.4.tar.bz2" \
  --disable-introspection || exit 1
build_at xfwm4 xfwm4-4.18.0.tar.bz2 "$XFCE/xfwm4/4.18/xfwm4-4.18.0.tar.bz2" || exit 1
build_at xfdesktop xfdesktop-4.18.1.tar.bz2 "$XFCE/xfdesktop/4.18/xfdesktop-4.18.1.tar.bz2" \
  --disable-notifications || exit 1
# xfce4-session's configure refuses to run without the iceauth
# program in PATH; no earlier tranche built it. Uncounted prereq.
build_prereq_prog iceauth iceauth-1.0.9.tar.xz \
  "https://www.x.org/releases/individual/app/iceauth-1.0.9.tar.xz" || exit 1
build_at xfce4-session xfce4-session-4.18.4.tar.bz2 "$XFCE/xfce4-session/4.18/xfce4-session-4.18.4.tar.bz2" || exit 1
build_at xfce4-settings xfce4-settings-4.18.2.tar.bz2 "$XFCE/xfce4-settings/4.18/xfce4-settings-4.18.2.tar.bz2" || exit 1
build_at xfce4-appfinder xfce4-appfinder-4.18.0.tar.bz2 "$XFCE/xfce4-appfinder/4.18/xfce4-appfinder-4.18.0.tar.bz2" || exit 1

# DESTDIR leak scrub: xfce4-session's configure finds iceauth via
# PATH at build time, and the build PATH holds the STAGED bin dir,
# so the staged absolute path gets baked into the binary. On the
# phone that path does not exist, ICE auth setup fails, and every
# session client is rejected by the session manager (xfwm4, panel
# and xfdesktop all die). Rewrite the staged prefix to the phone
# prefix in place (shorter, NUL-padded) in the installed binary.
python3 - "$XROOT/bin/xfce4-session" "$XROOT" "$XPREFIX" <<'PYEOF' || exit 1
import sys
path, staged, phone = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
data = open(path, "rb").read()
if staged in data:
    data = data.replace(staged, phone + b"\x00" * (len(staged) - len(phone)))
    open(path, "wb").write(data)
    print("scrubbed staged prefix in", path)
PYEOF

echo "TRANCHE 4 DONE"
