#!/bin/bash
set -euo pipefail

# ============================================================================
# lipo-catalyst-universal.sh
# Combines Vendor-catalyst-x86_64/ and Vendor-catalyst-arm64/ into
# a universal Vendor-catalyst/ suitable for App Store submission.
#
# Prerequisites:
#   Scripts/build-deps-catalyst.sh x86_64   (produces Vendor-catalyst-x86_64/)
#   Scripts/build-deps-catalyst.sh arm64    (produces Vendor-catalyst-arm64/)
#
# Usage: Scripts/lipo-catalyst-universal.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

X86_DIR="$PROJECT_DIR/Vendor-catalyst-x86_64"
ARM_DIR="$PROJECT_DIR/Vendor-catalyst-arm64"
OUT_DIR="$PROJECT_DIR/Vendor-catalyst"

# Verify both arch builds exist
for dir in "$X86_DIR" "$ARM_DIR"; do
    if [ ! -d "$dir/lib" ]; then
        echo "ERROR: Missing $dir/lib — run build-deps-catalyst.sh for both arches first."
        exit 1
    fi
done

echo "=== Creating universal Vendor-catalyst/ ==="

# Start from a clean slate (headers/pkgconfig from arm64 build are fine for both)
rm -rf "$OUT_DIR"
cp -R "$ARM_DIR" "$OUT_DIR"

# Lipo every .a from x86_64 + arm64 into the output
for arm_lib in "$ARM_DIR/lib/"*.a; do
    lib_name="$(basename "$arm_lib")"
    x86_lib="$X86_DIR/lib/$lib_name"

    if [ ! -f "$x86_lib" ]; then
        echo "WARNING: $lib_name not found in x86_64 build — skipping lipo, using arm64 only"
        continue
    fi

    echo "  lipo $lib_name"
    lipo -create "$x86_lib" "$arm_lib" -output "$OUT_DIR/lib/$lib_name"
done

# Merge any headers present in x86_64 but missing in arm64
# (ninja install sometimes fails in cross-compile; headers are arch-independent)
for dir in "$X86_DIR/include/"*/; do
    name="$(basename "$dir")"
    if [ ! -d "$OUT_DIR/include/$name" ]; then
        echo "  merging missing headers: $name"
        cp -R "$dir" "$OUT_DIR/include/$name"
    fi
done

echo "=== Verifying architectures ==="
for lib in "$OUT_DIR/lib/"*.a; do
    info=$(lipo -info "$lib" 2>/dev/null || echo "unknown")
    echo "  $(basename "$lib"): $info"
done

echo "=== Done: $OUT_DIR ==="
