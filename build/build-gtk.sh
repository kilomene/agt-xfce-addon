#!/bin/bash
# Tranche 3 of the XFCE add-on stack: session/X libs, dbus, and the
# GTK stack (glib, cairo, pango, gdk-pixbuf, atk, epoxy, gtk3),
# built from source for bionic aarch64 into the add-on prefix.
# Same rules as the earlier tranches: resumable via done.txt,
# stop at first failure, per-package logs in $STACK/logs.
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

export PYTHONPATH="$STACK/pylibs${PYTHONPATH:+:$PYTHONPATH}"
export PKG_CONFIG="$PKGCFG"

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

# EGL/GLES .pc files pointing at the NDK sysroot, so libepoxy can
# find the phone's system GL libraries at build time. Build aids
# only; they live in buildpc and never ship.
SYSROOT="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
if [ ! -f "$STACK/buildpc/egl.pc" ]; then
  cat > "$STACK/buildpc/egl.pc" <<EOF
prefix=$SYSROOT/usr
libdir=\${prefix}/lib/aarch64-linux-android/26
includedir=\${prefix}/include
Name: EGL
Description: Android system EGL (NDK sysroot, build aid only)
Version: 1.5
Libs: -L\${libdir} -lEGL
Cflags: -I\${includedir}
EOF
  cat > "$STACK/buildpc/glesv2.pc" <<EOF
prefix=$SYSROOT/usr
libdir=\${prefix}/lib/aarch64-linux-android/26
includedir=\${prefix}/include
Name: GLESv2
Description: Android system GLESv2 (NDK sysroot, build aid only)
Version: 3.2
Libs: -L\${libdir} -lGLESv2
Cflags: -I\${includedir}
EOF
fi

# Meson cross file for the Android target.
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

prep_src() {
  local name="$1" tb="$2" url="$3"
  fetch "$tb" "$url" || return 1
  cd "$SRC" || return 1
  rm -rf "$name-src"
  mkdir "$name-src"
  tar xf "$tb" -C "$name-src" --strip-components=1 || return 1
  cd "$name-src" || return 1
}

build_at() {
  local name="$1" tb="$2" url="$3"; shift 3
  if is_done "$name"; then echo "skip $name (done)"; return 0; fi
  echo "=== $name ==="
  prep_src "$name" "$tb" "$url" || return 1
  if declare -F "patch_$name" >/dev/null; then "patch_$name" || return 1; fi
  ./configure --host=aarch64-linux-android --build=x86_64-pc-linux-gnu \
    --prefix="$XPREFIX" "$@" > "$LOGS/$name.log" 2>&1 || { echo "CONFIGURE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make -j3 >> "$LOGS/$name.log" 2>&1 || { echo "MAKE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  make install DESTDIR="$DEST" >> "$LOGS/$name.log" 2>&1 || { echo "INSTALL FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  sync_buildpc
  mark_done "$name"
  echo "done $name"
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

build_meson_libs() { # like build_meson, but compiles only the named
  # installable targets, skipping test-only targets that cannot
  # cross-compile. libxkbcommon's test helper (test/xvfb-wrapper.c)
  # calls posix_spawnp, which bionic only provides from API 28 while
  # this stack targets API 26; the helper links only into test
  # executables that are never installed or run on the phone.
  local name="$1" tb="$2" url="$3"; shift 3
  local targets=() margs=() seen=0 a
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; continue; fi
    if [ $seen -eq 0 ]; then targets+=("$a"); else margs+=("$a"); fi
  done
  if is_done "$name"; then echo "skip $name (done)"; return 0; fi
  echo "=== $name ==="
  prep_src "$name" "$tb" "$url" || return 1
  if declare -F "patch_$name" >/dev/null; then "patch_$name" || return 1; fi
  meson setup build --cross-file "$STACK/android-cross.txt" \
    --prefix="$XPREFIX" --libdir=lib --libexecdir=libexec \
    --buildtype=release "${margs[@]}" > "$LOGS/$name.log" 2>&1 || { echo "MESON SETUP FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  meson compile -C build -j3 "${targets[@]}" >> "$LOGS/$name.log" 2>&1 || { echo "MESON COMPILE FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  DESTDIR="$DEST" meson install -C build --no-rebuild >> "$LOGS/$name.log" 2>&1 || { echo "MESON INSTALL FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  sync_buildpc
  mark_done "$name"
  echo "done $name"
}

build_either() { # build_either <name> <tb> <url> <at args...> -- <meson args...>
  local name="$1" tb="$2" url="$3"; shift 3
  if is_done "$name"; then echo "skip $name (done)"; return 0; fi
  echo "=== $name ==="
  prep_src "$name" "$tb" "$url" || return 1
  local atargs=() margs=() seen=0 a
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; continue; fi
    if [ $seen -eq 0 ]; then atargs+=("$a"); else margs+=("$a"); fi
  done
  cd "$SRC/$name-src" || return 1
  if [ -x ./configure ]; then
    ./configure --host=aarch64-linux-android --build=x86_64-pc-linux-gnu \
      --prefix="$XPREFIX" "${atargs[@]}" > "$LOGS/$name.log" 2>&1 || { echo "CONFIGURE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
    make -j3 >> "$LOGS/$name.log" 2>&1 || { echo "MAKE FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
    make install DESTDIR="$DEST" >> "$LOGS/$name.log" 2>&1 || { echo "INSTALL FAILED $name"; tail -20 "$LOGS/$name.log"; return 1; }
  else
    meson setup build --cross-file "$STACK/android-cross.txt" \
      --prefix="$XPREFIX" --libdir=lib --libexecdir=libexec \
      --buildtype=release "${margs[@]}" > "$LOGS/$name.log" 2>&1 || { echo "MESON SETUP FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
    meson compile -C build -j3 >> "$LOGS/$name.log" 2>&1 || { echo "MESON COMPILE FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
    DESTDIR="$DEST" meson install -C build --no-rebuild >> "$LOGS/$name.log" 2>&1 || { echo "MESON INSTALL FAILED $name"; tail -25 "$LOGS/$name.log"; return 1; }
  fi
  sync_buildpc
  mark_done "$name"
  echo "done $name"
}

XORG="https://www.x.org/releases/individual"
GNOME="https://download.gnome.org/sources"

patch_libICE() {
  # Android app storage denies hard links outright (link() fails
  # with EACCES everywhere under files/), and IceLockAuthFile only
  # treats EEXIST as "locked, retry" -- EACCES aborts the lock, so
  # iceauth can never write .ICEauthority and every XFCE session
  # client gets its ICE connection rejected (xfwm4, panel and
  # xfdesktop all die). Fall back to an exclusive create of the
  # lock file, which has the same atomic test-and-set semantics.
  python3 - "$PWD/src/authutil.c" <<'PYEOF' || return 1
import sys
p = sys.argv[1]
s = open(p).read()
old = ("\t    if (link (creat_name, link_name) != -1)\n"
       "\t\treturn (IceAuthLockSuccess);\n"
       "\n"
       "\t    if (errno == ENOENT)\n")
new = ("\t    if (link (creat_name, link_name) != -1)\n"
       "\t\treturn (IceAuthLockSuccess);\n"
       "\n"
       "\t    if (errno == EACCES)\n"
       "\t    {\n"
       "\t\tint lock_fd = open (link_name, O_CREAT | O_EXCL | O_WRONLY, 0666);\n"
       "\n"
       "\t\tif (lock_fd != -1)\n"
       "\t\t{\n"
       "\t\t    close (lock_fd);\n"
       "\t\t    return (IceAuthLockSuccess);\n"
       "\t\t}\n"
       "\t\tif (errno != EEXIST)\n"
       "\t\t    return (IceAuthLockError);\n"
       "\t    }\n"
       "\n"
       "\t    if (errno == ENOENT)\n")
assert s.count(old) == 1, "libICE lock anchor not found"
s = s.replace(old, new)
open(p, "w").write(s)
print("patched libICE auth lock fallback")
PYEOF
}
# --- session management and Xft ---
build_at libICE libICE-1.1.1.tar.xz "$XORG/lib/libICE-1.1.1.tar.xz" || exit 1
build_at libSM libSM-1.2.4.tar.xz "$XORG/lib/libSM-1.2.4.tar.xz" || exit 1
build_at libXft libXft-2.3.8.tar.xz "$XORG/lib/libXft-2.3.8.tar.xz" || exit 1

# --- dbus (session bus for XFCE and at-spi) ---
build_at dbus dbus-1.14.10.tar.xz "https://dbus.freedesktop.org/releases/dbus/dbus-1.14.10.tar.xz" \
  --enable-shared --disable-static --disable-systemd --disable-launchd \
  --without-x --disable-selinux --disable-apparmor \
  --disable-tests --disable-doxygen-docs --disable-xml-docs \
  --with-session-socket-dir="$XPREFIX/var/run" || exit 1

# --- glib chain ---
build_at pcre2 pcre2-10.44.tar.bz2 "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2" \
  --enable-shared --disable-static --enable-pcre2-16 --enable-pcre2-32 || exit 1
build_meson glib glib-2.82.4.tar.xz "$GNOME/glib/2.82/glib-2.82.4.tar.xz" \
  -Dtests=false -Dinstalled_tests=false -Dman-pages=disabled \
  -Dnls=disabled -Dselinux=disabled -Dlibmount=disabled \
  -Dsysprof=disabled -Ddocumentation=false \
  -Dintrospection=disabled || exit 1
build_either cairo cairo-1.18.2.tar.xz "https://cairographics.org/releases/cairo-1.18.2.tar.xz" \
  --enable-xlib --enable-xcb --enable-ft --enable-fc --enable-png \
  --enable-gobject --disable-gl --disable-egl --disable-glesv2 --disable-tee \
  -- \
  -Dxlib=enabled -Dxcb=enabled -Dfontconfig=enabled -Dfreetype=enabled \
  -Dpng=enabled -Dglib=enabled -Dspectre=disabled || exit 1
patch_libxkbcommon() {
  # test/xvfb-wrapper.c calls posix_spawnp, which bionic only provides
  # from API 28 while this stack targets API 26. The wrapper is test-only
  # infrastructure; on API < 28 use fork+execvp instead.
  python3 - "$PWD/test/xvfb-wrapper.c" <<'PYEOF' || return 1
import sys
p = sys.argv[1]
s = open(p).read()
inc_old = "#include <sys/wait.h>\n"
inc_new = "#include <sys/wait.h>\n#include <unistd.h>\n#include <errno.h>\n"
assert s.count(inc_old) == 1, "include anchor not found"
s = s.replace(inc_old, inc_new)
old = '    ret = posix_spawnp(&xvfb_pid, "Xvfb", NULL, NULL, xvfb_argv, envp);\n'
new = ('#if defined(__ANDROID__) && __ANDROID_API__ < 28\n'
       '    /* posix_spawnp needs API 28; this stack targets 26: fork+execvp instead */\n'
       '    xvfb_pid = fork();\n'
       '    if (xvfb_pid == 0) {\n'
       '        execvp("Xvfb", xvfb_argv);\n'
       '        _exit(127);\n'
       '    }\n'
       '    ret = (xvfb_pid < 0) ? errno : 0;\n'
       '#else\n'
       '    ret = posix_spawnp(&xvfb_pid, "Xvfb", NULL, NULL, xvfb_argv, envp);\n'
       '#endif\n')
assert s.count(old) == 1, "spawn anchor not found"
s = s.replace(old, new)
open(p, "w").write(s)
print("patched test/xvfb-wrapper.c for API < 28")
PYEOF
}

build_meson_libs libxkbcommon xkbcommon-1.7.0.tar.gz "https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.7.0.tar.gz" \
  xkbcommon xkbcommon-x11 -- \
  -Denable-x11=true -Denable-wayland=false -Denable-docs=false \
  -Denable-tools=false -Denable-xkbregistry=false -Denable-bash-completion=false || exit 1
build_either harfbuzz harfbuzz-10.1.0.tar.xz "https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz" \
  --with-glib=yes --with-freetype=yes --with-cairo=no --with-icu=no --with-graphite2=no \
  -- \
  -Dglib=enabled -Dfreetype=enabled -Dcairo=disabled -Dicu=disabled \
  -Dgraphite=disabled -Dgraphite2=disabled -Dtests=disabled -Ddocs=disabled \
  -Dintrospection=disabled -Dutilities=disabled || exit 1
build_either fribidi fribidi-1.0.16.tar.xz "https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz" \
  --enable-shared --disable-static \
  -- \
  -Ddocs=false -Dtests=false -Dbin=false || exit 1
build_meson pango pango-1.54.0.tar.xz "$GNOME/pango/1.54/pango-1.54.0.tar.xz" \
  -Dintrospection=disabled -Ddocumentation=false \
  -Dfontconfig=enabled -Dlibthai=disabled -Dcairo=enabled \
  -Dxft=enabled -Dfreetype=enabled || exit 1
build_meson gdk-pixbuf gdk-pixbuf-2.42.12.tar.xz "$GNOME/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz" \
  -Dintrospection=disabled -Ddocs=false -Dman=false \
  -Dtests=false -Dinstalled_tests=false -Dbuiltin_loaders=png,jpeg \
  -Dothers=disabled || exit 1
# libxml2 was missing from the stack; at-spi2-core requires it.
build_at libxml2 libxml2-2.13.8.tar.xz "$GNOME/libxml2/2.13/libxml2-2.13.8.tar.xz" \
  --enable-shared --disable-static --without-python --without-readline \
  --without-lzma --without-zlib --without-icu || exit 1
build_meson at-spi2-core at-spi2-core-2.54.0.tar.xz "$GNOME/at-spi2-core/2.54/at-spi2-core-2.54.0.tar.xz" \
  -Dintrospection=disabled -Ddocs=false \
  -Dx11=enabled || exit 1
build_meson libepoxy libepoxy-1.5.10.tar.gz "https://github.com/anholt/libepoxy/archive/refs/tags/1.5.10.tar.gz" \
  -Degl=yes -Dglx=yes -Dx11=true -Dtests=false || exit 1

# --- GTK 3 ---
build_meson gtk gtk-3.24.49.tar.xz "$GNOME/gtk/3.24/gtk-3.24.49.tar.xz" \
  -Dx11_backend=true -Dwayland_backend=false -Dbroadway_backend=false \
  -Dwin32_backend=false -Dquartz_backend=false -Dintrospection=false \
  -Dman=false -Ddemos=false -Dexamples=false \
  -Dtests=false -Dinstalled_tests=false -Dcloudproviders=false \
  -Dcolord=no -Dprint_backends=file || exit 1

# --- base icon theme (data) ---
build_at hicolor-icon-theme hicolor-icon-theme-0.17.tar.xz \
  "https://icon-theme.freedesktop.org/releases/hicolor-icon-theme-0.17.tar.xz" || exit 1

echo "TRANCHE 3 DONE"
