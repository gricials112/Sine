# Sine · 本地 4 音轨分离与实时混音 (iOS)

100% 本地离线、零服务器开销的 4 音轨 (人声 / 鼓 / 贝斯 / 其他) 分离与实时混音 App，主打"扒谱神器"，采用现代拟真 (Modern Skeuomorphic) 工业风界面。所有处理跑在设备本地 (Apple Neural Engine)，不上传任何文件。

## 文档 (按本项目执行的流程)
| 阶段 | 文档 |
|---|---|
| 一 设计方案 | [docs/01-设计方案.md](docs/01-设计方案.md) |
| 二 功能需求 FRD | [docs/02-功能需求文档-FRD.md](docs/02-功能需求文档-FRD.md) |
| 三 FRD 评审与优化 (P0/P1 → ≈96%) | [docs/03-FRD审查与优化.md](docs/03-FRD审查与优化.md) |
| 四 交互设计 | [docs/04-交互设计方案.md](docs/04-交互设计方案.md) |
| 五 交互设计评审 (反哺界面) | [docs/05-交互设计审查.md](docs/05-交互设计审查.md) |
| 六 功能测试报告 | [docs/06-功能测试报告.md](docs/06-功能测试报告.md) |

## 三大核心难点的工程对策
1. **抗 OOM (难点一)**：分块 (15~30s, 按内存降级) + `autoreleasepool` 逐块推理 + **线性/三角窗 Overlap-Add** 无缝拼接 → `Core/Separation`。
2. **多轨同步 (难点二)**：单例 `AVAudioEngine` + 统一 `AVAudioTime` 锚点采样级调度；Solo/Mute 走增益不 stop 节点 → `Core/Audio`。
3. **Other 轨杂音 (难点三)**：`AVAudioUnitEQ` 10 段预设补偿 (吉他/钢琴/中频削弱) → `Core/DSP`。

## 目录结构
```
Sine/                    # iOS App 源码 (单一模块)
  App/                   入口 / 全局状态 / 主题
  Features/              Import · Separation · Mixer · Export · Projects
  Core/                  Audio · Separation · DSP · Haptics · MetalFFT · Models
  Resources/             Info.plist · Assets.xcassets
Tests/SineCoreTests/     XCTest (纯逻辑, 对应 reference 用例)
reference/               Python 算法参考实现 + pytest (本仓库唯一可在 Linux 跑通的功能测试)
docs/                    全套设计/需求/交互/测试文档
project.yml              XcodeGen 工程描述
Package.swift            SwiftPM (SineCore 纯逻辑库 + 单元测试)
```

## 在 macOS 上编译运行

### 方式 A：XcodeGen (推荐)
```bash
brew install xcodegen
xcodegen generate          # 生成 Sine.xcodeproj
open Sine.xcodeproj        # 选择 Sine scheme + 真机/模拟器运行
```
> 首次运行需将分离模型 `HTDemucs.mlmodelc` 或 `Spleeter.mlmodelc` 放入 App bundle (见下"模型")。

### 方式 B：纯逻辑库与单元测试 (无需真机)
```bash
swift test                 # 运行 Tests/SineCoreTests (分块/Overlap-Add/时钟/Solo-Mute/归一/ETA/EQ)
```

## 功能测试 (本环境已跑通的部分)
三大核心难点的算法正确性在 `reference/` 用 Python 等价实现 + pytest 验证：
```bash
cd reference
pip install -r requirements.txt
python -m pytest -v        # 24 passed
```
Swift 侧 `Tests/SineCoreTests` 与之一一对应，在 macOS `swift test` 回归。
真机集成项 (CoreML/音频图/Metal/Haptics/内存) 清单见 docs/06。

## 模型 (CoreML)
- v1.0 捆绑轻量 `Spleeter-CoreML` (默认可用)，`HT-Demucs FP16` 作为高质量包按需下载。
- 用 `coremltools` 转换为 `.mlmodelc` (FP16/INT8)，输入 `mix [1,2,frames]`，输出 `vocals/drums/bass/other`。
- 权重不入库 (见 `.gitignore`)；`SeparationModelProvider` 协议已抽象，二选一不影响上层。

## 隐私
全程本地处理，无任何网络上传；权限矩阵见 `Sine/Resources/Info.plist`。
