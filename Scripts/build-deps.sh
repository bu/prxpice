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

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

# Library versions
OPENSSL_VERSION="3.2.1"
LIBFFI_VERSION="3.4.6"
GLIB_VERSION="2.78.4"
PIXMAN_VERSION="0.42.2"
OPUS_VERSION="1.4"
LIBJPEG_VERSION="3.0.2"
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
c_args = ['-arch', 'arm64', '-mios-version-min=$IOS_MIN_VERSION', '-isysroot', '$SDKROOT', '-I$PREFIX/include']
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
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSSEOF

        meson setup _build \
            --cross-file=ios-cross.ini \
            --prefix="$PREFIX" \
            --default-library=static \
            -Dtests=disabled \
            -Ddemos=disabled \
            -Dgtk=disabled

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
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN_VERSION \
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
            -Dgtk_doc=disabled

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
    download "https://www.spice-space.org/download/releases/spice-protocol/spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.xz" \
             "$SOURCES_DIR/spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.xz"

    if [ ! -d "$PREFIX/include/spice-1" ]; then
        rm -rf spice-protocol-${SPICE_PROTOCOL_VERSION}
        tar xJf "$SOURCES_DIR/spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.xz"
        cd spice-protocol-${SPICE_PROTOCOL_VERSION}

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
    download "https://www.spice-space.org/download/gtk/spice-gtk-${SPICE_GTK_VERSION}.tar.xz" \
             "$SOURCES_DIR/spice-gtk-${SPICE_GTK_VERSION}.tar.xz"

    if [ ! -f "$PREFIX/lib/libspice-client-glib-2.0.a" ]; then
        rm -rf spice-gtk-${SPICE_GTK_VERSION}
        tar xJf "$SOURCES_DIR/spice-gtk-${SPICE_GTK_VERSION}.tar.xz"
        cd spice-gtk-${SPICE_GTK_VERSION}

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
            -Dpulseaudio=disabled \
            -Dlz4=disabled \
            -Dsasl=disabled \
            -Dsmartcard=disabled \
            -Dcoroutine=gthread \
            -Dvapi=disabled \
            -Dgtk_doc=disabled \
            -Dtests=false \
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
