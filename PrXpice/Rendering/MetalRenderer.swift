import Foundation
import Metal
import QuartzCore
import CoreVideo

/// GPU-accelerated renderer for SPICE framebuffer display.
///
/// Thread safety: `updateTexture(region:data:stride:)` is safe to call from the
/// GLib thread. Rendering via `draw(in:)` happens on the CADisplayLink thread.
/// Triple-buffered texture pool avoids contention.
final class MetalRenderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    // YUV pipeline for H.264/H.265 NV12 zero-copy fast path
    private var yuvPipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    // CVMetalTexture refs keep the CVPixelBuffer alive through the render
    private var yTextureCVRef: CVMetalTexture?
    private var uvTextureCVRef: CVMetalTexture?
    private var videoYTexture: MTLTexture?
    private var videoUVTexture: MTLTexture?
    private(set) var needsVideoRedraw = false

    // Single shared-storage texture — CPU writes dirty rects directly, GPU reads each frame
    private var texture: MTLTexture?

    // Display dimensions
    private(set) var displayWidth: Int = 0
    private(set) var displayHeight: Int = 0

    // True when pixel data has changed since the last GPU draw.
    // Read on the CADisplayLink thread; written on the GLib thread.
    // Atomic via OSAtomicOr32/OSAtomicAnd32 would be ideal but a plain Bool
    // with unified memory is safe here: a missed frame just delays by 1 tick.
    private(set) var needsRedraw = false

    // Zoom/pan uniforms set each frame by MetalDisplayViewController
    var zoomScale: Float = 1.0
    var panNormalized: SIMD2<Float> = .zero  // pan as fraction of view size

    private struct ZoomUniforms {
        var uvOffset: SIMD2<Float>
        var uvScale: Float
        var _pad: Float = 0
    }

    private func makeZoomUniforms() -> ZoomUniforms {
        let s = 1.0 / zoomScale
        return ZoomUniforms(
            uvOffset: SIMD2<Float>(
                0.5 * (1 - s) - panNormalized.x * s,
                0.5 * (1 - s) - panNormalized.y * s
            ),
            uvScale: s
        )
    }

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

        // YUV pipeline for NV12 H.264/H.265 zero-copy fast path
        if let yuvFragmentFunc = library.makeFunction(name: "yuvFragmentShader") {
            let yuvPipelineDesc = MTLRenderPipelineDescriptor()
            yuvPipelineDesc.vertexFunction = vertexFunc
            yuvPipelineDesc.fragmentFunction = yuvFragmentFunc
            yuvPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            yuvPipelineState = try? device.makeRenderPipelineState(descriptor: yuvPipelineDesc)
        }

        // CVMetalTextureCache for zero-copy NV12 plane import
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
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
        descriptor.storageMode = .shared // CPU-writable, GPU-readable — unified memory

        texture = device.makeTexture(descriptor: descriptor)
        needsRedraw = true

        Log.rendering.info("Created surface: \(width)x\(height)")
    }

    /// Destroys texture when the display surface is removed.
    func destroySurface() {
        texture = nil
        displayWidth = 0
        displayHeight = 0
        needsRedraw = false
        videoYTexture = nil
        videoUVTexture = nil
        yTextureCVRef = nil
        uvTextureCVRef = nil
        needsVideoRedraw = false
    }

    /// Zero-copy import of a decoded NV12 CVPixelBuffer as Metal textures.
    /// Called from the GLib thread; CVMetalTextureCache is thread-safe.
    func updateVideoTexture(pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        // Y plane (luma) — full resolution, R8Unorm
        var yCVTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .r8Unorm, w, h, 0, &yCVTex)
        // UV plane (chroma) — half resolution, RG8Unorm
        var uvCVTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .rg8Unorm, w / 2, h / 2, 1, &uvCVTex)

        guard let yCVTex = yCVTex, let uvCVTex = uvCVTex else { return }
        yTextureCVRef  = yCVTex
        uvTextureCVRef = uvCVTex
        videoYTexture  = CVMetalTextureGetTexture(yCVTex)
        videoUVTexture = CVMetalTextureGetTexture(uvCVTex)
        needsVideoRedraw = true
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
        guard let texture = texture else { return }

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
        guard let texture = texture else { return }

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
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        // NV12 fast path: H.264/H.265 video frame decoded via VideoToolbox
        if let yTex = videoYTexture, let uvTex = videoUVTexture, needsVideoRedraw,
           let yuvPS = yuvPipelineState {
            needsVideoRedraw = false
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }
            var uniforms = makeZoomUniforms()
            encoder.setRenderPipelineState(yuvPS)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ZoomUniforms>.size, index: 0)
            encoder.setFragmentTexture(yTex,  index: 0)
            encoder.setFragmentTexture(uvTex, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return true
        }

        // BGRA path: static display content or MJPEG fallback
        guard let texture = texture else {
            // No surface yet — clear to black and present
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return false
        }

        // Skip re-encoding on idle frames; saves GPU work on static screens.
        guard needsRedraw else { return false }
        needsRedraw = false

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return false
        }

        var uniforms = makeZoomUniforms()
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ZoomUniforms>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }
}
