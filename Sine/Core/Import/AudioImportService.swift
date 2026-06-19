import Foundation
#if canImport(AVFoundation)
import AVFoundation

public enum ImportError: Error {
    case noAudioTrack       // UC-01 A1
    case drmProtected       // UC-01 A3
    case decodeFailed       // UC-01 A4
    case insufficientDisk
}

/// 导入与取流 (UC-01)。AVAssetReader 流式解码 -> 重采样 44.1k/Float32/立体声 -> 边解边写临时 WAV。
/// 关键 (P0-1): 解码缓冲固定 ≤1s/批, 绝不在内存持有整文件 PCM。
public final class AudioImportService {

    public struct Result { public let pcmURL: URL; public let duration: TimeInterval; public let sampleRate: Double }

    private let targetSampleRate: Double = 44100
    public init() {}

    public func extractAudio(from sourceURL: URL,
                             to pcmURL: URL,
                             maxDuration: TimeInterval = 600,
                             progress: ((Double) -> Void)? = nil) async throws -> Result {
        let asset = AVURLAsset(url: sourceURL)

        // DRM / 无音轨校验
        let isProtected = try? await asset.load(.hasProtectedContent)
        if isProtected == true { throw ImportError.drmProtected }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw ImportError.noAudioTrack }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 2
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else { throw ImportError.decodeFailed }
        reader.add(output)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: targetSampleRate, channels: 2, interleaved: false)!
        let outFile = try AVAudioFile(forWriting: pcmURL, settings: format.settings)

        guard reader.startReading() else { throw ImportError.decodeFailed }
        var processed: TimeInterval = 0

        // 流式: 逐 sampleBuffer 写盘, 不累积 (P0-1)
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            try autoreleasepool {
                if let buf = Self.pcmBuffer(from: sampleBuffer, format: format) {
                    try outFile.write(from: buf)
                    processed += Double(buf.frameLength) / targetSampleRate
                    progress?(duration > 0 ? min(1.0, processed / duration) : 0)
                }
                CMSampleBufferInvalidate(sampleBuffer)
            }
        }
        if reader.status == .failed { throw ImportError.decodeFailed }

        return Result(pcmURL: pcmURL, duration: duration, sampleRate: targetSampleRate)
    }

    private static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)

        var lengthAtOffset = 0, totalLength = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
              let raw = dataPtr else { return nil }
        // 交错 Float32 [L,R,L,R...] -> 非交错
        raw.withMemoryRebound(to: Float.self, capacity: totalLength / 4) { interleaved in
            if let ch = buf.floatChannelData {
                for f in 0..<frames {
                    ch[0][f] = interleaved[f * 2]
                    ch[1][f] = interleaved[f * 2 + 1]
                }
            }
        }
        return buf
    }
}
#endif
