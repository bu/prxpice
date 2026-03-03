#!/bin/bash
set -euo pipefail

# ============================================================================
# build-deps.sh - Cross-compile all C dependencies for iOS arm64
# ============================================================================
# Builds static libraries (.a) for:
#   OpenSSL, libffi, glib, pixman, opus, libjpeg-turbo,
#   json-glib, spice-protocol, spice-client-glib
#
# Requirements: macOS with Xcode CLI tools, meson, ninja, autoconf, automake,
#               libtool, pkg-config, nasm (for libjpeg-turbo)
#
# Output: All .a files and headers installed to $PREFIX (Vendor/)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build-deps"
PREFIX="$PROJECT_DIR/Vendor"
SOURCES_DIR="$BUILD_DIR/sources"

# iOS cross-compilation settings
IOS_MIN_VERSION="15.0"
ARCH="arm64"
SDK="iphoneos"
SDKROOT=$(xcrun --sdk $SDK --show-sdk-path)
CC="$(xcrun --sdk $SDK --find clang)"
CXX="$(xcrun --sdk $SDK --find clang++)"
AR="$(xcrun --sdk $SDK --find ar)"
RANLIB="$(xcrun --sdk $SDK --find ranlib)"
STRIP="$(xcrun --sdk $SDK --find strip)"

CFLAGS="-arch $ARCH -mios-version-min=$IOS_MIN_VERSION -isysroot $SDKROOT -O2 -fembed-bitcode"
CXXFLAGS="$CFLAGS"
LDFLAGS="-arch $ARCH -mios-version-min=$IOS_MIN_VERSION -isysroot $SDKROOT"

HOST="aarch64-apple-darwin"

NJOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# Library versions
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

        ./Configure ios64-xcrun \
            --prefix="$PREFIX" \
            no-shared \
            no-tests \
            no-ui-console \
            -mios-version-min=$IOS_MIN_VERSION

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
        # distutils was removed in Python 3.12+; setuptools provides it as a shim
        # required by GLib's gdbus-codegen
        python3 -m pip install setuptools --break-system-packages --quiet 2>/dev/null || \
        python3 -m pip install setuptools --quiet || true

        rm -rf glib-${GLIB_VERSION}
        tar xJf "$SOURCES_DIR/glib-${GLIB_VERSION}.tar.xz"
        cd glib-${GLIB_VERSION}

        # Create Meson cross file with correct paths
        cat > ios-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'

[built-in options]
c_args = ['-arch', 'arm64', '-mios-version-min=$IOS_MIN_VERSION', '-isysroot', '$SDKROOT', '-I$SCRIPT_DIR/ios-stubs', '-I$PREFIX/include']
c_link_args = ['-arch', 'arm64', '-mios-version-min=$IOS_MIN_VERSION', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=ios-cross.ini \
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

        cat > ios-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'

[built-in options]
c_args = ['-arch', 'arm64', '-mios-version-min=$IOS_MIN_VERSION', '-isysroot', '$SDKROOT']
c_link_args = ['-arch', 'arm64', '-mios-version-min=$IOS_MIN_VERSION', '-isysroot', '$SDKROOT']

[host_machine]
system = 'darwin'
cpu_family = 'arm'
cpu = 'arm'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=ios-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dtests=disabled \
            -Darm-simd=disabled \
            -Dneon=disabled

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
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_SYSTEM_PROCESSOR=arm64 \
            -DCMAKE_C_COMPILER="$CC" \
            -DCMAKE_C_COMPILER_AR="$AR" \
            -DCMAKE_OSX_SYSROOT="$SDKROOT" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN_VERSION \
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

        cat > ios-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'

[built-in options]
c_args = ['-arch', 'arm64', '-mios-version-min=$IOS_MIN_VERSION', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include']
c_link_args = ['-arch', 'arm64', '-mios-version-min=$IOS_MIN_VERSION', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=ios-cross.ini \
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

    # Git submodules are not included in GitLab archive tarballs — download separately
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

        # Populate submodule directories
        rm -rf subprojects/spice-common
        mkdir -p subprojects/spice-common
        tar xzf "$SOURCES_DIR/spice-common-${SPICE_COMMON_COMMIT}.tar.gz" \
            --strip-components=1 -C subprojects/spice-common

        rm -rf subprojects/keycodemapdb
        mkdir -p subprojects/keycodemapdb
        tar xzf "$SOURCES_DIR/keycodemapdb-${KEYCODEMAPDB_COMMIT}.tar.gz" \
            --strip-components=1 -C subprojects/keycodemapdb

        # spice-common code generator requires these Python modules
        python3 -m pip install six pyparsing --break-system-packages 2>/dev/null || true

        # GStreamer is not available on iOS — patch it to be optional
        # Patch 1: meson.build — make GStreamer deps optional, expose spice_glib_has_gstreamer
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

        # Patch 2: src/meson.build — make channel-display-gst.c conditional
        python3 - << 'PYEOF'
with open('src/meson.build') as f:
    content = f.read()
# Remove from unconditional list
content = content.replace("  'channel-display-gst.c',\n", "")
# Inject conditional just before the library() call
marker = "spice_client_glib_lib = library("
conditional = (
    "if spice_glib_has_gstreamer\n"
    "  spice_client_glib_sources += files('channel-display-gst.c')\n"
    "else\n"
    "  spice_client_glib_sources += files('channel-display-gst-stub.c')\n"
    "endif\n"
)
assert marker in content, "library() call not found in src/meson.build"
content = content.replace(marker, conditional + marker, 1)
with open('src/meson.build', 'w') as f:
    f.write(content)
print("src/meson.build: channel-display-gst.c is now conditional")
PYEOF

        # Patch 3: channel-display-priv.h — guard GStreamer-specific include/decl
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

        # Patch 4: channel-display.c — guard all GStreamer-specific code
        python3 - << 'PYEOF'
with open('src/channel-display.c') as f:
    content = f.read()

# 4a: Guard the GstPipeline signal registration in class_init
old_sig = (
    "    signals[SPICE_DISPLAY_OVERLAY] =\n"
    "        g_signal_new(\"gst-video-overlay\",\n"
)
# Find the end of this signal registration (closing semicolon after GST_TYPE_PIPELINE)
sig_start = content.index(old_sig)
sig_end = content.index("GST_TYPE_PIPELINE);", sig_start) + len("GST_TYPE_PIPELINE);")
content = (content[:sig_start] +
           "#ifdef HAVE_GSTREAMER\n" +
           content[sig_start:sig_end] + "\n#endif" +
           content[sig_end:])

# 4b: Guard hand_pipeline_to_widget implementation
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

        # Patch 5: create stub for no-GStreamer builds
        cat > src/channel-display-gst-stub.c << 'CEOF'
/* channel-display-gst-stub.c
 * Stub GStreamer video decoder — used when cross-compiling for targets
 * (e.g. iOS) where GStreamer is not available. Video stream decoding is
 * simply disabled; all other SPICE channels (display, input, cursor) work. */
#include "config.h"
#include "channel-display-priv.h"

gboolean gstvideo_has_codec(int codec_type)
{
    return FALSE;
}

VideoDecoder* create_gstreamer_decoder(int codec_type, display_stream *stream)
{
    return NULL;
}
CEOF

        # Patch 6: wrap spice-gstaudio.c in a HAVE_GSTREAMER guard.
        # Pure bash: leave the file in meson's source list but make it an empty
        # translation unit when GStreamer is absent.  config.h won't define
        # HAVE_GSTREAMER when GStreamer was not found, so the preprocessor skips
        # the entire body — clang sees only "#include config.h", no <gst/gst.h>.
        {
            printf '#include "config.h"\n#ifdef HAVE_GSTREAMER\n'
            cat src/spice-gstaudio.c
            printf '\n#endif /* HAVE_GSTREAMER */\n'
        } > src/spice-gstaudio.c.new
        mv src/spice-gstaudio.c.new src/spice-gstaudio.c
        echo "spice-gstaudio.c: wrapped in HAVE_GSTREAMER guard"

        # Patch 6b: guard GStreamer audio header and call in spice-audio.c.
        # spice-gstaudio.c is now a no-op TU without GStreamer, so
        # spice_gst_audio_new() is never defined — guard the call site too.
        # Use perl (always present on macOS) instead of a Python heredoc.
        perl -i '' \
            -pe 's|#include "spice-gstaudio\.h"|#ifdef HAVE_GSTREAMER\n#include "spice-gstaudio.h"\n#endif|' \
            src/spice-audio.c
        perl -i '' -0pe \
            's|(\s*)(return spice_gst_audio_new\([^)]+\);)|\1#ifdef HAVE_GSTREAMER\n\1\2\n\1#else\n\1return NULL;\n\1#endif|g' \
            src/spice-audio.c
        echo "spice-audio.c: GStreamer audio guarded"

        cat > ios-cross.ini <<CROSSEOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(which pkg-config)'

[built-in options]
c_args = ['-arch', 'arm64', '-mios-version-min=$IOS_MIN_VERSION', '-isysroot', '$SDKROOT', '-I$PREFIX/include', '-I$PREFIX/include/glib-2.0', '-I$PREFIX/lib/glib-2.0/include', '-I$PREFIX/include/json-glib-1.0', '-I$PREFIX/include/spice-1', '-I$PREFIX/include/pixman-1', '-DHAVE_SPICE']
c_link_args = ['-arch', 'arm64', '-mios-version-min=$IOS_MIN_VERSION', '-isysroot', '$SDKROOT', '-L$PREFIX/lib']

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=ios-cross.ini \
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
            -Dopus=enabled

        ninja -C _build -j$NJOBS
        ninja -C _build install
        log "spice-gtk done"
    else
        log "spice-gtk already built"
    fi
}

# ============================================================================
# Build order (respecting dependencies)
# ============================================================================

log "Starting iOS arm64 dependency build"
log "Build directory: $BUILD_DIR"
log "Install prefix: $PREFIX"
log "iOS SDK: $SDKROOT"

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

# List built libraries
echo ""
echo "Built libraries:"
ls -la "$PREFIX/lib/"*.a 2>/dev/null || echo "  (none found)"
