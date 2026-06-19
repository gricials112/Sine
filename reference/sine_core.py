"""
Sine — 核心算法参考实现 (Python)
============================================

本模块是 iOS Swift 实现的"算法事实来源 (source of truth)"。
由于 iOS 工程无法在 Linux CI 上编译运行，这里用纯算法等价实现，
配合 tests/ 下的 pytest 在本环境验证三大核心难点的数学正确性：

  难点一: Overlap-Add 分块无缝拼接 (等功率窗)        -> overlap_add_stitch
  难点二: 多轨采样级时钟对齐                          -> compute_sync_anchor / segment_schedule
  难点三/导出: 混音归一化防削波 + Solo/Mute 真值表    -> normalize_mix / audible_mask

附带工程辅助:
  - 内存分级选块                                       -> select_chunk_plan
  - 进度 ETA 估算                                      -> EtaEstimator
  - EQ 预设表                                          -> EQ_PRESETS

这些函数被设计为"纯函数 / 无平台依赖"，Swift 端按相同公式实现即可。
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import List, Sequence

import numpy as np


# ---------------------------------------------------------------------------
# 难点一: 分块 + Overlap-Add
# ---------------------------------------------------------------------------

def select_chunk_plan(physical_memory_gb: float, sample_rate: int = 44100) -> dict:
    """根据设备物理内存选择模型与分块参数 (对应 SeparationEngine 降级链)。

    返回: { model, segment_sec, overlap_sec, segment_frames, overlap_frames }
    规则 (与 FRD/设计方案一致):
        <=4GB  -> Spleeter 轻量, 15s 块
        <=6GB  -> HT-Demucs FP16, 20s 块
        >6GB   -> HT-Demucs FP16, 30s 块
    overlap 固定 2.0s。
    """
    if physical_memory_gb <= 4.0:
        model, segment = "spleeter-coreml", 15.0
    elif physical_memory_gb <= 6.0:
        model, segment = "ht-demucs-fp16", 20.0
    else:
        model, segment = "ht-demucs-fp16", 30.0
    overlap = 2.0
    return {
        "model": model,
        "segment_sec": segment,
        "overlap_sec": overlap,
        "segment_frames": int(round(segment * sample_rate)),
        "overlap_frames": int(round(overlap * sample_rate)),
    }


def plan_chunks(total_frames: int, segment_frames: int, overlap_frames: int) -> List[tuple]:
    """把 [0, total_frames) 切成带 overlap 的块。

    返回每块的 (start, end) 半开区间。相邻块在 overlap_frames 上重叠。
    步长 hop = segment_frames - overlap_frames。
    保证: 覆盖全部样本; 最后一块对齐 total_frames; 无空块。
    """
    if segment_frames <= overlap_frames:
        raise ValueError("segment_frames 必须大于 overlap_frames")
    if total_frames <= 0:
        return []
    if total_frames <= segment_frames:
        return [(0, total_frames)]

    hop = segment_frames - overlap_frames
    chunks = []
    start = 0
    while start < total_frames:
        end = min(start + segment_frames, total_frames)
        chunks.append((start, end))
        if end >= total_frames:
            break
        start += hop
    return chunks


def crossfade_weights(n: int) -> tuple:
    """生成长度 n 的"线性/三角"交叉淡化权重 (w_out, w_in)。

    重要 (测试驱动的修正):
      源分离的 Overlap-Add 中, 相邻块在重叠区输出的是"同一段源信号"的两个
      估计 (相关信号)。此时应使用满足 w_out + w_in == 1 的线性权重, 它:
        1) 对相关/相同内容做加权平均 -> 完美重建, 接缝无台阶;
        2) 平均两个估计 -> 抵消块边界处模型误差。
      若误用等功率窗 (w_out^2 + w_in^2 == 1), 相关内容会被放大最高 +3dB,
      产生接缝鼓包。等功率仅适用于"交叉不同信号"(如 DJ 过渡), 非本场景。
      这与官方 Demucs 的三角窗 overlap-add 一致。
    """
    if n <= 0:
        return np.array([], dtype=np.float64), np.array([], dtype=np.float64)
    # t 从接近 0 -> 接近 1 (对称取中点), 线性
    t = (np.arange(n) + 0.5) / n
    w_in = t            # 0 -> 1
    w_out = 1.0 - t     # 1 -> 0
    return w_out, w_in


def overlap_add_stitch(chunk_outputs: Sequence[np.ndarray],
                       chunk_ranges: Sequence[tuple],
                       total_frames: int,
                       overlap_frames: int) -> np.ndarray:
    """将各块的模型输出用等功率窗 Overlap-Add 拼回完整音轨。

    chunk_outputs[i] 对应 chunk_ranges[i] = (start, end)，长度 == end-start。
    重叠区用 equal_power_fade 交叉淡化, 非重叠区直接写入。
    返回长度 total_frames 的一维数组 (单声道; 多声道按通道分别调用)。
    """
    out = np.zeros(total_frames, dtype=np.float64)
    written_until = 0  # 已最终确定写入的位置 (不含)

    for i, (start, end) in enumerate(chunk_ranges):
        seg = np.asarray(chunk_outputs[i], dtype=np.float64)
        assert len(seg) == end - start, "块输出长度必须等于其区间长度"

        if i == 0:
            out[start:end] = seg
            written_until = end
            continue

        # 与上一块的重叠区 = [start, min(end, written_until))
        ov_start = start
        ov_end = min(end, written_until)
        ov_len = ov_end - ov_start
        if ov_len > 0:
            fade_out, fade_in = crossfade_weights(ov_len)
            prev = out[ov_start:ov_end]
            cur = seg[:ov_len]
            out[ov_start:ov_end] = prev * fade_out + cur * fade_in
            # 重叠区之后的部分直接写
            out[ov_end:end] = seg[ov_len:]
        else:
            out[start:end] = seg
        written_until = max(written_until, end)

    return out


# ---------------------------------------------------------------------------
# 难点二: 多轨采样级时钟对齐
# ---------------------------------------------------------------------------

def compute_sync_anchor(now_frame: int, buffer_sec: float, sample_rate: int) -> int:
    """计算 4 轨共同启动锚点 (帧号)。

    now_frame: 当前渲染时间对应的采样帧 (来自 lastRenderTime)。
    buffer_sec: 启动缓冲 (~0.1s), 保证所有轨都来得及调度。
    所有轨道使用同一返回值作为 AVAudioTime 锚点 -> 采样级对齐。
    """
    return now_frame + int(round(buffer_sec * sample_rate))


def segment_schedule(seek_frame: int, total_frames: int, anchor_frame: int,
                     num_tracks: int = 4) -> List[dict]:
    """为 num_tracks 条轨生成 scheduleSegment 参数, 全部共享 anchor_frame。

    返回每轨: { track, starting_frame, frame_count, at_frame }
    关键不变量: 所有轨的 at_frame 完全相同 (== anchor_frame),
                starting_frame 完全相同 (== seek_frame) -> 不会产生相位漂移。
    """
    seek_frame = max(0, min(seek_frame, total_frames))
    frame_count = total_frames - seek_frame
    return [
        {
            "track": t,
            "starting_frame": seek_frame,
            "frame_count": frame_count,
            "at_frame": anchor_frame,
        }
        for t in range(num_tracks)
    ]


# ---------------------------------------------------------------------------
# 难点三 / 导出: Solo/Mute 真值表 + 归一化防削波
# ---------------------------------------------------------------------------

def audible_mask(solos: Sequence[bool], mutes: Sequence[bool]) -> List[bool]:
    """根据 FRD §4 真值表计算各轨是否发声。

    规则:
      - Mute 永远优先 (被 mute -> 不发声)。
      - 有任意 solo 激活 (solo 模式): 仅 "被 solo 且未被 mute" 的轨发声。
      - 无 solo: 未被 mute 即发声。
    """
    assert len(solos) == len(mutes)
    solo_active = any(solos)
    result = []
    for s, m in zip(solos, mutes):
        if m:
            result.append(False)
        elif solo_active:
            result.append(bool(s))
        else:
            result.append(True)
    return result


def normalize_mix(mix: np.ndarray, ceiling_dbfs: float = -0.1) -> tuple:
    """导出前防削波: 若真峰值超过 ceiling, 整体线性衰减到 ceiling。

    返回 (processed, applied_gain)。不放大 (只在超限时衰减), 保持相对动态。
    """
    peak = float(np.max(np.abs(mix))) if mix.size else 0.0
    ceiling = 10.0 ** (ceiling_dbfs / 20.0)
    if peak <= ceiling or peak == 0.0:
        return mix.copy(), 1.0
    gain = ceiling / peak
    return mix * gain, gain


def mixdown(tracks: Sequence[np.ndarray], volumes: Sequence[float],
            solos: Sequence[bool], mutes: Sequence[bool]) -> np.ndarray:
    """按音量 + Solo/Mute 合成主混音 (导出/波形数据源等价逻辑)。"""
    mask = audible_mask(solos, mutes)
    n = max((len(t) for t in tracks), default=0)
    out = np.zeros(n, dtype=np.float64)
    for t, v, a in zip(tracks, volumes, mask):
        if not a:
            continue
        seg = np.asarray(t, dtype=np.float64)
        out[:len(seg)] += seg * v
    return out


# ---------------------------------------------------------------------------
# 进度 ETA
# ---------------------------------------------------------------------------

@dataclass
class EtaEstimator:
    """基于已完成块的滑动平均速度估算剩余时间 (秒)。

    首块完成后才给出估计 (避免冷启动乱跳)。
    """
    total_chunks: int
    window: int = 4
    _durations: List[float] = field(default_factory=list)

    def record_chunk(self, duration_sec: float) -> None:
        self._durations.append(duration_sec)

    @property
    def completed(self) -> int:
        return len(self._durations)

    def eta_seconds(self):
        if not self._durations:
            return None  # 尚无数据
        recent = self._durations[-self.window:]
        avg = sum(recent) / len(recent)
        remaining = self.total_chunks - self.completed
        return max(0.0, avg * remaining)

    def progress(self) -> float:
        if self.total_chunks <= 0:
            return 1.0
        return min(1.0, self.completed / self.total_chunks)


# ---------------------------------------------------------------------------
# EQ 预设 (Other 轨, 10 段; 与 docs/03 附录 A 一致)
# ---------------------------------------------------------------------------

EQ_FREQS_HZ = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

EQ_PRESETS = {
    "guitar_boost":  [0, 0, 1, 2, 3, 4, 3, 2, 1, 0],
    "piano_boost":   [0, 1, 2, 2, 1, 2, 3, 2, 1, 0],
    "mid_scoop":     [0, 0, 0, -2, -4, -5, -3, 0, 1, 2],
    "flat":          [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
}
