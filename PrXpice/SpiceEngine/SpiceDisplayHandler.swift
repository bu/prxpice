import Foundation
import CSpiceBridge

/// Routes SPICE display callbacks to the MetalRenderer.
/// Callbacks arrive on the GLib thread. Texture updates are thread-safe
/// (Metal shared storage mode). No main thread dispatch needed for pixel data.
final class SpiceDisplayHandler {
    weak var renderer: MetalRenderer?

    // Cached surface data pointer from display-primary-create
    private var surfaceDataPointer: UnsafeRawPointer?
    private var surfaceStride: Int = 0

    func handleDisplayCreate(surface: SpiceBridgeSurface) {
        let width = Int(surface.width)
        let height = Int(surface.height)
        let stride = Int(surface.stride)

        Log.spice.info("Display created: \(width)x\(height), stride=\(stride)")

        // Cache the data pointer - it remains valid until display-primary-destroy
        surfaceDataPointer = UnsafeRawPointer(surface.data)
        surfaceStride = stride

        // Create Metal textures (must happen before any invalidate)
        renderer?.createSurface(width: width, height: height)

        // Upload initial full frame
        if let data = surfaceDataPointer {
            renderer?.uploadFullFrame(data: data, stride: stride)
        }
    }

    func handleDisplayInvalidate(surfaceId: Int32, rect: SpiceBridgeRect, data: UnsafePointer<UInt8>?, stride: Int32) {
        // Use cached surface pointer (data param may be NULL from bridge)
        guard let basePointer = surfaceDataPointer else { return }

        let dirtyRect = (
            x: Int(rect.x),
            y: Int(rect.y),
            width: Int(rect.width),
            height: Int(rect.height)
        )

        // Direct texture upload on GLib thread - thread-safe with Metal shared storage
        renderer?.updateTexture(
            rect: dirtyRect,
            basePointer: basePointer,
            stride: surfaceStride
        )
    }

    func handleDisplayDestroy(surfaceId: Int32) {
        Log.spice.info("Display destroyed: surface \(surfaceId)")
        surfaceDataPointer = nil
        surfaceStride = 0
        renderer?.destroySurface()
    }
}
