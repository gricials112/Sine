#include <metal_stdlib>
using namespace metal;

// FFT 波形顶点: 把 [0,1] 幅度谱映射到屏幕折线, 频率沿 x, 幅度沿 y。
struct VOut {
    float4 position [[position]];
    float  intensity;
};

vertex VOut fft_vertex(uint vid [[vertex_id]],
                       const device float* mags [[buffer(0)]],
                       constant uint& count [[buffer(1)]]) {
    VOut o;
    float x = (float(vid) / float(count - 1)) * 2.0 - 1.0;   // -1..1
    float m = mags[vid];
    float y = m * 1.6 - 0.8;                                  // 居中显示
    o.position = float4(x, y, 0.0, 1.0);
    o.intensity = m;
    return o;
}

// 发光亮度随幅度与全局能量演变 (越响越亮越粗的视觉由 blend=add 叠加近似)。
fragment float4 fft_fragment(VOut in [[stage_in]],
                             constant float4& accent [[buffer(0)]],
                             constant float& glow [[buffer(1)]]) {
    float a = clamp(in.intensity * (0.5 + glow), 0.0, 1.0);
    return float4(accent.rgb, accent.a * a);
}
