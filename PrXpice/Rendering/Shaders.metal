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
