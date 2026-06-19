import Foundation
#if canImport(Accelerate)
import Accelerate

/// 实时 FFT 频谱计算 (设计规范 §3: Metal 动态波形数据源)。
/// 音频 tap 写入环形缓冲, 此处在独立队列读取做 FFT, 绝不反压音频线程 (P1-7)。
public final class FFTProcessor {

    private let log2n: vDSP_Length
    private let n: Int
    private let fftSetup: FFTSetup
    private var window: [Float]

    public init(size: Int = 1024) {
        self.n = size
        self.log2n = vDSP_Length(log2(Float(size)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// 输入时域样本 (>= n), 返回归一化幅度谱 (n/2 个 bin, 0~1)。
    public func magnitudes(_ samples: [Float]) -> [Float] {
        guard samples.count >= n else { return [] }
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        // 转 dB 并归一到 0~1 供 Metal 顶点使用
        var scaled = magnitudes.map { 10 * log10f($0 + 1e-9) }
        let minDB: Float = -80, maxDB: Float = 0
        for i in scaled.indices {
            scaled[i] = max(0, min(1, (scaled[i] - minDB) / (maxDB - minDB)))
        }
        return scaled
    }
}
#endif
