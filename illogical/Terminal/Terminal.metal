#include <metal_stdlib>
using namespace metal;

// Must match TerminalQuad.Kind in MetalRenderer.swift.
enum QuadKind : uint {
    solid = 0,
    glyph = 1,      // Grayscale atlas coverage, tinted by the quad color.
    colorGlyph = 2, // Premultiplied RGBA atlas texels (emoji).
    image = 3,      // Straight-alpha Kitty image, normalized coordinates.
    curlyLine = 4,  // Procedural decorations in device-pixel pattern space.
    dottedLine = 5,
    dashedLine = 6,
};

// Must match TerminalQuad in MetalRenderer.swift (64-byte stride).
struct Quad {
    float4 rect;      // Origin and size in points.
    float4 uv;        // Texture or pattern origin and extent.
    float4 color;     // Premultiplied.
    uint kind;
    float thickness;  // Decoration stroke thickness in device pixels.
    uint2 padding;
};

// Must match TerminalUniforms in MetalRenderer.swift.
struct Uniforms {
    float2 viewport;  // Drawable size in points.
    float cellWidth;  // Decoration pattern period in device pixels.
    uint smoothGlyphs; // Scaled previews filter the atlas linearly.
};

struct Raster {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint kind [[flat]];
    float thickness [[flat]];
};

vertex Raster terminal_vertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
                              const device Quad *quads [[buffer(0)]], constant Uniforms &uniforms [[buffer(1)]]) {
    const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
    Quad quad = quads[instance];
    float2 corner = corners[vertexID];
    float2 position = quad.rect.xy + corner * quad.rect.zw;
    Raster out;
    out.position = float4(position.x / uniforms.viewport.x * 2 - 1, 1 - position.y / uniforms.viewport.y * 2, 0, 1);
    out.uv = quad.uv.xy + corner * quad.uv.zw;
    out.color = quad.color;
    out.kind = quad.kind;
    out.thickness = quad.thickness;
    return out;
}

// Coverage of a stroke at signed distance `distance` (pixels) from its edge,
// antialiased over one screen pixel of pattern space.
static float edgeCoverage(float distance, float2 uv) {
    float pixel = max(length(fwidth(uv)) * 0.7071, 1e-3);
    return saturate(0.5 - distance / pixel);
}

// One wave per cell, peaking at the cell center, like Ghostty's undercurl.
// The quad spans the wave's amplitude plus one stroke thickness.
static float curlyCoverage(float2 p, float thickness, float cellWidth) {
    float amplitude = cellWidth / M_PI_F;
    float phase = 2 * M_PI_F * p.x / cellWidth;
    float center = thickness / 2 + amplitude * (1 + cos(phase)) / 2;
    float slope = -amplitude * M_PI_F / cellWidth * sin(phase);
    float distance = abs(p.y - center) / sqrt(1 + slope * slope);
    return edgeCoverage(distance - thickness / 2, p);
}

// Evenly spaced round dots, sized and counted per cell like Ghostty's.
static float dottedCoverage(float2 p, float thickness, float cellWidth) {
    float radius = M_SQRT1_2_F * thickness;
    float count = max(1.0, min(min(ceil(cellWidth / (4 * radius)), floor(cellWidth / (3 * radius))),
                               floor(cellWidth / (2 * radius + 1))));
    float spacing = cellWidth / count;
    float x = fmod(p.x, cellWidth);
    float2 center = float2((floor(x / spacing) + 0.5) * spacing, ceil(radius));
    return edgeCoverage(length(float2(x, p.y) - center) - radius, p);
}

// Ghostty's per-cell dash pattern: dashes one third of a cell wide, plus one.
static float dashedCoverage(float2 p, float cellWidth) {
    float dash = floor(cellWidth / 3) + 1;
    return fmod(floor(fmod(p.x, cellWidth) / dash), 2.0) == 0 ? 1 : 0;
}

fragment float4 terminal_fragment(Raster in [[stage_in]], constant Uniforms &uniforms [[buffer(1)]],
                                  texture2d<float> glyphs [[texture(0)]], texture2d<float> colorGlyphs [[texture(1)]],
                                  texture2d<float> imageTexture [[texture(2)]]) {
    // Full-size glyphs sample exact texels, like Ghostty. Scaled previews
    // and images interpolate.
    constexpr sampler exact(coord::pixel, address::clamp_to_edge, filter::nearest);
    constexpr sampler smooth(coord::pixel, address::clamp_to_edge, filter::linear);
    constexpr sampler normalized(coord::normalized, address::clamp_to_edge, filter::linear);
    switch (in.kind) {
    case solid:
        return in.color;
    case glyph:
        return in.color * (uniforms.smoothGlyphs ? glyphs.sample(smooth, in.uv) : glyphs.sample(exact, in.uv)).r;
    case colorGlyph:
        return (uniforms.smoothGlyphs ? colorGlyphs.sample(smooth, in.uv) : colorGlyphs.sample(exact, in.uv)) * in.color.a;
    case image: {
        // Kitty pixel payloads contain straight alpha; the window is premultiplied.
        float4 pixel = imageTexture.sample(normalized, in.uv);
        return float4(pixel.rgb * pixel.a, pixel.a);
    }
    case curlyLine:
        return in.color * curlyCoverage(in.uv, in.thickness, uniforms.cellWidth);
    case dottedLine:
        return in.color * dottedCoverage(in.uv, in.thickness, uniforms.cellWidth);
    case dashedLine:
        return in.color * dashedCoverage(in.uv, uniforms.cellWidth);
    default:
        return float4(0);
    }
}
