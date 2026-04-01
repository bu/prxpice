#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct ZoomUniforms {
    float2 uvOffset;  // UV of the top-left corner of the visible region
    float  uvScale;   // Fraction of the texture visible (= 1/zoom)
    float  _pad;
};

// Full-screen textured quad with zoom/pan applied in UV space.
vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                               constant ZoomUniforms &uniforms [[buffer(0)]]) {
    // Triangle strip positions for full-screen quad
    // vertexID: 0=BL, 1=BR, 2=TL, 3=TL, 4=BR, 5=TR
    const float2 positions[] = {
        float2(-1.0, -1.0), // bottom-left
        float2( 1.0, -1.0), // bottom-right
        float2(-1.0,  1.0), // top-left
        float2(-1.0,  1.0), // top-left
        float2( 1.0, -1.0), // bottom-right
        float2( 1.0,  1.0), // top-right
    };

    // UV coordinates (flipped Y for Metal's texture coordinate system)
    const float2 texCoords[] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(1.0, 0.0),
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID] * uniforms.uvScale + uniforms.uvOffset;
    return out;
}

// Simple texture sampling - BGRA native format means no swizzle needed.
// Returns black for any UV coordinate outside the VM display area (e.g. when panned
// beyond the content boundary while zoomed in).
fragment half4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<half> framebuffer [[texture(0)]]) {
    float2 uv = in.texCoord;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return half4(0.0, 0.0, 0.0, 1.0);
    }
    constexpr sampler textureSampler(mag_filter::linear,
                                      min_filter::linear,
                                      address::clamp_to_edge);
    return framebuffer.sample(textureSampler, uv);
}

// NV12 YUV→RGB fragment shader (BT.601 limited range, used for H.264/H.265 streams).
// Texture 0: Y plane  (R8Unorm, full resolution luma)
// Texture 1: UV plane (RG8Unorm, half-resolution chroma, Cb in R, Cr in G)
fragment half4 yuvFragmentShader(VertexOut in [[stage_in]],
                                  texture2d<half> y_tex  [[texture(0)]],
                                  texture2d<half> uv_tex [[texture(1)]]) {
    float2 uv = in.texCoord;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return half4(0.0, 0.0, 0.0, 1.0);

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    // Y: limited range 16–235 → normalize to [0,1]
    float y    = (float(y_tex.sample(s, uv).r)  - 16.0/255.0) * (255.0/219.0);
    // CbCr: limited range 16–240 → shift to [-0.5, 0.5]
    float2 cbcr = float2(uv_tex.sample(s, uv).rg) - float2(128.0/255.0);

    float r = y + 1.402   * cbcr.y;
    float g = y - 0.34414 * cbcr.x - 0.71414 * cbcr.y;
    float b = y + 1.772   * cbcr.x;

    return half4(half3(clamp(float3(r, g, b), 0.0, 1.0)), 1.0);
}
