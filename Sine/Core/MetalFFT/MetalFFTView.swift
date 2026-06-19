import SwiftUI
#if canImport(MetalKit)
import MetalKit

/// 120Hz Metal FFT 波形 (顶部 1/3 屏)。线条粗细/辉光/流速随频谱能量与推子音量演变。
/// 数据源 = 主混音输出 (IR-6, 与听感一致)。
public struct MetalFFTView: UIViewRepresentable {
    @Binding var spectrum: [Float]      // 0~1 幅度谱
    var energy: Float                   // 总能量, 驱动辉光/流速
    var accentColor: SIMD4<Float> = SIMD4(1.0, 0.42, 0.17, 1.0) // 信号橙

    public init(spectrum: Binding<[Float]>, energy: Float) {
        self._spectrum = spectrum
        self.energy = energy
    }

    public func makeCoordinator() -> Renderer { Renderer() }

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.preferredFramesPerSecond = 120     // 高刷设备 120Hz
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0.10, 0.105, 0.117, 1.0) // #1A1B1E
        view.delegate = context.coordinator
        context.coordinator.setup(view)
        return view
    }

    public func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.spectrum = spectrum
        context.coordinator.energy = energy
        context.coordinator.accent = accentColor
    }

    /// 渲染器: 把频谱上传为顶点, 用 Shaders.metal 的 pipeline 绘制发光折线。
    public final class Renderer: NSObject, MTKViewDelegate {
        var spectrum: [Float] = []
        var energy: Float = 0
        var accent = SIMD4<Float>(1, 0.42, 0.17, 1)
        private var device: MTLDevice?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?

        func setup(_ view: MTKView) {
            guard let device = view.device else { return }
            self.device = device
            self.queue = device.makeCommandQueue()
            guard let library = device.makeDefaultLibrary() else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fft_vertex")
            desc.fragmentFunction = library.makeFunction(name: "fft_fragment")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            // 加色混合实现辉光叠加
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .one
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        public func draw(in view: MTKView) {
            guard let pipeline, let queue,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  !spectrum.isEmpty,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

            var verts = spectrum
            var count = UInt32(verts.count)
            var glow = energy
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&verts, length: verts.count * MemoryLayout<Float>.stride, index: 0)
            enc.setVertexBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
            enc.setFragmentBytes(&accent, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.setFragmentBytes(&glow, length: MemoryLayout<Float>.stride, index: 1)
            enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: verts.count)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
#endif
