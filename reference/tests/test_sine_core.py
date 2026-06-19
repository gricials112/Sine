"""核心算法功能测试 (本环境可运行)。

验证三大核心难点的数学正确性，作为 Swift 实现的回归基线。
运行: cd reference && python -m pytest -v
"""
import math
import os
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sine_core import (  # noqa: E402
    EQ_PRESETS,
    EtaEstimator,
    audible_mask,
    compute_sync_anchor,
    crossfade_weights,
    mixdown,
    normalize_mix,
    overlap_add_stitch,
    plan_chunks,
    segment_schedule,
    select_chunk_plan,
)

SR = 44100


# ---------------------------------------------------------------------------
# 难点一: 分块计划
# ---------------------------------------------------------------------------

class TestChunkPlan:
    def test_memory_tiers(self):
        assert select_chunk_plan(4.0)["model"] == "spleeter-coreml"
        assert select_chunk_plan(4.0)["segment_sec"] == 15.0
        assert select_chunk_plan(6.0)["model"] == "ht-demucs-fp16"
        assert select_chunk_plan(6.0)["segment_sec"] == 20.0
        assert select_chunk_plan(8.0)["segment_sec"] == 30.0
        # overlap 恒为 2s
        for gb in (3, 6, 12):
            assert select_chunk_plan(gb)["overlap_sec"] == 2.0

    def test_chunks_cover_all_samples(self):
        total = 5 * 60 * SR  # 5 分钟
        plan = select_chunk_plan(6.0, SR)
        chunks = plan_chunks(total, plan["segment_frames"], plan["overlap_frames"])
        # 第一块从 0 开始, 最后一块到 total
        assert chunks[0][0] == 0
        assert chunks[-1][1] == total
        # 相邻块重叠正好 overlap_frames (除最后一块可能更短)
        hop = plan["segment_frames"] - plan["overlap_frames"]
        for i in range(1, len(chunks) - 1):
            assert chunks[i][0] == i * hop
            overlap = chunks[i - 1][1] - chunks[i][0]
            assert overlap == plan["overlap_frames"]

    def test_short_audio_single_chunk(self):
        plan = select_chunk_plan(6.0, SR)
        total = 5 * SR  # 5 秒 < 20 秒
        chunks = plan_chunks(total, plan["segment_frames"], plan["overlap_frames"])
        assert chunks == [(0, total)]

    def test_invalid_segment(self):
        with pytest.raises(ValueError):
            plan_chunks(1000, 100, 100)


# ---------------------------------------------------------------------------
# 难点一: Overlap-Add 无缝拼接
# ---------------------------------------------------------------------------

class TestOverlapAdd:
    def test_linear_partition_of_unity(self):
        fo, fi = crossfade_weights(512)
        # 线性/三角窗: w_out + w_in == 1 (源分离重叠区为相关信号, 见 sine_core 注释)
        np.testing.assert_allclose(fo + fi, np.ones(512), atol=1e-12)

    def test_identity_reconstruction(self):
        """若各块都是同一信号的对应切片, 拼接结果应≈原信号 (接缝无台阶)。"""
        total = 200000
        overlap = 4000
        seg_len = 50000
        hop = seg_len - overlap
        t = np.arange(total)
        signal = np.sin(2 * math.pi * 440 * t / SR) * 0.8

        ranges = []
        start = 0
        while start < total:
            end = min(start + seg_len, total)
            ranges.append((start, end))
            if end >= total:
                break
            start += hop
        outputs = [signal[s:e].copy() for (s, e) in ranges]

        recon = overlap_add_stitch(outputs, ranges, total, overlap)
        # 完整重建: 误差极小
        max_err = np.max(np.abs(recon - signal))
        assert max_err < 1e-9, f"重建误差过大: {max_err}"

    def test_no_seam_discontinuity(self):
        """即使相邻块有轻微增益差, 接缝处也应平滑 (无突变台阶)。"""
        total = 120000
        overlap = 4000
        seg_len = 50000
        hop = seg_len - overlap
        t = np.arange(total)
        base = np.sin(2 * math.pi * 220 * t / SR)

        ranges = []
        start = 0
        while start < total:
            end = min(start + seg_len, total)
            ranges.append((start, end))
            if end >= total:
                break
            start += hop
        # 给每块乘以略不同的增益, 模拟模型块间微小差异
        gains = [1.0, 1.03, 0.98, 1.01, 0.99]
        outputs = [base[s:e] * gains[i % len(gains)] for i, (s, e) in enumerate(ranges)]

        recon = overlap_add_stitch(outputs, ranges, total, overlap)
        # 相邻样本差分的最大跳变应远小于信号幅度 (无咔哒)
        diff = np.abs(np.diff(recon))
        assert np.max(diff) < 0.1, f"接缝出现突变: {np.max(diff)}"

    def test_length_invariant(self):
        total = 123457
        overlap = 4000
        seg_len = 40000
        hop = seg_len - overlap
        ranges = []
        start = 0
        while start < total:
            end = min(start + seg_len, total)
            ranges.append((start, end))
            if end >= total:
                break
            start += hop
        outputs = [np.ones(e - s) for (s, e) in ranges]
        recon = overlap_add_stitch(outputs, ranges, total, overlap)
        assert len(recon) == total


# ---------------------------------------------------------------------------
# 难点二: 多轨时钟对齐
# ---------------------------------------------------------------------------

class TestSyncClock:
    def test_anchor_offset(self):
        now = 1_000_000
        anchor = compute_sync_anchor(now, 0.1, SR)
        assert anchor == now + int(round(0.1 * SR))

    def test_all_tracks_share_anchor_and_start(self):
        total = 3 * 60 * SR
        anchor = compute_sync_anchor(500000, 0.1, SR)
        seek = 30 * SR
        sched = segment_schedule(seek, total, anchor, num_tracks=4)
        assert len(sched) == 4
        # 关键不变量: 4 轨 at_frame / starting_frame 完全一致 -> 无漂移
        at_frames = {s["at_frame"] for s in sched}
        start_frames = {s["starting_frame"] for s in sched}
        assert at_frames == {anchor}
        assert start_frames == {seek}
        for s in sched:
            assert s["frame_count"] == total - seek

    def test_seek_clamped(self):
        total = 1000
        sched = segment_schedule(5000, total, 0, num_tracks=4)
        assert all(s["starting_frame"] == total for s in sched)
        assert all(s["frame_count"] == 0 for s in sched)


# ---------------------------------------------------------------------------
# Solo / Mute 真值表 (FRD §4)
# ---------------------------------------------------------------------------

class TestSoloMute:
    def test_no_solo_respects_mute(self):
        solos = [False, False, False, False]
        mutes = [False, True, False, False]
        assert audible_mask(solos, mutes) == [True, False, True, True]

    def test_solo_mode_only_soloed(self):
        solos = [True, False, True, False]
        mutes = [False, False, False, False]
        assert audible_mask(solos, mutes) == [True, False, True, False]

    def test_mute_overrides_solo(self):
        solos = [True, True, False, False]
        mutes = [False, True, False, False]
        # 轨1 solo+mute -> mute 优先 -> False
        assert audible_mask(solos, mutes) == [True, False, False, False]

    def test_all_muted_silent(self):
        assert audible_mask([False] * 4, [True] * 4) == [False] * 4


# ---------------------------------------------------------------------------
# 导出归一化防削波
# ---------------------------------------------------------------------------

class TestNormalize:
    def test_no_change_when_under_ceiling(self):
        mix = np.array([0.5, -0.5, 0.3])
        out, gain = normalize_mix(mix)
        assert gain == 1.0
        np.testing.assert_array_equal(out, mix)

    def test_attenuate_when_clipping(self):
        mix = np.array([1.5, -2.0, 0.5])  # 超过 0dBFS
        out, gain = normalize_mix(mix, ceiling_dbfs=-0.1)
        peak = np.max(np.abs(out))
        ceiling = 10 ** (-0.1 / 20)
        assert peak <= ceiling + 1e-9
        assert gain < 1.0

    def test_silent_input(self):
        out, gain = normalize_mix(np.zeros(10))
        assert gain == 1.0

    def test_mixdown_solo_silences_others(self):
        a = np.ones(100) * 0.5
        b = np.ones(100) * 0.5
        c = np.ones(100) * 0.5
        d = np.ones(100) * 0.5
        # solo 轨0 -> 仅轨0
        out = mixdown([a, b, c, d], [1, 1, 1, 1],
                      solos=[True, False, False, False],
                      mutes=[False, False, False, False])
        np.testing.assert_allclose(out, a)


# ---------------------------------------------------------------------------
# ETA
# ---------------------------------------------------------------------------

class TestEta:
    def test_no_estimate_before_first_chunk(self):
        eta = EtaEstimator(total_chunks=8)
        assert eta.eta_seconds() is None
        assert eta.progress() == 0.0

    def test_estimate_and_progress(self):
        eta = EtaEstimator(total_chunks=8)
        for _ in range(4):
            eta.record_chunk(2.0)  # 每块 2s
        assert eta.progress() == 0.5
        # 剩 4 块 * 2s = 8s
        assert eta.eta_seconds() == pytest.approx(8.0)

    def test_eta_reaches_zero(self):
        eta = EtaEstimator(total_chunks=2)
        eta.record_chunk(1.0)
        eta.record_chunk(1.0)
        assert eta.eta_seconds() == 0.0
        assert eta.progress() == 1.0


# ---------------------------------------------------------------------------
# EQ 预设完整性
# ---------------------------------------------------------------------------

class TestEqPresets:
    def test_all_presets_have_10_bands(self):
        for name, bands in EQ_PRESETS.items():
            assert len(bands) == 10, f"{name} 必须 10 段"

    def test_flat_is_zero(self):
        assert all(g == 0 for g in EQ_PRESETS["flat"])
