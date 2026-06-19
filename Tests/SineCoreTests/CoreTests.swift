import XCTest
@testable import SineCore

/// 与 reference/tests/test_sine_core.py 一一对应的 Swift 回归测试。
/// 在 macOS 上 `swift test` 运行; 验证三大核心难点的数学正确性。
final class CoreTests: XCTestCase {

    let sr: Double = 44100

    // MARK: 分块计划 (难点一)

    func testMemoryTiers() {
        XCTAssertEqual(ChunkPlanner.selectPlan(physicalMemoryGB: 4).model, .spleeterCoreML)
        XCTAssertEqual(ChunkPlanner.selectPlan(physicalMemoryGB: 4).segmentSec, 15)
        XCTAssertEqual(ChunkPlanner.selectPlan(physicalMemoryGB: 6).model, .htDemucsFP16)
        XCTAssertEqual(ChunkPlanner.selectPlan(physicalMemoryGB: 6).segmentSec, 20)
        XCTAssertEqual(ChunkPlanner.selectPlan(physicalMemoryGB: 8).segmentSec, 30)
        for gb in [3.0, 6.0, 12.0] {
            XCTAssertEqual(ChunkPlanner.selectPlan(physicalMemoryGB: gb).overlapSec, 2.0)
        }
    }

    func testChunksCoverAllSamples() {
        let total = 5 * 60 * Int(sr)
        let plan = ChunkPlanner.selectPlan(physicalMemoryGB: 6, sampleRate: sr)
        let chunks = ChunkPlanner.planChunks(totalFrames: total,
                                             segmentFrames: plan.segmentFrames,
                                             overlapFrames: plan.overlapFrames)
        XCTAssertEqual(chunks.first?.lowerBound, 0)
        XCTAssertEqual(chunks.last?.upperBound, total)
        let hop = plan.segmentFrames - plan.overlapFrames
        for i in 1..<(chunks.count - 1) {
            XCTAssertEqual(chunks[i].lowerBound, i * hop)
            XCTAssertEqual(chunks[i - 1].upperBound - chunks[i].lowerBound, plan.overlapFrames)
        }
    }

    func testShortAudioSingleChunk() {
        let plan = ChunkPlanner.selectPlan(physicalMemoryGB: 6, sampleRate: sr)
        let total = 5 * Int(sr)
        let chunks = ChunkPlanner.planChunks(totalFrames: total,
                                             segmentFrames: plan.segmentFrames,
                                             overlapFrames: plan.overlapFrames)
        XCTAssertEqual(chunks, [0..<total])
    }

    // MARK: Overlap-Add (难点一)

    func testCrossfadePartitionOfUnity() {
        let (wOut, wIn) = OverlapAdd.crossfadeWeights(512)
        for i in 0..<512 {
            XCTAssertEqual(wOut[i] + wIn[i], 1.0, accuracy: 1e-6)
        }
    }

    func testIdentityReconstruction() {
        let total = 200_000, overlap = 4000, segLen = 50_000
        let hop = segLen - overlap
        var signal = [Float](repeating: 0, count: total)
        for t in 0..<total { signal[t] = sinf(2 * .pi * 440 * Float(t) / Float(sr)) * 0.8 }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < total {
            let end = min(start + segLen, total)
            ranges.append(start..<end)
            if end >= total { break }
            start += hop
        }
        let outputs = ranges.map { Array(signal[$0]) }
        let recon = OverlapAdd.stitch(chunkOutputs: outputs, ranges: ranges,
                                      totalFrames: total, overlapFrames: overlap)
        var maxErr: Float = 0
        for i in 0..<total { maxErr = max(maxErr, abs(recon[i] - signal[i])) }
        XCTAssertLessThan(maxErr, 1e-4, "重建误差过大: \(maxErr)")
    }

    func testNoSeamDiscontinuity() {
        let total = 120_000, overlap = 4000, segLen = 50_000
        let hop = segLen - overlap
        var base = [Float](repeating: 0, count: total)
        for t in 0..<total { base[t] = sinf(2 * .pi * 220 * Float(t) / Float(sr)) }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < total {
            let end = min(start + segLen, total)
            ranges.append(start..<end)
            if end >= total { break }
            start += hop
        }
        let gains: [Float] = [1.0, 1.03, 0.98, 1.01, 0.99]
        let outputs = ranges.enumerated().map { i, r in Array(base[r]).map { $0 * gains[i % gains.count] } }
        let recon = OverlapAdd.stitch(chunkOutputs: outputs, ranges: ranges,
                                      totalFrames: total, overlapFrames: overlap)
        var maxDiff: Float = 0
        for i in 1..<total { maxDiff = max(maxDiff, abs(recon[i] - recon[i - 1])) }
        XCTAssertLessThan(maxDiff, 0.1, "接缝出现突变: \(maxDiff)")
    }

    // MARK: 时钟对齐 (难点二)

    func testAllTracksShareAnchor() {
        let total = 3 * 60 * Int(sr)
        let anchor = SyncClock.computeAnchor(nowFrame: 500_000, bufferSec: 0.1, sampleRate: sr)
        let seek = 30 * Int(sr)
        let sched = SyncClock.segmentSchedule(seekFrame: seek, totalFrames: total, anchorFrame: anchor, numTracks: 4)
        XCTAssertEqual(sched.count, 4)
        XCTAssertEqual(Set(sched.map { $0.atFrame }), [anchor])
        XCTAssertEqual(Set(sched.map { $0.startingFrame }), [seek])
        sched.forEach { XCTAssertEqual($0.frameCount, total - seek) }
    }

    func testSeekClamped() {
        let sched = SyncClock.segmentSchedule(seekFrame: 5000, totalFrames: 1000, anchorFrame: 0)
        sched.forEach {
            XCTAssertEqual($0.startingFrame, 1000)
            XCTAssertEqual($0.frameCount, 0)
        }
    }

    // MARK: Solo/Mute 真值表 (FRD §4)

    func testNoSoloRespectsMute() {
        XCTAssertEqual(MixMath.audibleMask(solos: [false, false, false, false],
                                           mutes: [false, true, false, false]),
                       [true, false, true, true])
    }
    func testSoloModeOnlySoloed() {
        XCTAssertEqual(MixMath.audibleMask(solos: [true, false, true, false],
                                           mutes: [false, false, false, false]),
                       [true, false, true, false])
    }
    func testMuteOverridesSolo() {
        XCTAssertEqual(MixMath.audibleMask(solos: [true, true, false, false],
                                           mutes: [false, true, false, false]),
                       [true, false, false, false])
    }

    // MARK: 归一化防削波

    func testNoChangeUnderCeiling() {
        XCTAssertEqual(MixMath.normalizeGain(peak: 0.5), 1.0, accuracy: 1e-6)
    }
    func testAttenuateWhenClipping() {
        let gain = MixMath.normalizeGain(peak: 2.0, ceilingDBFS: -0.1)
        XCTAssertLessThan(gain, 1.0)
        XCTAssertEqual(2.0 * gain, powf(10, -0.1 / 20), accuracy: 1e-5)
    }

    // MARK: ETA

    func testEtaEstimate() {
        let eta = EtaEstimator(totalChunks: 8)
        XCTAssertNil(eta.etaSeconds())
        for _ in 0..<4 { eta.recordChunk(duration: 2.0) }
        XCTAssertEqual(eta.progress, 0.5, accuracy: 1e-9)
        XCTAssertEqual(eta.etaSeconds()!, 8.0, accuracy: 1e-6)
    }

    // MARK: EQ 预设

    func testEqPresets() {
        for s in EQPresets.all { XCTAssertEqual(s.bands.count, 10) }
        XCTAssertTrue(EQPresets.flat.bands.allSatisfy { $0.gain == 0 })
    }
}
