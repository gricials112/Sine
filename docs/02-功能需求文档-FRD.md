# Sine — 功能需求文档 (FRD)

> 版本 v1.0 · 阶段二 · 配合《01-设计方案》。本文将功能拆到 **用例 (UC) / 功能点 (F) / 验收标准 (AC)** 粒度。

---

## 0. 术语
- **Stem**：分离出的单条音轨 (Vocal/Drums/Bass/Other)。
- **Project**：一次导入产生的工程，含源音频元数据 + 4 个 stem + 混音参数。
- **Chunk**：分离时切分的音频块。
- **混音参数 (MixState)**：每轨的 volume / solo / mute / 全局 pitch / 全局 speed / Other-EQ。

---

## 1. 功能模块清单
| 模块 | 编号 | 功能 |
|---|---|---|
| 导入 | F1 | 多来源导入 (相册/文件/微信分享)、取流解码 |
| 分离 | F2 | 4 轨离线分离、进度、可取消、内存降级 |
| 调音台 | F3 | 4 路推子、Solo/Mute、实时混音 |
| 变调变速 | F4 | Pitch -12~+12、Speed 0.5x~2.0x、保真 |
| Other-EQ | F5 | 10 段参量 EQ + 预设 |
| 波形 | F6 | Metal FFT 实时波形 |
| 触感 | F7 | CoreHaptics 阻尼/段落反馈 |
| 导出 | F8 | 自定义勾选轨 + 参数烘焙导出 |
| 工程管理 | F9 | 工程列表、删除、重命名、缓存清理 |

---

## 2. 用例规格

### UC-01 导入本地媒体并提取音频
- **Actor**：用户
- **前置**：App 已获相册/文件读取权限 (首次弹权限)。
- **主流程**：
  1. 用户在首页点 "导入" → 选择来源 (相册 / 文件 / 最近的微信分享)。
  2. 选中一个视频或音频文件。
  3. App 用 `AVAssetReader` 解码并重采样为 44.1kHz/Float32/立体声，写入临时 WAV。
  4. 生成 Project，进入"待分离"状态，展示文件名、时长、封面缩略图。
- **分支/异常**：
  - A1 文件无音频轨 → 提示"未检测到音频"，回到导入。
  - A2 时长 > 10 分钟 → 提示可裁剪或继续 (继续则警告耗时/内存)。
  - A3 受 DRM 保护 (如 Apple Music) → 提示不支持，引导选其他文件。
  - A4 解码失败/格式不支持 → 错误提示 + 重试。
- **AC**：
  - AC1 常见格式 (mp4/mov/m4a/mp3/wav/aac) 均能解码成功。
  - AC2 解码后内存峰值不因"整文件驻留"而失控 (落盘临时文件)。

### UC-02 离线分离为 4 轨
- **前置**：存在"待分离" Project。
- **主流程**：
  1. 用户点 "开始分离"。
  2. 引擎按设备内存选模型与 chunk 大小 (降级链)。
  3. 逐块推理，实时上报进度 (含预计剩余时间)。
  4. Overlap-Add 拼接，输出 4 个 stem 文件，Project → "已分离"。
  5. 自动跳转调音台。
- **分支/异常**：
  - A1 用户中途取消 → 释放资源、删除半成品、回"待分离"。
  - A2 内存告警 (`didReceiveMemoryWarning`) → 主动降 chunk / 暂停并提示。
  - A3 ANE 不可用 → 回落 CPU/GPU，提示更慢但继续。
  - A4 推理异常/模型加载失败 → 错误 + 重试 + 降级到 Spleeter。
- **AC**：
  - AC1 5 分钟歌曲在 6GB 设备上不被 Jetsam 杀掉 (内存峰值 < 安全阈值)。
  - AC2 块边界无可闻爆音/咔哒声 (Overlap-Add 验证)。
  - AC3 进度单调不回退；取消后 1s 内停止并清理。

### UC-03 调音台实时混音 (4 推子 + Solo/Mute)
- **主流程**：
  1. 进入调音台，4 轨默认全开、音量 0dB。
  2. 拖动某轨推子 → 实时改变该轨音量 (带阻尼触感)。
  3. 点 Solo → 仅该轨发声 (其余隐式静音，可多轨 Solo)。
  4. 点 Mute → 该轨静音；与 Solo 互斥逻辑见下。
  5. 播放/暂停/seek，4 轨始终同步。
- **Solo/Mute 逻辑** (评审重点)：
  - 任一轨 Solo 激活 → 进入 Solo 模式：仅被 Solo 的轨发声。
  - 多轨可同时 Solo。无 Solo 时按各轨 Mute 决定。
  - Mute 与 Solo 可独立存在；最终发声 = `soloActive ? (isSoloed && !? ) : !isMuted`。精确真值表见 §4。
- **AC**：
  - AC1 拖推子到改变发声延迟 < 50ms (感知实时)。
  - AC2 4 轨播放任意时刻采样级同步 (无相位重影)。

### UC-04 实时变调变速
- **主流程**：
  1. 用户调 Pitch 旋钮 (-12~+12 半音，步进 1，可微调 cents 选配)。
  2. 用户调 Speed (0.5x~2.0x)。
  3. 4 轨整体同时变换，保持同步与保真。
- **分支**：
  - A1 极端组合 (0.5x + -12) 音质下降 → 仍可用，UI 不报错。
  - A2 调整时正在播放 → 平滑过渡，不爆音、不失步 (统一时钟重排)。
- **AC**：
  - AC1 变速后 4 轨仍同步 (难点二)。
  - AC2 Pitch/Speed 改变在 100ms 内生效。

### UC-05 Other 轨 EQ 补偿
- **主流程**：进入 Other 轨详情 → 选预设 (吉他/钢琴/中频削弱) 或手动拖 10 段 → 实时听感变化。
- **AC**：EQ 改变实时生效；预设可一键复位。

### UC-06 自定义导出
- **主流程**：
  1. 点 "导出" → 勾选要输出的轨 (1~4 任意组合)。
  2. 选择"是否套用当前混音参数 (音量/Speed/Key/EQ)"。
  3. 选格式 (m4a/wav) 与目标 (相册/文件/分享)。
  4. 离线渲染 → 进度 → 完成提示。
- **分支**：
  - A1 一个都没勾 → 导出按钮禁用。
  - A2 渲染中取消 → 删除半成品文件。
  - A3 磁盘空间不足 → 预检报错。
- **AC**：
  - AC1 导出文件听感与调音台一致 (所见即所得)。
  - AC2 多轨混音导出无削波 (做 limiter/归一保护)。

### UC-07 工程管理
- 列表查看/打开/重命名/删除工程；清理临时与 stem 缓存；显示占用空间。
- **AC**：删除工程释放全部关联文件；清缓存不损坏"已分离"工程的 stem。

---

## 3. 非功能需求 (NFR)
| 编号 | 需求 | 指标 |
|---|---|---|
| NFR-1 性能 | 分离速度 | 6GB 设备 ANE 上 ≤ 实时的 ~1.5x (3min 歌 ≤ ~4.5min)；目标值，待真机标定 |
| NFR-2 内存 | 分离峰值 | < 设备可用内存安全线 (4GB 机型 < 1.2GB 驻留) |
| NFR-3 波形 | 帧率 | 支持设备上 120Hz，无音频卡顿 |
| NFR-4 隐私 | 数据 | 全程本地，无任何网络上传 |
| NFR-5 稳定 | 崩溃 | 分离/播放/导出全流程无 OOM 崩溃 |
| NFR-6 兼容 | 系统 | iOS 16.0+；ANE 缺失可降级 |
| NFR-7 包体 | 体积 | 评审决议 (捆绑 vs 按需下载) |

---

## 4. Solo/Mute 真值表 (消歧)
设 `S` = 是否有任意轨 Solo 激活；轨 i 状态 `solo_i`, `mute_i`。
轨 i 是否发声 `audible_i`：

| 是否有 Solo (S) | solo_i | mute_i | audible_i |
|---|---|---|---|
| 否 | - | true | 否 |
| 否 | - | false | 是 |
| 是 | true | false | 是 |
| 是 | true | true | 否 (Mute 优先) |
| 是 | false | - | 否 |

> 规则：**Solo 模式下只有被 Solo 且未被 Mute 的轨发声；非 Solo 模式下未被 Mute 即发声。Mute 永远优先于 Solo。**

---

## 5. 数据模型 (Domain)
```
Project { id, title, sourceURL, duration, sampleRate, createdAt, state, stems: [Stem] }
Stem    { kind: .vocal/.drums/.bass/.other, fileURL, peakLevel }
MixState{ tracks: [TrackState], pitchSemitones, speed, otherEQ: EQSettings }
TrackState { kind, volume(0~1), solo, mute }
EQSettings { bands: [EQBand(freq,gain,q,type)], presetName }
```

## 6. 状态机 (Project)
`imported → separating → separated → (editing) → exported`；任意阶段可 `failed`/`cancelled` → 回退。
