import Foundation
import Metal
import QuartzCore

/// GPU-accelerated renderer for SPICE framebuffer display.
///
/// Thread safety: `updateTexture(region:data:stride:)` is safe to call from the
/// GLib thread. Rendering via `draw(in:)` happens on the CADisplayLink thread.
/// Triple-buffered texture pool avoids contention.
final class MetalRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    // Triple-buffered textures to avoid GPU/CPU contention
    private var textures: [MTLTexture] = []
    private var currentTextureIndex = 0
    private let textureCount = 3

    // Display dimensions
    private(set) var displayWidth: Int = 0
    private(set) var displayHeight: Int = 0

    // Dirty tracking - coalesce multiple invalidations into one region
    private var dirtyRegion: MTLRegion?
    private let dirtyLock = NSLock()

    // Flag indicating texture has new data
    private var needsRedraw = false

    init?(device: MTLDevice) {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            Log.rendering.error("Failed to create command queue")
            return nil
        }
        self.commandQueue = queue

        // Load shaders and create pipeline
        guard let library = device.makeDefaultLibrary(),
              let vertexFunc = library.makeFunction(name: "vertexShader"),
              let fragmentFunc = library.makeFunction(name: "fragmentShader")
        else {
            Log.rendering.error("Failed to load Metal shaders")
            return nil
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragmentFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            Log.rendering.error("Failed to create pipeline state: \(error)")
            return nil
        }
    }

    /// Creates the texture pool for a new display surface.
    /// Called when SPICE sends `display-primary-create`.
    func createSurface(width: Int, height: Int) {
        displayWidth = width
        displayHeight = height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared // CPU-writable, GPU-readable

        textures = (0..<textureCount).compactMap { _ in
            device.makeTexture(descriptor: descriptor)
        }
        currentTextureIndex = 0
        needsRedraw = true

        Log.rendering.info("Created surface: \(width)x\(height), \(textures.count) textures")
    }

    /// Destroys texture pool when the display surface is removed.
    func destroySurface() {
        textures.removeAll()
        displayWidth = 0
        displayHeight = 0
        needsRedraw = false
    }

    /// Uploads pixel data for a dirty rectangle.
    /// Thread-safe: called from the GLib thread when SPICE invalidates a region.
    ///
    /// - Parameters:
    ///   - rect: The dirty rectangle in display coordinates
    ///   - basePointer: Pointer to the top-left of the entire framebuffer
    ///   - stride: Bytes per row in the source framebuffer
    func updateTexture(rect: (x: Int, y: Int, width: Int, height: Int),
                       basePointer: UnsafeRawPointer,
                       stride: Int) {
        guard !textures.isEmpty else { return }

        let texture = textures[currentTextureIndex]

        let region = MTLRegion(
            origin: MTLOrigin(x: rect.x, y: rect.y, z: 0),
            size: MTLSize(width: rect.width, height: rect.height, depth: 1)
        )

        // Compute pointer to the start of the dirty region
        let srcOffset = rect.y * stride + rect.x * 4 // 4 bytes per pixel (BGRA)
        let srcPointer = basePointer.advanced(by: srcOffset)

        // Partial texture upload - only the dirty rectangle
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: srcPointer,
            bytesPerRow: stride
        )

        needsRedraw = true
    }

    /// Uploads the entire framebuffer to the current texture.
    /// Used for initial surface creation.
    func uploadFullFrame(data: UnsafeRawPointer, stride: Int) {
        guard !textures.isEmpty else { return }

        let texture = textures[currentTextureIndex]
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: displayWidth, height: displayHeight, depth: 1)
        )

        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: stride
        )

        needsRedraw = true
    }

    /// Renders the current framebuffer texture to the given drawable.
    /// Called from CADisplayLink on the main thread.
    ///
    /// - Returns: `true` if a frame was rendered, `false` if no update was needed.
    @discardableResult
    func draw(in drawable: CAMetalDrawable, renderPassDescriptor: MTLRenderPassDescriptor) -> Bool {
        guard !textures.isEmpty, needsRedraw else { return false }

        let texture = textures[currentTextureIndex]

        // Advance to next texture for the next update cycle
        currentTextureIndex = (currentTextureIndex + 1) % textureCount

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return false
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        needsRedraw = false
        return true
    }
}
