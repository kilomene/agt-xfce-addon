#!/bin/bash
# Build the X stack for the XFCE add-on, from source, for Android
# (bionic), aarch64, the AGT way: same NDK toolchain and treatment
# as the bootstrap builds, nothing here is a Termux binary and no
# prebuilt package is used. The stack's compiled-in prefix is the
# add-on's own root on the phone:
#   /data/data/com.novainc.agt/files/addons/xfce
# so the add-on is self-contained and survives bootstrap reinstalls.
#
# Resumable: finished packages are recorded in $STACK/done.txt and
# skipped on rerun. The build stops at the first failing package;
# its log is $STACK/logs/<pkg>.log. Rerun to continue.
set -u
NB="$HOME/workspace/Agt-tools/native-build"
STACK="$NB/xfce-stack"
SRC="$STACK/src"
DEST="$STACK/dest"
LOGS="$STACK/logs"
DONE="$STACK/done.txt"
NDK="$HOME/workspace/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_ROOT="$HOME/workspace/android-sdk/ndk/28.2.13676358"
XPREFIX="/data/data/com.novainc.agt/files/addons/xfce"
XVAR="$XPREFIX/var"   # runtime socket/lock dir: Android has no /tmp
BPREFIX="/data/data/com.novainc.agt/files/usr"
XROOT="$DEST$XPREFIX"          # staged add-on root (dev view)
BSTAGE="$NB/stage/usr"         # bootstrap stage (openssl, zlib)
export TMPDIR="$STACK/.tmp"
mkdir -p "$SRC" "$DEST" "$LOGS" "$TMPDIR" "$XROOT"

export CC="$NDK/aarch64-linux-android26-clang"
export CXX="$NDK/aarch64-linux-android26-clang++"
export AR="$NDK/llvm-ar"
export RANLIB="$NDK/llvm-ranlib"
export STRIP="$NDK/llvm-strip"
export CFLAGS="-O2 -fPIC"
export xorg_cv_malloc0_returns_null=no
export CXXFLAGS="-O2 -fPIC"
export CPPFLAGS="-I$XROOT/include -I$BSTAGE/include"
export LDFLAGS="-L$XROOT/lib -L$BSTAGE/lib -L$STACK/stublib -Wl,-rpath,$XPREFIX/lib -Wl,-rpath,$BPREFIX/lib"
export PKG_CONFIG_PATH="$STACK/buildpc:$XROOT/lib/pkgconfig:$XROOT/share/pkgconfig:$BSTAGE/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export PATH="$STACK/hosttools/bin:$STACK/pylibs/bin:$STACK/hostbin:$XROOT/bin:$PATH"
export PYTHONPATH="$STACK/pylibs${PYTHONPATH:+:$PYTHONPATH}"
if [ -x "$STACK/hosttools/bin/pkg-config" ]; then
  export PKG_CONFIG="$STACK/hosttools/bin/pkg-config"
else
  export PKG_CONFIG="$STACK/hostbin/pkg-config"
fi

# Build-time .pc mirror: staged .pc files name the FINAL phone
# prefix, but consumers at build time (libxcb reading xcb-proto's
# data dir, xcbgen, include subdirs) need the files where DESTDIR
# actually put them. Keep a rewritten copy of every staged .pc in
# $STACK/buildpc with the final prefix replaced by the staged
# root, and let it win PKG_CONFIG_PATH. These never ship.
sync_buildpc() {
  mkdir -p "$STACK/buildpc"
  local pc la
  for pc in "$XROOT"/lib/pkgconfig/*.pc "$XROOT"/share/pkgconfig/*.pc; do
    [ -f "$pc" ] && sed "s|$XPREFIX|$XROOT|g" "$pc" > "$STACK/buildpc/$(basename "$pc")"
  done
  # Staged .la files record the final phone libdir; libtool reads
  # them at the next package's link step and fails on this machine.
  # Rewrite them to the staged root (they never ship).
  for la in "$XROOT"/lib/*.la; do
    [ -f "$la" ] && sed -i -e "s|$XROOT|@@AGT_XROOT@@|g" -e "s|$XPREFIX|$XROOT|g" -e "s|@@AGT_XROOT@@|$XROOT|g" "$la"
  done
}
sync_buildpc

# pkg-config: use the host's if present, else a shim that answers
# from the .pc files on PKG_CONFIG_PATH (all this chain needs).
if ! command -v pkg-config >/dev/null 2>&1; then
  mkdir -p "$STACK/hostbin"
  cat > "$STACK/hostbin/pkg-config" <<'SHIM'
#!/usr/bin/env python3
import os, re, sys
paths = (os.environ.get("PKG_CONFIG_PATH") or "").split(":")
def find(name):
    for d in paths:
        p = os.path.join(d, name + ".pc")
        if os.path.isfile(p):
            return p
    return None
def load(name, seen=None):
    seen = seen or set()
    if name in seen: return {}
    seen.add(name)
    p = find(name)
    if not p: sys.exit("pkg-config shim: no such package: " + name)
    vars, fields = {}, {}
    for line in open(p):
        line = line.rstrip("\n")
        m = re.match(r"^([A-Za-z0-9_.]+)=(.*)$", line)
        if m: vars[m.group(1)] = m.group(2); continue
        m = re.match(r"^([A-Za-z ]+):\s*(.*)$", line)
        if m: fields[m.group(1)] = m.group(2)
    def expand(s, depth=0):
        if depth > 10: return s
        return re.sub(r"\$\{([^}]+)\}", lambda m: expand(vars.get(m.group(1), ""), depth+1), s)
    out = {k: expand(v) for k, v in fields.items()}
    out["_vars"] = {k: expand(v) for k, v in vars.items()}
    reqs = []
    for key in ("Requires", "Requires.private"):
        for tok in re.split(r"[,\s]+", out.get(key, "")):
            if tok and not re.match(r"^[<>=!]+$", tok) and not re.match(r"^[0-9.]+$", tok):
                reqs.append(tok)
    out["_reqs"] = reqs
    return out
def collect(pkgs, key):
    vals, seen = [], set()
    def visit(name):
        info = load(name)
        for r in info["_reqs"]: visit(r)
        for tok in info.get(key, "").split():
            if tok not in seen: seen.add(tok); vals.append(tok)
    for p in pkgs: visit(p)
    return vals
args = sys.argv[1:]
pkgs = [a for a in args if not a.startswith("-")]
flags = [a for a in args if a.startswith("-")]
if "--modversion" in flags:
    for p in pkgs: print(load(p).get("Version", ""))
elif "--variable" in flags:
    var = flags[flags.index("--variable") + 1] if False else None
    varname = None
    for i, a in enumerate(args):
        if a == "--variable" and i + 1 < len(args): varname = args[i+1]
    for p in pkgs: print(load(p)["_vars"].get(varname, ""))
elif "--cflags" in flags:
    print(" ".join(collect(pkgs, "Cflags")))
elif "--libs" in flags:
    print(" ".join(collect(pkgs, "Libs") + (collect(pkgs, "Libs.private") if "--static" in flags else [])))
elif "--exists" in flags or "--atleast-version" in flags:
    for p in pkgs: load(p)
else:
    for p in pkgs: load(p)
SHIM
  chmod +x "$STACK/hostbin/pkg-config"
  export PATH="$STACK/hostbin:$PATH"
fi

fetch() { # fetch <file> <url>
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

build_at() { # build_at <name> <tarball> <url> [configure args...]
  local name="$1" tb="$2" url="$3"; shift 3
  if is_done "$name"; then echo "skip $name (done)"; return 0; fi
  echo "=== $name ==="
  fetch "$tb" "$url" || return 1
  cd "$SRC" || return 1
  rm -rf "$name-src"
  mkdir "$name-src"
  tar xf "$tb" -C "$name-src" --strip-components=1 || return 1
  cd "$name-src" || return 1
  if declare -F "patch_$name" >/dev/null 2>&1; then "patch_$name" || return 1; fi
  if [ -x ./configure ]; then
    ./configure --host=aarch64-linux-android --build=x86_64-pc-linux-gnu \
      --prefix="$XPREFIX" "$@" > "$LOGS/$name.log" 2>&1 || { echo "CONFIGURE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  elif [ -f ./meson.build ]; then
    echo "MESON PACKAGE NOT WIRED: $name" | tee -a "$LOGS/$name.log"; return 1
  else
    echo "NO BUILD SYSTEM: $name" | tee -a "$LOGS/$name.log"; return 1
  fi
  make -j3 >> "$LOGS/$name.log" 2>&1 || { echo "MAKE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make install DESTDIR="$DEST" >> "$LOGS/$name.log" 2>&1 || { echo "INSTALL FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  sync_buildpc
  mark_done "$name"
  echo "done $name"
}

build_cmake() { # build_cmake <name> <tarball> <url> [cmake -D args...]
  local name="$1" tb="$2" url="$3"; shift 3
  if is_done "$name"; then echo "skip $name (done)"; return 0; fi
  echo "=== $name ==="
  fetch "$tb" "$url" || return 1
  cd "$SRC" || return 1
  rm -rf "$name-src"
  mkdir "$name-src"
  tar xf "$tb" -C "$name-src" --strip-components=1 || return 1
  cd "$name-src" || return 1
  cmake -S . -B build \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=26 \
    -DCMAKE_INSTALL_PREFIX="$XPREFIX" \
    -DCMAKE_PREFIX_PATH="$XROOT;$BSTAGE" \
    -DCMAKE_BUILD_TYPE=Release "$@" > "$LOGS/$name.log" 2>&1 || { echo "CMAKE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  cmake --build build -j3 >> "$LOGS/$name.log" 2>&1 || { echo "CMAKE BUILD FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  DESTDIR="$DEST" cmake --install build >> "$LOGS/$name.log" 2>&1 || { echo "CMAKE INSTALL FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  sync_buildpc
  mark_done "$name"
  echo "done $name"
}

XORG="https://www.x.org/releases/individual"

# --- tranche 1: proto, xcb, X11 core ---
# Meson cross file (same content build-gtk.sh generates) and a
# meson builder, for the meson-only packages in this tranche.
cat > "$STACK/android-cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
ranlib = '$RANLIB'
strip = '$STRIP'
pkg-config = '$PKG_CONFIG'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-I$XROOT/include', '-I$BSTAGE/include']
cpp_args = ['-I$XROOT/include', '-I$BSTAGE/include']
c_link_args = ['-L$XROOT/lib', '-L$BSTAGE/lib', '-L$STACK/stublib -Wl,-rpath,$XPREFIX/lib', '-Wl,-rpath,$BPREFIX/lib']
cpp_link_args = ['-L$XROOT/lib', '-L$BSTAGE/lib', '-L$STACK/stublib -Wl,-rpath,$XPREFIX/lib', '-Wl,-rpath,$BPREFIX/lib']
EOF

build_meson() { # build_meson <name> <tarball> <url> [meson -D args...]
  local name="$1" tb="$2" url="$3"; shift 3
  if is_done "$name"; then echo "skip $name (done)"; return 0; fi
  echo "=== $name ==="
  fetch "$tb" "$url" || return 1
  cd "$SRC" || return 1
  rm -rf "$name-src"
  mkdir "$name-src"
  tar xf "$tb" -C "$name-src" --strip-components=1 || return 1
  cd "$name-src" || return 1
  meson setup build --cross-file "$STACK/android-cross.txt" \
    --prefix="$XPREFIX" --libdir=lib --libexecdir=libexec \
    --buildtype=release "$@" > "$LOGS/$name.log" 2>&1 || { echo "MESON SETUP FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  meson compile -C build -j3 >> "$LOGS/$name.log" 2>&1 || { echo "MESON COMPILE FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  DESTDIR="$DEST" meson install -C build --no-rebuild >> "$LOGS/$name.log" 2>&1 || { echo "MESON INSTALL FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  sync_buildpc
  mark_done "$name"
  echo "done $name"
}

# Android has no /tmp at all, so every hard-coded /tmp unix-socket
# path in the X stack moves into the add-on's own var dir. xtrans is
# compiled into its consumers (X server, libICE), so patching it
# here and rebuilding those consumers propagates the path.
patch_xtrans() {
  sed -i -e "s|/tmp/\.X11-unix|$XVAR/.X11-unix|g" \
         -e "s|/tmp/\.ICE-unix|$XVAR/.ICE-unix|g" \
         -e "s|/tmp/\.font-unix|$XVAR/.font-unix|g" \
         -e "s|/tmp/\.XIM-unix|$XVAR/.XIM-unix|g" Xtranssock.c || return 1
}
patch_libxcb() {
  sed -i "s|/tmp/\.X11-unix|$XVAR/.X11-unix|g" src/xcb_util.c || return 1
}

build_at xorgproto xorgproto-2024.1.tar.xz "$XORG/proto/xorgproto-2024.1.tar.xz" || exit 1
build_at xtrans xtrans-1.5.2.tar.xz "$XORG/lib/xtrans-1.5.2.tar.xz" || exit 1
build_at libXau libXau-1.0.11.tar.xz "$XORG/lib/libXau-1.0.11.tar.xz" || exit 1
build_at libXdmcp libXdmcp-1.1.5.tar.xz "$XORG/lib/libXdmcp-1.1.5.tar.xz" || exit 1
build_at xcb-proto xcb-proto-1.17.0.tar.xz "$XORG/proto/xcb-proto-1.17.0.tar.xz" || exit 1
build_at libxcb libxcb-1.17.0.tar.xz "$XORG/lib/libxcb-1.17.0.tar.xz" --enable-xinput --enable-xkb || exit 1
build_meson pixman pixman-0.43.4.tar.xz "$XORG/lib/pixman-0.43.4.tar.xz" -Dgtk=disabled -Dlibpng=disabled -Dtests=disabled -Ddemos=disabled -Dopenmp=disabled || exit 1
build_at libX11 libX11-1.8.10.tar.xz "$XORG/lib/libX11-1.8.10.tar.xz" --disable-specs || exit 1
build_at libXext libXext-1.3.6.tar.xz "$XORG/lib/libXext-1.3.6.tar.xz" --disable-specs || exit 1
build_at libXrender libXrender-0.9.11.tar.xz "$XORG/lib/libXrender-0.9.11.tar.xz" || exit 1
build_at libXfixes libXfixes-6.0.1.tar.xz "$XORG/lib/libXfixes-6.0.1.tar.xz" || exit 1
build_at libXdamage libXdamage-1.1.6.tar.xz "$XORG/lib/libXdamage-1.1.6.tar.xz" || exit 1
build_at libXrandr libXrandr-1.5.4.tar.xz "$XORG/lib/libXrandr-1.5.4.tar.xz" || exit 1
build_at libXcomposite libXcomposite-0.4.6.tar.xz "$XORG/lib/libXcomposite-0.4.6.tar.xz" || exit 1
build_at libXi libXi-1.8.1.tar.xz "$XORG/lib/libXi-1.8.1.tar.xz" --disable-specs || exit 1
build_at libXtst libXtst-1.2.4.tar.xz "$XORG/lib/libXtst-1.2.4.tar.xz" --disable-specs || exit 1
build_at libXcursor libXcursor-1.2.2.tar.xz "$XORG/lib/libXcursor-1.2.2.tar.xz" || exit 1
build_at libXinerama libXinerama-1.1.5.tar.xz "$XORG/lib/libXinerama-1.1.5.tar.xz" || exit 1
build_at libxkbfile libxkbfile-1.1.3.tar.xz "$XORG/lib/libxkbfile-1.1.3.tar.xz" || exit 1
build_at xkbcomp xkbcomp-1.4.7.tar.xz "$XORG/app/xkbcomp-1.4.7.tar.xz" || exit 1

echo "TRANCHE 1 DONE"
