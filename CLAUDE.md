# PrXpice - iOS SPICE Client for Proxmox VE

## Build Commands

```bash
# Cross-compile all C dependencies for iOS arm64
Scripts/build-deps.sh

# Build app for device
TOOLCHAINS=com.apple.dt.toolchain.Metal.32023.850.10 xcodebuild -project PrXpice.xcodeproj -scheme PrXpice -sdk iphoneos -configuration Release build

# Build for simulator (testing)
TOOLCHAINS=com.apple.dt.toolchain.Metal.32023.850.10 xcodebuild -project PrXpice.xcodeproj -scheme PrXpice -sdk iphonesimulator -configuration Debug build

# Run unit tests
TOOLCHAINS=com.apple.dt.toolchain.Metal.32023.850.10 xcodebuild test -project PrXpice.xcodeproj -scheme PrXpice -destination 'platform=iOS Simulator,name=iPhone 15'
```

> **Note**: The `TOOLCHAINS` prefix is required because the Metal toolchain was installed to
> `~/Library/Developer/Toolchains/` rather than inside `Xcode.app`. To avoid it permanently,
> run `sudo cp -R ~/Library/Developer/Toolchains/Metal.xctoolchain /Applications/Xcode.app/Contents/Developer/Toolchains/`.

## Architecture

**Pattern**: MVVM with SwiftUI shell + UIKit for performance-critical VM display

**Display Pipeline** (performance-critical):
```
SPICE Server → libspice-client-glib (GLib thread) → display-invalidate callback
  → MTLTexture.replace(region:) for dirty rect only (no main thread dispatch)
  → CADisplayLink coalesces updates → GPU renders textured quad → screen
```

**C Bridge Pattern**: Swift ↔ C ↔ GObject
- Swift cannot call GObject APIs directly
- `CSpiceBridge/` exposes plain C functions
- Swift passes `Unmanaged<Self>.toOpaque()` as context pointer
- C callbacks invoke Swift function pointers with that context

**Threading Model**:
- Main thread: SwiftUI/UIKit UI
- GLib thread: dedicated pthread running `g_main_loop_run()`, SPICE callbacks fire here
- Metal texture updates: thread-safe, happen on GLib thread
- UI state changes: dispatched to main queue from GLib thread

## Key Directories

- `PrXpice/` - Main app target (Swift)
- `CSpiceBridge/` - C bridging module between Swift and libspice
- `Vendor/` - Pre-built static libraries and headers for iOS arm64
- `Scripts/` - Cross-compilation build scripts

## Dependencies (static libs, iOS arm64)

- OpenSSL (TLS for SPICE connections)
- libffi (GLib dependency)
- glib-2.0 (SPICE dependency, event loop)
- pixman (pixel manipulation)
- opus (audio codec)
- libjpeg-turbo (JPEG decoding for SPICE)
- json-glib (JSON parsing for SPICE)
- spice-client-glib (core SPICE protocol)

## Testing

- Unit tests in `PrXpiceTests/`
- Manual testing requires a Proxmox VE server with SPICE-enabled VMs
- Simulator builds work for UI testing; device builds needed for Metal + SPICE
