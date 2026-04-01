#!/bin/bash
set -euo pipefail

# ============================================================================
# build-deps-catalyst.sh - Cross-compile all C dependencies for Mac Catalyst
# ============================================================================
# Builds static libraries (.a) for:
#   OpenSSL, libffi, glib, pixman, opus, libjpeg-turbo,
#   json-glib, spice-protocol, spice-client-glib
#
# Target: arm64-apple-ios17.0-macabi  (Mac Catalyst, Apple Silicon Macs)
#
# Requirements: macOS with Xcode CLI tools, meson, ninja, autoconf, automake,
#               libtool, pkg-config, nasm (for libjpeg-turbo)
#
# Output: All .a files and headers installed to $PREFIX (Vendor-catalyst/)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCES_DIR="$PROJECT_DIR/.build-deps-catalyst/sources"

# Mac Catalyst cross-compilation settings
# Catalyst requires the macOS SDK but targets the ios-macabi ABI.
CATALYST_IOS_VERSION="17.0"
# Accept architecture as first argument, default to host arch.
# Usage: build-deps-catalyst.sh [arm64|x86_64]
ARCH="${1:-$(uname -m)}"
BUILD_DIR="$PROJECT_DIR/.build-deps-catalyst-${ARCH}"
PREFIX="$PROJECT_DIR/Vendor-catalyst-${ARCH}"
TARGET_TRIPLE="${ARCH}-apple-ios${CATALYST_IOS_VERSION}-macabi"
SDK="macosx"
SDKROOT=$(xcrun --sdk $SDK --show-sdk-path)
CC="$(xcrun --sdk $SDK --find clang)"
CXX="$(xcrun --sdk $SDK --find clang++)"
AR="$(xcrun --sdk $SDK --find ar)"
RANLIB="$(xcrun --sdk $SDK --find ranlib)"
STRIP="$(xcrun --sdk $SDK --find strip)"

CFLAGS="-target $TARGET_TRIPLE -isysroot $SDKROOT -O2"
CXXFLAGS="$CFLAGS"
LDFLAGS="-target $TARGET_TRIPLE -isysroot $SDKROOT"

# Meson uses 'aarch64' as cpu_family for arm64.
# autotools configure --host also requires 'aarch64', not 'arm64'.
if [ "$ARCH" = "arm64" ]; then
    AUTOTOOLS_HOST="aarch64-apple-darwin"
    MESON_CPU_FAMILY="aarch64"
    MESON_CPU="arm64"
else
    AUTOTOOLS_HOST="${ARCH}-apple-darwin"
    MESON_CPU_FAMILY="x86_64"
    MESON_CPU="x86_64"
fi
HOST="$AUTOTOOLS_HOST"

NJOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Ensure meson/ninja are findable (installed via pip into user Python path)
export PATH="/usr/local/bin:/usr/bin:/bin:/Users/damian/Library/Python/3.9/bin:$PATH"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# Library versions (keep in sync with build-deps.sh)
OPENSSL_VERSION="3.2.1"
LIBFFI_VERSION="3.4.6"
GLIB_VERSION="2.78.4"
PIXMAN_VERSION="0.42.2"
OPUS_VERSION="1.4"
LIBJPEG_VERSION="3.1.0"
JSONGLIB_VERSION="1.8.0"
SPICE_PROTOCOL_VERSION="0.14.4"
SPICE_GTK_VERSION="0.42"

# ============================================================================
# Helper functions
# ============================================================================

log() {
    echo "=== $(date '+%H:%M:%S') $1 ==="
}

download() {
    local url="$1"
    local dest="$2"
    if [ ! -f "$dest" ]; then
        log "Downloading $(basename $dest)"
        curl -L -o "$dest" "$url"
    fi
}

# ============================================================================
# Build each dependency
# ============================================================================

mkdir -p "$BUILD_DIR" "$SOURCES_DIR" "$PREFIX/lib" "$PREFIX/include" "$PREFIX/lib/pkgconfig"

# --- OpenSSL ---
build_openssl() {
    log "Building OpenSSL $OPENSSL_VERSION"
    cd "$BUILD_DIR"
    download "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
             "$SOURCES_DIR/openssl-${OPENSSL_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libssl.a" ]; then
        rm -rf openssl-${OPENSSL_VERSION}
        tar xzf "$SOURCES_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
        cd openssl-${OPENSSL_VERSION}

        # Use the appropriate darwin64 config for the host architecture.
        OPENSSL_TARGET="darwin64-${ARCH}-cc"
        CC="$CC" \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
        ./Configure "$OPENSSL_TARGET" \
            --prefix="$PREFIX" \
            no-shared \
            no-tests \
            no-ui-console

        make -j$NJOBS
        make install_sw
        log "OpenSSL done"
    else
        log "OpenSSL already built"
    fi
}

# --- libffi ---
build_libffi() {
    log "Building libffi $LIBFFI_VERSION"
    cd "$BUILD_DIR"
    download "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz" \
             "$SOURCES_DIR/libffi-${LIBFFI_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libffi.a" ]; then
        rm -rf libffi-${LIBFFI_VERSION}
        tar xzf "$SOURCES_DIR/libffi-${LIBFFI_VERSION}.tar.gz"
        cd libffi-${LIBFFI_VERSION}

        CC="$CC" CFLAGS="$CFLAGS -Wno-deprecated-declarations" LDFLAGS="$LDFLAGS" \
        ./configure \
            --host=$HOST \
            --prefix="$PREFIX" \
            --enable-static \
            --disable-shared \
            --disable-docs

        # configure sets HAVE_AS_CFI_PSEUDO_OP=1 because the macOS assembler
        # supports .cfi_startproc, but it rejects .cfi_def_cfa with register
        # names (e.g. x1) when targeting macabi.  Clearing this flag makes
        # libffi's ffi_cfi.h use empty no-op macros for all CFI directives,
        # which is safe (only affects stack-unwind debug info, not correctness).
        # fficonfig.h is generated in a host-triple subdirectory (e.g. aarch64-apple-darwin/)
        find . -name "fficonfig.h" -exec sed -i '' 's/#define HAVE_AS_CFI_PSEUDO_OP 1/\/* HAVE_AS_CFI_PSEUDO_OP disabled for macabi *\//' {} \;

        make -j$NJOBS
        make install
        log "libffi done"
    else
        log "libffi already built"
    fi
}

# --- GLib ---
build_glib() {
    log "Building GLib $GLIB_VERSION"
    cd "$BUILD_DIR"
    local GLIB_MAJOR=$(echo $GLIB_VERSION | cut -d. -f1-2)
    download "https://download.gnome.org/sources/glib/${GLIB_MAJOR}/glib-${GLIB_VERSION}.tar.xz" \
             "$SOURCES_DIR/glib-${GLIB_VERSION}.tar.xz"

    if [ ! -f "$PREFIX/lib/libglib-2.0.a" ]; then
        python3 -m pip install setuptools --break-system-packages --quiet 2>/dev/null || \
        python3 -m pip install setuptools --quiet || true

        rm -rf glib-${GLIB_VERSION}
        tar xJf "$SOURCES_DIR/glib-${GLIB_VERSION}.tar.xz"
        cd glib-${GLIB_VERSION}

        cat > catalyst-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=catalyst-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dtests=false \
            -Dglib_debug=disabled \
            -Dlibelf=disabled \
            -Dnls=disabled \
            -Dlibmount=disabled \
            -Dxattr=false

        ninja -C _build -j$NJOBS
        ninja -C _build install
        log "GLib done"
    else
        log "GLib already built"
    fi
}

# --- Pixman ---
build_pixman() {
    log "Building pixman $PIXMAN_VERSION"
    cd "$BUILD_DIR"
    download "https://cairographics.org/releases/pixman-${PIXMAN_VERSION}.tar.gz" \
             "$SOURCES_DIR/pixman-${PIXMAN_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libpixman-1.a" ]; then
        rm -rf pixman-${PIXMAN_VERSION}
        tar xzf "$SOURCES_DIR/pixman-${PIXMAN_VERSION}.tar.gz"
        cd pixman-${PIXMAN_VERSION}

        cat > catalyst-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=catalyst-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dtests=disabled \
            -Darm-simd=disabled \
            -Dneon=disabled \
            -Da64-neon=disabled

        ninja -C _build -j$NJOBS
        ninja -C _build install
        log "Pixman done"
    else
        log "Pixman already built"
    fi
}

# --- Opus ---
build_opus() {
    log "Building opus $OPUS_VERSION"
    cd "$BUILD_DIR"
    download "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" \
             "$SOURCES_DIR/opus-${OPUS_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libopus.a" ]; then
        rm -rf opus-${OPUS_VERSION}
        tar xzf "$SOURCES_DIR/opus-${OPUS_VERSION}.tar.gz"
        cd opus-${OPUS_VERSION}

        CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        ./configure \
            --host=$HOST \
            --prefix="$PREFIX" \
            --enable-static \
            --disable-shared \
            --disable-doc \
            --disable-extra-programs

        make -j$NJOBS
        make install
        log "Opus done"
    else
        log "Opus already built"
    fi
}

# --- libjpeg-turbo ---
build_libjpeg() {
    log "Building libjpeg-turbo $LIBJPEG_VERSION"
    cd "$BUILD_DIR"
    download "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_VERSION}/libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz" \
             "$SOURCES_DIR/libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz"

    if [ ! -f "$PREFIX/lib/libjpeg.a" ]; then
        rm -rf libjpeg-turbo-${LIBJPEG_VERSION}
        tar xzf "$SOURCES_DIR/libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz"
        cd libjpeg-turbo-${LIBJPEG_VERSION}

        cmake -B _build \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_SYSTEM_NAME=Darwin \
            -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
            -DCMAKE_C_COMPILER="$CC" \
            -DCMAKE_C_COMPILER_AR="$AR" \
            -DCMAKE_OSX_SYSROOT="$SDKROOT" \
            -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
            -DCMAKE_C_FLAGS="$CFLAGS" \
            -DENABLE_SHARED=OFF \
            -DENABLE_STATIC=ON \
            -DWITH_TURBOJPEG=OFF

        cmake --build _build -j$NJOBS
        cmake --install _build
        log "libjpeg-turbo done"
    else
        log "libjpeg-turbo already built"
    fi
}

# --- json-glib ---
build_json_glib() {
    log "Building json-glib $JSONGLIB_VERSION"
    cd "$BUILD_DIR"
    local JG_MAJOR=$(echo $JSONGLIB_VERSION | cut -d. -f1-2)
    download "https://download.gnome.org/sources/json-glib/${JG_MAJOR}/json-glib-${JSONGLIB_VERSION}.tar.xz" \
             "$SOURCES_DIR/json-glib-${JSONGLIB_VERSION}.tar.xz"

    if [ ! -f "$PREFIX/lib/libjson-glib-1.0.a" ]; then
        rm -rf json-glib-${JSONGLIB_VERSION}
        tar xJf "$SOURCES_DIR/json-glib-${JSONGLIB_VERSION}.tar.xz"
        cd json-glib-${JSONGLIB_VERSION}

        cat > catalyst-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=catalyst-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dtests=false \
            -Dgtk_doc=disabled \
            -Dintrospection=disabled

        ninja -C _build -j$NJOBS
        ninja -C _build install
        log "json-glib done"
    else
        log "json-glib already built"
    fi
}

# --- spice-protocol (headers only) ---
build_spice_protocol() {
    log "Building spice-protocol $SPICE_PROTOCOL_VERSION"
    cd "$BUILD_DIR"
    download "https://gitlab.freedesktop.org/spice/spice-protocol/-/archive/v${SPICE_PROTOCOL_VERSION}/spice-protocol-v${SPICE_PROTOCOL_VERSION}.tar.gz" \
             "$SOURCES_DIR/spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.gz"

    if [ ! -d "$PREFIX/include/spice-1" ]; then
        rm -rf spice-protocol-v${SPICE_PROTOCOL_VERSION}
        tar xzf "$SOURCES_DIR/spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.gz"
        cd spice-protocol-v${SPICE_PROTOCOL_VERSION}

        meson setup _build \
            --prefix="$PREFIX"

        ninja -C _build install
        log "spice-protocol done"
    else
        log "spice-protocol already built"
    fi
}

# --- spice-gtk (client library only, no GTK) ---
build_spice_client() {
    log "Building spice-gtk $SPICE_GTK_VERSION (client-glib only)"
    cd "$BUILD_DIR"
    download "https://gitlab.freedesktop.org/spice/spice-gtk/-/archive/v${SPICE_GTK_VERSION}/spice-gtk-v${SPICE_GTK_VERSION}.tar.gz" \
             "$SOURCES_DIR/spice-gtk-${SPICE_GTK_VERSION}.tar.gz"

    local SPICE_COMMON_COMMIT="58d375e5eadc6fb9e587e99fd81adcb95d01e8d6"
    local KEYCODEMAPDB_COMMIT="14cdba29ecd7448310fe4ff890e67830b1a40f64"
    download "https://gitlab.freedesktop.org/spice/spice-common/-/archive/${SPICE_COMMON_COMMIT}/spice-common-${SPICE_COMMON_COMMIT}.tar.gz" \
             "$SOURCES_DIR/spice-common-${SPICE_COMMON_COMMIT}.tar.gz"
    download "https://gitlab.com/keycodemap/keycodemapdb/-/archive/${KEYCODEMAPDB_COMMIT}/keycodemapdb-${KEYCODEMAPDB_COMMIT}.tar.gz" \
             "$SOURCES_DIR/keycodemapdb-${KEYCODEMAPDB_COMMIT}.tar.gz"

    if [ ! -f "$PREFIX/lib/libspice-client-glib-2.0.a" ]; then
        rm -rf spice-gtk-v${SPICE_GTK_VERSION}
        tar xzf "$SOURCES_DIR/spice-gtk-${SPICE_GTK_VERSION}.tar.gz"
        cd spice-gtk-v${SPICE_GTK_VERSION}

        rm -rf subprojects/spice-common
        mkdir -p subprojects/spice-common
        tar xzf "$SOURCES_DIR/spice-common-${SPICE_COMMON_COMMIT}.tar.gz" \
            --strip-components=1 -C subprojects/spice-common

        rm -rf subprojects/keycodemapdb
        mkdir -p subprojects/keycodemapdb
        tar xzf "$SOURCES_DIR/keycodemapdb-${KEYCODEMAPDB_COMMIT}.tar.gz" \
            --strip-components=1 -C subprojects/keycodemapdb

        python3 -m pip install six pyparsing --break-system-packages 2>/dev/null || true

        # Patch 1: make GStreamer deps optional
        python3 - << 'PYEOF'
import re, sys
with open('meson.build') as f:
    content = f.read()
pattern = r"gstreamer_version = '1\.10'.*?endforeach"
replacement = (
    "spice_glib_has_gstreamer = false\n"
    "_gst_probe = dependency('gstreamer-1.0', required: false)\n"
    "if _gst_probe.found()\n"
    "  foreach dep : ['gstreamer-1.0', 'gstreamer-base-1.0', 'gstreamer-app-1.0', 'gstreamer-audio-1.0', 'gstreamer-video-1.0']\n"
    "    spice_glib_deps += dependency(dep, version: '>= 1.10')\n"
    "  endforeach\n"
    "  spice_glib_has_gstreamer = true\n"
    "  spice_gtk_config_data.set('HAVE_GSTREAMER', '1')\n"
    "endif"
)
new, n = re.subn(pattern, replacement, content, flags=re.DOTALL)
assert n == 1, f"Expected 1 GStreamer block replacement, got {n}"
with open('meson.build', 'w') as f:
    f.write(new)
print("meson.build: GStreamer is now optional")
PYEOF

        # Patch 2: make channel-display-gst.c conditional
        python3 - << 'PYEOF'
with open('src/meson.build') as f:
    content = f.read()
content = content.replace("  'channel-display-gst.c',\n", "")
marker = "spice_client_glib_lib = library("
conditional = (
    "if spice_glib_has_gstreamer\n"
    "  spice_client_glib_sources += files('channel-display-gst.c')\n"
    "else\n"
    "  spice_client_glib_sources += files('channel-display-vtb.c')\n"
    "endif\n"
)
assert marker in content, "library() call not found in src/meson.build"
content = content.replace(marker, conditional + marker, 1)
with open('src/meson.build', 'w') as f:
    f.write(content)
print("src/meson.build: channel-display-gst.c is now conditional")
PYEOF

        # Patch 3: guard GStreamer-specific include/decl in channel-display-priv.h
        python3 - << 'PYEOF'
with open('src/channel-display-priv.h') as f:
    content = f.read()
content = content.replace(
    '#include <gst/gst.h>',
    '#ifdef HAVE_GSTREAMER\n#include <gst/gst.h>\n#endif'
)
content = content.replace(
    'gboolean hand_pipeline_to_widget(display_stream *st,  GstPipeline *pipeline);',
    '#ifdef HAVE_GSTREAMER\ngboolean hand_pipeline_to_widget(display_stream *st,  GstPipeline *pipeline);\n#endif'
)
with open('src/channel-display-priv.h', 'w') as f:
    f.write(content)
print("channel-display-priv.h: GStreamer guarded")
PYEOF

        # Patch 4: guard GStreamer-specific code in channel-display.c
        python3 - << 'PYEOF'
with open('src/channel-display.c') as f:
    content = f.read()

old_sig = (
    "    signals[SPICE_DISPLAY_OVERLAY] =\n"
    "        g_signal_new(\"gst-video-overlay\",\n"
)
sig_start = content.index(old_sig)
sig_end = content.index("GST_TYPE_PIPELINE);", sig_start) + len("GST_TYPE_PIPELINE);")
content = (content[:sig_start] +
           "#ifdef HAVE_GSTREAMER\n" +
           content[sig_start:sig_end] + "\n#endif" +
           content[sig_end:])

old_func = (
    "G_GNUC_INTERNAL\n"
    "gboolean hand_pipeline_to_widget(display_stream *st, GstPipeline *pipeline)\n"
)
new_func = (
    "#ifdef HAVE_GSTREAMER\n"
    "G_GNUC_INTERNAL\n"
    "gboolean hand_pipeline_to_widget(display_stream *st, GstPipeline *pipeline)\n"
)
assert old_func in content, "hand_pipeline_to_widget not found in channel-display.c"
idx = content.index(old_func)
brace_idx = content.index('{', idx + len(old_func))
depth = 1
brace_idx += 1
while depth > 0:
    c = content[brace_idx]
    if c == '{': depth += 1
    elif c == '}': depth -= 1
    brace_idx += 1
content = (content[:idx] + new_func +
           content[idx+len(old_func):brace_idx] + "\n#endif\n" +
           content[brace_idx:])

with open('src/channel-display.c', 'w') as f:
    f.write(content)
print("channel-display.c: hand_pipeline_to_widget guarded")
PYEOF

        # Patch 5: install VideoToolbox H.264/H.265 decoder
        cp "$SCRIPT_DIR/channel-display-vtb.c" src/channel-display-vtb.c
        echo "Installed VideoToolbox decoder"

        # Patch 6: wrap spice-gstaudio.c in HAVE_GSTREAMER guard
        {
            printf '#include "config.h"\n#ifdef HAVE_GSTREAMER\n'
            cat src/spice-gstaudio.c
            printf '\n#endif /* HAVE_GSTREAMER */\n'
        } > src/spice-gstaudio.c.new
        mv src/spice-gstaudio.c.new src/spice-gstaudio.c
        echo "spice-gstaudio.c: wrapped in HAVE_GSTREAMER guard"

        # Patch 6b: guard GStreamer audio header and call in spice-audio.c
        python3 - << 'PYEOF'
with open('src/spice-audio.c') as f:
    content = f.read()

content = content.replace(
    '#include "spice-gstaudio.h"',
    '#ifdef HAVE_GSTREAMER\n#include "spice-gstaudio.h"\n#endif'
)

old_block = (
    '    self = SPICE_AUDIO(spice_gstaudio_new(session, context, name));\n'
    '    if (self != NULL) {\n'
    '        spice_g_signal_connect_object(session, "notify::enable-audio", G_CALLBACK(session_enable_audio), self, 0);\n'
    '        spice_g_signal_connect_object(session, "channel-new", G_CALLBACK(channel_new), self, G_CONNECT_AFTER);\n'
    '        update_audio_channels(self, session);\n'
    '    }\n'
)
new_block = (
    '#ifdef HAVE_GSTREAMER\n'
    '    self = SPICE_AUDIO(spice_gstaudio_new(session, context, name));\n'
    '    if (self != NULL) {\n'
    '        spice_g_signal_connect_object(session, "notify::enable-audio", G_CALLBACK(session_enable_audio), self, 0);\n'
    '        spice_g_signal_connect_object(session, "channel-new", G_CALLBACK(channel_new), self, G_CONNECT_AFTER);\n'
    '        update_audio_channels(self, session);\n'
    '    }\n'
    '#endif\n'
)
assert old_block in content, "spice_gstaudio_new block not found in spice-audio.c"
content = content.replace(old_block, new_block, 1)

with open('src/spice-audio.c', 'w') as f:
    f.write(content)
print("spice-audio.c: GStreamer audio guarded")
PYEOF

        # Patch 7: add missing standard headers before jpeglib.h
        python3 - << 'PYEOF'
with open('src/channel-display-priv.h') as f:
    content = f.read()
content = content.replace(
    '#include <jpeglib.h>',
    '#include <stdio.h>\n#include <stddef.h>\n#include <stdbool.h>\n#include <jpeglib.h>'
)
with open('src/channel-display-priv.h', 'w') as f:
    f.write(content)
print("channel-display-priv.h: added stdio.h/stddef.h/stdbool.h before jpeglib.h")
PYEOF

        # Patch 8: guard hand_pipeline_to_widget call in channel-display-mjpeg.c
        python3 - << 'PYEOF'
with open('src/channel-display-mjpeg.c') as f:
    content = f.read()
old = '    hand_pipeline_to_widget(stream, NULL);\n'
new = '#ifdef HAVE_GSTREAMER\n    hand_pipeline_to_widget(stream, NULL);\n#endif\n'
assert old in content, "hand_pipeline_to_widget call not found in channel-display-mjpeg.c"
content = content.replace(old, new, 1)
with open('src/channel-display-mjpeg.c', 'w') as f:
    f.write(content)
print("channel-display-mjpeg.c: guarded hand_pipeline_to_widget call")
PYEOF

        cat > catalyst-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'

[built-in options]
c_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include', '-I$PREFIX/include/json-glib-1.0', '-I$PREFIX/include/spice-1', '-I$PREFIX/include/pixman-1', '-DHAVE_SPICE']
c_link_args = ['-target', '$TARGET_TRIPLE', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']

[host_machine]
system = 'darwin'
subsystem = 'macos'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=catalyst-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dgtk=disabled \
            -Dwebdav=disabled \
            -Dusbredir=disabled \
            -Dpolkit=disabled \
            -Dlz4=disabled \
            -Dsasl=disabled \
            -Dsmartcard=disabled \
            -Dcoroutine=gthread \
            -Dvapi=disabled \
            -Dgtk_doc=disabled \
            -Dintrospection=disabled \
            -Dopus=enabled \
            -Dspice-common:tests=false

        ninja -C _build -j$NJOBS src/libspice-client-glib-2.0.a
        ninja -C _build install 2>/dev/null || \
            cp _build/src/libspice-client-glib-2.0.a "$PREFIX/lib/"
        log "spice-gtk done"
    else
        log "spice-gtk already built"
    fi
}

# ============================================================================
# Build order (respecting dependencies)
# ============================================================================

log "Starting Mac Catalyst arm64 dependency build"
log "Target triple: $TARGET_TRIPLE"
log "Build directory: $BUILD_DIR"
log "Install prefix: $PREFIX"
log "macOS SDK: $SDKROOT"

build_openssl
build_libffi
build_glib        # depends on: libffi
build_pixman
build_opus
build_libjpeg
build_json_glib   # depends on: glib
build_spice_protocol
build_spice_client # depends on: all of the above

log "All dependencies built successfully!"
log "Static libraries in: $PREFIX/lib/"
log "Headers in: $PREFIX/include/"

echo ""
echo "Built libraries:"
ls -la "$PREFIX/lib/"*.a 2>/dev/null || echo "  (none found)"
