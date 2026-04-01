import Foundation
import CoreVideo
import CSpiceBridge

/// Routes SPICE display callbacks to the MetalRenderer.
/// Callbacks arrive on the GLib thread. Texture updates are thread-safe
/// (Metal shared storage mode). No main thread dispatch needed for pixel data.
final class SpiceDisplayHandler {
    // When renderer is set after display-primary-create already fired, replay the surface.
    // Only replay on nil → non-nil transition; re-wiring to the same object must not
    // recreate the surface (that would clear the live texture mid-render).
    weak var renderer: MetalRenderer? {
        didSet {
            guard renderer != nil, oldValue == nil else { return }
            replayPendingDisplayIfNeeded()
        }
    }
    var onLog: ((String) -> Void)?

    // Cached surface data pointer from display-primary-create
    private var surfaceDataPointer: UnsafeRawPointer?
    private var surfaceStride: Int = 0
    private var pendingWidth: Int = 0
    private var pendingHeight: Int = 0

    private func replayPendingDisplayIfNeeded() {
        guard let renderer = renderer, pendingWidth > 0, let data = surfaceDataPointer else { return }
        onLog?("replayDisplay \(pendingWidth)x\(pendingHeight) (renderer arrived late)")
        renderer.createSurface(width: pendingWidth, height: pendingHeight)
        renderer.uploadFullFrame(data: data, stride: surfaceStride)
    }

    func handleDisplayCreate(surface: SpiceBridgeSurface) {
        let width = Int(surface.width)
        let height = Int(surface.height)
        let stride = Int(surface.stride)
        let hasData = surface.data != nil
        let hasRenderer = renderer != nil

        Log.spice.info("Display created: \(width)x\(height), stride=\(stride)")
        onLog?("displayCreate \(width)x\(height) stride=\(stride) data=\(hasData) renderer=\(hasRenderer)")

        // Cache the data pointer - it remains valid until display-primary-destroy
        surfaceDataPointer = UnsafeRawPointer(surface.data)
        surfaceStride = stride
        pendingWidth = width
        pendingHeight = height

        guard let renderer = renderer else {
            onLog?("displayCreate: renderer nil, will replay when renderer arrives")
            return
        }

        // Create Metal textures (must happen before any invalidate)
        renderer.createSurface(width: width, height: height)

        // Upload initial full frame
        if let data = surfaceDataPointer {
            renderer.uploadFullFrame(data: data, stride: stride)
            onLog?("uploadFullFrame done")
        } else {
            onLog?("uploadFullFrame skipped: no data")
        }
    }

    func handleDisplayInvalidate(surfaceId: Int32, rect: SpiceBridgeRect, data: UnsafePointer<UInt8>?, stride: Int32) {
        // Prefer live data pointer from bridge; fall back to cached pointer from display-create
        guard let basePointer = data.map({ UnsafeRawPointer($0) }) ?? surfaceDataPointer else {
            onLog?("invalidate: no data pointer!")
            return
        }
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

    func handleVideoFrame(_ pixelBuffer: CVPixelBuffer) {
        renderer?.updateVideoTexture(pixelBuffer: pixelBuffer)
    }

    func handleDisplayDestroy(surfaceId: Int32) {
        Log.spice.info("Display destroyed: surface \(surfaceId)")
        surfaceDataPointer = nil
        surfaceStride = 0
        pendingWidth = 0
        pendingHeight = 0
        renderer?.destroySurface()
    }
}
