#include <metal_stdlib>
using namespace metal;
struct Quad { float4 rect; float4 uv; float4 color; uint textured; };
struct Raster { float4 position [[position]]; float2 uv; float4 color; uint textured [[flat]]; };
vertex Raster terminal_vertex(uint v [[vertex_id]], uint i [[instance_id]], const device Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
    const float2 corners[6] = {float2(0,0),float2(1,0),float2(0,1),float2(1,0),float2(1,1),float2(0,1)};
    Quad q = quads[i]; float2 p = corners[v]; float2 position = q.rect.xy + p * q.rect.zw;
    Raster out; out.position = float4(position.x / viewport.x * 2 - 1, 1 - position.y / viewport.y * 2, 0, 1);
    out.uv = q.uv.xy + p * q.uv.zw; out.color = q.color; out.textured = q.textured; return out;
}
fragment float4 terminal_fragment(Raster in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler sample(coord::normalized, address::clamp_to_edge, filter::linear);
    if (in.textured == 0) return in.color;
    if (in.textured == 8) {
        // Kitty pixel payloads contain straight alpha. The window uses
        // premultiplied alpha, as do the text and solid-color pipelines.
        float4 pixel = atlas.sample(sample, in.uv);
        return float4(pixel.rgb * pixel.a, pixel.a);
    }
    if (in.textured >= 5) {
        float coverage;
        if (in.textured == 5) {
            float center = 1.5 + sin(in.uv.x * 1.04719755);
            float distance = abs(in.uv.y - center);
            float aa = max(fwidth(in.uv.y) * 0.5, 0.05);
            coverage = 1.0 - smoothstep(0.5 - aa, 0.5 + aa, distance);
        } else if (in.textured == 6) {
            float distance = length(float2(fmod(in.uv.x, 3.0) - 1.5, in.uv.y - 0.75));
            float aa = max(fwidth(in.uv.x) * 0.5, 0.05);
            coverage = 1.0 - smoothstep(0.65 - aa, 0.65 + aa, distance);
        } else {
            float distance = abs(fmod(in.uv.x, 6.0) - 3.0);
            float aa = max(fwidth(in.uv.x) * 0.5, 0.05);
            coverage = 1.0 - smoothstep(2.0 - aa, 2.0 + aa, distance);
        }
        return in.color * coverage;
    }
    if (in.textured >= 2) {
        // A repeating 2x2 dither preserves light, medium, and dark shade characters.
        uint2 pixel = uint2(in.position.xy);
        uint threshold = ((pixel.x & 1) << 1) | ((pixel.x ^ pixel.y) & 1);
        return threshold < in.textured - 1 ? in.color : float4(0);
    }
    return atlas.sample(sample, in.uv) * in.color;
}
