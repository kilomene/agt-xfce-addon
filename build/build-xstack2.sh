#!/bin/bash
# Tranche 2 of the XFCE add-on X stack: fonts, freetype, fontconfig,
# Xfont2, the X server (Xvfb only), xkeyboard data, png/jpeg,
# libvncserver, x11vnc, plus the vendored viewer assets (websockify
# and noVNC) that land in the add-on source tree. Same rules as
# build-xstack.sh: from source, bionic aarch64, add-on prefix,
# resumable via $STACK/done.txt, stop at first failure.
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
XROOT="$DEST$XPREFIX"
BSTAGE="$NB/stage/usr"
ADDON_SRC="$HOME/workspace/agt-phoenix/addon-sources/xfce"
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
if [ -x "$STACK/hosttools/bin/pkg-config" ]; then
  PKGCFG="$STACK/hosttools/bin/pkg-config"
else
  PKGCFG="$STACK/hostbin/pkg-config"
fi
export PATH="$STACK/hosttools/bin:$STACK/pylibs/bin:$STACK/hostbin:$XROOT/bin:$PATH"
export PYTHONPATH="$STACK/pylibs${PYTHONPATH:+:$PYTHONPATH}"
export PKG_CONFIG="$PKGCFG"

# Meson cross file for the Android target (mirrors build-gtk.sh;
# xkeyboard-config 2.42 is meson-only, no configure script).
cat > "$STACK/android-cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
ranlib = '$RANLIB'
strip = '$STRIP'
pkg-config = '$PKGCFG'
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

# fontconfig's build runs gperf on the host; build it first if missing.
if ! command -v gperf >/dev/null 2>&1; then
  "$NB/build-host-tools.sh" || exit 1
fi

# Same build-time .pc mirror as build-xstack.sh (see its comment).
sync_buildpc() {
  mkdir -p "$STACK/buildpc"
  local pc la
  for pc in "$XROOT"/lib/pkgconfig/*.pc "$XROOT"/share/pkgconfig/*.pc; do
    [ -f "$pc" ] && sed "s|$XPREFIX|$XROOT|g" "$pc" > "$STACK/buildpc/$(basename "$pc")"
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
  # Bionic defines no NOFILES_MAX, NOFILE or OPEN_MAX, so libXfont2's
  # fslibos.h falls through to OPEN_MAX = NOFILES_MAX and fails to
  # compile. Give it the same 256 fallback the file already uses for
  # SVR4/OSF1. Applied to the fresh extract each run, so re-running
  # the script is safe.
  if [ "$name" = libXfont2 ]; then
    sed -i 's|#       define OPEN_MAX NOFILES_MAX|#       define OPEN_MAX 256|' src/fc/fslibos.h || return 1
  fi
  # Android has no /tmp: the X server lock file lives in /tmp by
  # default (LOCK_DIR in os/utils.c) and the server dies creating
  # it. Move it into the add-on's own var dir. (-nolock exists but
  # the server honours it for root only; the app uid is not root.)
  if [ "$name" = xorg-server ]; then
    sed -i "s|#define LOCK_DIR \"/tmp\"|#define LOCK_DIR \"$XVAR\"|" os/utils.c || return 1
    # Android app storage denies hard links outright (ln fails
    # with EACCES everywhere under files/, F2FS inlinecrypt), and
    # LockServer's link() step is the only hard-link user. Swap it
    # for an existence check plus rename(), which works on this
    # storage (agt-xfce's os.replace proves it); the EEXIST branch
    # of the same loop still handles stale-lock validation.
    sed -i "s|haslock = (link(tmp, LockFile) == 0);|haslock = (access(LockFile, F_OK) == 0 ? (errno = EEXIST, 0) : rename(tmp, LockFile) == 0);|" os/utils.c || return 1
    grep -q "rename(tmp, LockFile)" os/utils.c || return 1
    # Android's app seccomp filter kills the setuid/setgid syscalls
    # with SIGSYS even when they are identity no-ops (proven on the
    # phone: python os.setuid(os.getuid()) dies, exit 159). The
    # server's spawn helpers (Popen and friends in os/utils.c) call
    # exactly those before execl("/bin/sh", ...) to run xkbcomp, so
    # every keymap compile died as a "bad system call" and keyboard
    # init failed fatally. The calls only drop privileges the app
    # process never had; neutralise all three identity pairs.
    sed -i -e 's|if (setgid(getgid()) == -1)|if (0)|g' \
           -e 's|if (setuid(getuid()) == -1)|if (0)|g' os/utils.c || return 1
    if grep -q "setgid(getgid())" os/utils.c; then return 1; fi
  fi
  # x11vnc's bundled ssl helper scripts hard-code the socket dir
  # when hunting for the display; point them at the same place.
  if [ "$name" = x11vnc ]; then
    grep -rl '/tmp/\.X11-unix' src --include='*.h' --include='*.c' 2>/dev/null | xargs -r sed -i "s|/tmp/\.X11-unix|$XVAR/.X11-unix|g"
  fi
  # GitHub archive tarballs of autotools projects ship no generated
  # configure script (x11vnc 0.9.16): build it with autoreconf first.
  # Host autotools are installed on the VM (autoconf/automake/libtool).
  if [ ! -x ./configure ] && [ -f configure.ac ]; then
    autoreconf -fi > "$LOGS/$name.log" 2>&1 || { echo "AUTORECONF FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  fi
  # x11vnc 0.9.16 is old C code that defines the same globals
  # (clientMutex, inputMutex, pointerMutex) in a header included by
  # many files. Modern clang defaults to -fno-common, so the link
  # fails with duplicate symbols. -fcommon restores the old
  # behaviour for this package only.
  local save_cflags="$CFLAGS"
  if [ "$name" = x11vnc ]; then export CFLAGS="$CFLAGS -fcommon"; fi
  if [ -x ./configure ]; then
    ./configure --host=aarch64-linux-android --build=x86_64-pc-linux-gnu \
      --prefix="$XPREFIX" "$@" > "$LOGS/$name.log" 2>&1 || { echo "CONFIGURE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  else
    echo "NO CONFIGURE: $name" | tee -a "$LOGS/$name.log"; return 1
  fi
  # The X font packages run bdftopcf and ucs2any on the host at build
  # time, but their Makefiles hard-code the staged aarch64 paths,
  # which cannot execute here. Override with the host-native copies
  # in hostbin (built by build-host-tools.sh).
  local make_vars=()
  case "$name" in
    font-*) make_vars=(BDFTOPCF="$STACK/hostbin/bdftopcf" UCS2ANY="$STACK/hostbin/ucs2any") ;;
  esac
  make -j3 "${make_vars[@]}" >> "$LOGS/$name.log" 2>&1 || { echo "MAKE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make install DESTDIR="$DEST" >> "$LOGS/$name.log" 2>&1 || { echo "INSTALL FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  export CFLAGS="$save_cflags"
  sync_buildpc
  mark_done "$name"
  echo "done $name"
}

build_cmake() {
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

# Meson packages (xkeyboard-config 2.42 ships no configure script).
build_meson() {
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

XORG="https://www.x.org/releases/individual"

# --- fonts and text ---
build_at libfontenc libfontenc-1.1.8.tar.xz "$XORG/lib/libfontenc-1.1.8.tar.xz" || exit 1
build_at freetype freetype-2.13.3.tar.xz "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz" \
  --enable-shared --disable-static --without-png --without-harfbuzz --without-brotli --without-bzip2 || exit 1
build_at fontconfig fontconfig-2.14.2.tar.xz "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.14.2.tar.xz" \
  --enable-shared --disable-static --disable-docs --with-cache-dir="$XPREFIX/var/cache/fontconfig" || exit 1
build_at libXfont2 libXfont2-2.0.6.tar.xz "$XORG/lib/libXfont2-2.0.6.tar.xz" || exit 1
build_at font-util font-util-1.4.1.tar.xz "$XORG/font/font-util-1.4.1.tar.xz" || exit 1
build_at bdftopcf bdftopcf-1.1.tar.gz "$XORG/app/bdftopcf-1.1.tar.gz" || exit 1
build_at mkfontscale mkfontscale-1.2.3.tar.xz "$XORG/app/mkfontscale-1.2.3.tar.xz" || exit 1
# font-misc-misc and font-cursor-misc run bdftopcf/ucs2any on the host;
# make sure the host-native copies exist before building them.
"$NB/build-host-tools.sh" || exit 1
build_at font-misc-misc font-misc-misc-1.1.3.tar.xz "$XORG/font/font-misc-misc-1.1.3.tar.xz" || exit 1
build_at font-cursor-misc font-cursor-misc-1.0.4.tar.xz "$XORG/font/font-cursor-misc-1.0.4.tar.xz" || exit 1
# xkeyboard-config 2.42 is meson-only (no configure script).
build_meson xkeyboard-config xkeyboard-config-2.42.tar.xz "$XORG/data/xkeyboard-config/xkeyboard-config-2.42.tar.xz" \
  -Dxkb-base="$XPREFIX/share/X11/xkb" -Dnls=false || exit 1

# xorg-server 21.1.13 configure requires libxcvt and it was never in
# the stack, so build it first (meson, no dependencies of its own).
build_meson libxcvt libxcvt-0.1.2.tar.xz "$XORG/lib/libxcvt-0.1.2.tar.xz" || exit 1

# --- the X server: Xvfb only ---
build_at xorg-server xorg-server-21.1.13.tar.xz "$XORG/xserver/xorg-server-21.1.13.tar.xz" \
  --enable-xvfb --disable-xorg --disable-xephyr --disable-xnest \
  --disable-xquartz --disable-xwin --disable-xwayland \
  --disable-glx --disable-dri --disable-dri2 --disable-dri3 \
  --enable-present --disable-xdmcp --disable-xvmc --disable-screensaver \
  --with-sha1=libcrypto \
  --with-xkb-path="$XPREFIX/share/X11/xkb" \
  --with-xkb-bin-directory="$XPREFIX/bin" \
  --with-xkb-output-dir="$XPREFIX/var/lib/xkb" \
  --with-default-font-path="$XPREFIX/share/fonts/X11/misc,$XPREFIX/share/fonts/X11/TTF" \
  --disable-docs --disable-devel-docs --disable-unit-tests || exit 1

# --- image libs and VNC ---
build_at libpng libpng-1.6.43.tar.xz "https://download.sourceforge.net/libpng/libpng-1.6.43.tar.xz" \
  --enable-shared --disable-static || exit 1
build_cmake libjpeg-turbo libjpeg-turbo-3.0.4.tar.gz "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.0.4/libjpeg-turbo-3.0.4.tar.gz" \
  -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF || exit 1
build_cmake libvncserver LibVNCServer-0.9.14.tar.gz "https://github.com/LibVNC/libvncserver/archive/refs/tags/LibVNCServer-0.9.14.tar.gz" \
  -DWITH_OPENSSL=ON -DWITH_GCRYPT=OFF -DWITH_GNUTLS=OFF \
  -DWITH_JPEG=ON -DWITH_PNG=ON -DWITH_ZLIB=ON \
  -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF -DBUILD_SHARED_LIBS=ON || exit 1
build_at x11vnc x11vnc-0.9.16.tar.gz "https://github.com/LibVNC/x11vnc/archive/refs/tags/0.9.16.tar.gz" || exit 1

# --- dejavu fonts (data only) ---
if ! is_done dejavu; then
  echo "=== dejavu ==="
  fetch dejavu-fonts-ttf-2.37.zip "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.zip" || exit 1
  cd "$SRC" && rm -rf dejavu-x && mkdir dejavu-x && cd dejavu-x
  unzip -q "$SRC/dejavu-fonts-ttf-2.37.zip" || exit 1
  mkdir -p "$XROOT/share/fonts/truetype/dejavu"
  cp dejavu-fonts-ttf-2.37/ttf/*.ttf "$XROOT/share/fonts/truetype/dejavu/" || exit 1
  mark_done dejavu
  echo "done dejavu"
fi

# --- viewer assets: websockify + noVNC into the add-on tree ---
if ! is_done websockify; then
  echo "=== websockify ==="
  fetch websockify-0.12.0.tar.gz "https://github.com/novnc/websockify/archive/refs/tags/v0.12.0.tar.gz" || exit 1
  cd "$SRC" && rm -rf ws-x && mkdir ws-x
  tar xf websockify-0.12.0.tar.gz -C ws-x --strip-components=1 || exit 1
  rm -rf "$ADDON_SRC/share/xview/websockify"
  cp -r ws-x/websockify "$ADDON_SRC/share/xview/websockify" || exit 1
  cat > "$ADDON_SRC/bin/websockify" <<'WRAP'
#!/bin/sh
# websockify launcher inside the XFCE add-on: runs the vendored
# python package with the phone's python3.
ADDON=/data/data/com.novainc.agt/files/addons/xfce
PYTHONPATH="$ADDON/share/xview" exec /data/data/com.novainc.agt/files/usr/bin/python3 \
  -m websockify.websockify "$@"
WRAP
  chmod +x "$ADDON_SRC/bin/websockify"
  mark_done websockify
  echo "done websockify"
fi

if ! is_done novnc; then
  echo "=== novnc ==="
  fetch noVNC-1.4.0.tar.gz "https://github.com/novnc/noVNC/archive/refs/tags/v1.4.0.tar.gz" || exit 1
  cd "$SRC" && rm -rf novnc-x && mkdir novnc-x
  tar xf noVNC-1.4.0.tar.gz -C novnc-x --strip-components=1 || exit 1
  mkdir -p "$ADDON_SRC/share/xview/web"
  cp novnc-x/vnc.html novnc-x/vnc_lite.html "$ADDON_SRC/share/xview/web/" || exit 1
  cp -r novnc-x/app novnc-x/core novnc-x/vendor "$ADDON_SRC/share/xview/web/" || exit 1
  mark_done novnc
  echo "done novnc"
fi

echo "TRANCHE 2 DONE"
