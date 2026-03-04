# Speechflow Agent-Oriented PRD

## 1. 文档定位

本文件是面向 AI agent 和开发者协作的当前开发文档。

它不是最初的理想化规划，而是基于当前代码的真实状态，回答下面这些更实际的问题：

- 现在已经做到了什么
- 当前主链路到底是什么
- 哪些地方仍然是 stub、兼容层或过渡实现
- 当前推荐如何开发、运行和验证
- 接下来优先应该补什么

如果实现细节与本文件冲突，优先以当前代码行为为准，并同步更新文档。

## 2. 当前产品定义

### 2.1 一句话定义

Speechflow 是一个 macOS 菜单栏实时字幕工具，支持在麦克风模式和系统音频模式之间二选一采集输入，使用本地 ASR 输出实时原文，并在 committed segment 级别追加可选翻译字幕。

### 2.2 当前默认技术路线

当前默认链路已经不是旧的「远端优先 + 可选本地」设计，而是：

- ASR 主链路：`faster-whisper`
- ASR fallback：`SpeechFramework`
- 翻译默认：本地 `Ollama`
- 本地翻译默认模型：`qwen3.5:2b`
- 系统翻译 fallback：
  - App target + macOS 15：`NativeTranslationService`
  - 其他环境：`StubTranslateService`

### 2.3 当前核心价值

- 原文链路本地优先
- 翻译按 segment 串行保序
- 菜单栏与浮窗可直接用于长时间悬浮显示
- 输入源在麦克风和系统音频之间可切换
- 本地翻译与本地识别都支持失败降级，不要求单一路径永不出错

## 3. 当前实现基线

### 3.1 已接通的真实链路

当前代码里已经接通的真实组件：

- 菜单栏 App：`SpeechflowApp`
- 浮窗：`OverlayWindowController` + `RealOverlayRenderer`
- 麦克风采集：`SystemAudioEngineService`
- 系统音频采集：`ScreenCaptureSystemAudioService`
- 输入源切换：`SelectableAudioCaptureService`
- 本地 ASR 主链路：`WhisperTurboASRService`
- 本地 ASR fallback：`SpeechFrameworkASRService`
- 翻译路由：`TranslationRouterService`
- 本地翻译：`LocalOllamaTranslationService` + `LocalOllamaRuntime`
- App 上的系统翻译 fallback：`NativeTranslationService`
- committed/partial 管理：`TranscriptBuffer`
- 顶层状态机：`AppCoordinator`

### 3.2 仍然是过渡实现的部分

当前仍然是占位或过渡态的部分：

- `InMemorySettingsStore` 仍未持久化到磁盘
- `StubNetworkMonitor` 仍未接真实网络监控
- core 层默认 live container 仍使用 `StubOverlayRenderer`
- `TranslationPolicy` 的命名还保留旧的 remote-first 语义
- 分段策略能工作，但仍在持续调参

### 3.3 已废弃的路线

以下路线不再是当前实现方向：

- `MLX` 本地翻译运行时
- `whisper.cpp` 作为默认 ASR 推理引擎
- “默认远端优先翻译”作为主链路描述

后续文档和实现都不应再把这三项写成当前主方案。

## 4. MVP 范围（按当前代码修正）

### 4.1 当前已覆盖的功能

- 菜单栏 app
- `启动翻译麦克风 / 启动翻译系统音频 / Pause / Stop`
- 源语言选择
- 目标语言选择
- 翻译开关
- 浮窗开关
- 原文和译文双浮窗
- 麦克风实时语音识别
- 系统音频实时监听
- partial 和 final 文本处理
- committed segment 增量翻译
- 本地 Ollama 翻译
- 系统翻译 fallback 路由
- 基础分句、静音提交和稳定提交
- 设置页的主要交互闭环

### 4.2 当前明确还没完成的事情

- 真正的设置持久化
- 真实网络质量监控
- 更稳定的短句滚动分段
- 更彻底的“重复前缀不再重复送翻译”控制
- 系统音频的精细内容选择（当前实现是基于 shareable display 的通路，不是完整的用户选择器）
- 完整的日志与崩溃回收体系

### 4.3 当前成功标准

当前版本最重要的成功标准是：

- 原文链路在翻译失败时仍能持续工作
- 切换输入源时不会把两条采集链同时跑起来
- 字幕能持续滚动，而不是整段反复重写历史
- 本地 Ollama 不可用时，翻译能降级而不是拖垮会话
- 长时间悬浮显示不因为频繁重绘而明显卡顿

## 5. 核心产品约束

### 5.1 字幕显示约束

- 原文区显示 `committed + current partial`
- 译文区只显示 committed segment 的翻译结果
- partial 默认不进入正式译文区
- 原文和译文必须按 segment `id` 对齐，而不是靠文本匹配

### 5.2 ASR 约束

- ASR 必须本地优先
- ASR 不依赖网络
- 翻译链路故障不得中断原文字幕
- 主链路失败时允许自动降级到本地系统识别 fallback

### 5.3 翻译约束

- 翻译单位是 committed segment
- 不允许每次 partial 改动都整段重翻
- 翻译必须串行保序
- 翻译失败不能阻塞原文识别
- 当前默认应优先尝试本地 `Ollama`
- 本地模型缺失或服务不可用时，应自动回退到系统翻译 provider

### 5.4 生命周期约束

- 任意时刻只允许一个活跃输入源会话
- `Pause` 必须停止推进新的识别和翻译
- `Stop` 必须释放捕获、识别、翻译和 transcript 状态

### 5.5 调试约束

- 涉及权限的首次验证应优先通过打包后的 `.app`
- 不要把裸 `swift run` 当成权限流程的标准验证方式
- 识别和翻译调优应优先通过可重复的 bench 或明确日志完成

## 6. 当前主链路

### 6.1 输入源与采集

当前音频入口是 `SelectableAudioCaptureService`：

- 麦克风模式走 `SystemAudioEngineService`
- 系统音频模式走 `ScreenCaptureSystemAudioService`

同一时刻只会激活其中一个。

### 6.2 识别链路

当前 ASR 链路：

1. 采集服务输出 `AVAudioPCMBuffer`
2. `WhisperTurboASRService` 把音频整理为 16 kHz 单声道
3. 通过打包到 `SpeechflowCore` 的 `faster_whisper_runner.py` 调本地 Python 常驻进程
4. `faster-whisper` 返回文本与 segment 边界
5. 服务把最前面的稳定段尽快提交，把尾巴继续作为 partial 滚动
6. 若主链路失败，`PreferredLocalASRService` 自动切到 `SpeechFrameworkASRService`

### 6.3 commit 链路

`AppCoordinator` 当前通过三种信号触发 commit：

1. `asrFinalReceived`
2. `partialStableTimeoutTriggered`
3. `silenceTimeoutTriggered`

其中 stable/silence 延迟会根据文本状态动态调整：

- 有句末标点更快
- 有子句边界也会较快
- 语义块看起来完整时会提前提交
- 太短的碎片会适当多等一点

### 6.4 翻译链路

当前翻译链路：

1. `TranscriptBuffer` commit 产生 `TranscriptSegment`
2. `AppCoordinator` 仅在 committed 后调用 `translateService.enqueue(segment)`
3. `TranslationRouterService` 按 `translationBackendPreference` 选择路由
4. 默认走 `LocalOllamaTranslationService`
5. 本地 provider 失败时再按 router 逻辑回退到系统 provider
6. 翻译结果通过 `segment.id` 写回，不会靠文本猜测覆盖

## 7. 当前模块边界

### 7.1 `AppCoordinator`

职责：

- 唯一状态机入口
- 处理事件
- 管理启动 / 暂停 / 恢复 / 停止
- 管理 commit 时机
- 决定 committed segment 何时进入翻译

### 7.2 `TranscriptBuffer`

职责：

- 保存 `partialText`
- commit 为 `TranscriptSegment`
- 抑制重复提交
- 合并近期滚动 refinement
- 挂载译文或失败状态

### 7.3 `WhisperTurboASRService`

职责：

- 驱动 `faster-whisper`
- 做音频重采样
- 输出 partial / final
- 做字幕导向的细粒度分段

### 7.4 `PreferredLocalASRService`

职责：

- 管理主识别器与 fallback 识别器
- 主链路运行中失败时切换 fallback

### 7.5 `TranslationRouterService`

职责：

- 统一持有本地翻译和系统翻译 provider
- 记录 pending segment
- 保持 provider fallback 逻辑集中
- 为最终结果补齐 metadata

### 7.6 `LocalOllamaTranslationService`

职责：

- 检查本地模型是否安装
- 构造口语化字幕翻译 prompt
- 串行发送翻译请求
- 输出 `TranslationResult`

### 7.7 `LocalOllamaRuntime`

职责：

- 调用本地 Ollama `POST /api/generate`
- 管理超时、最大 token、`think` 开关等 runtime 参数

### 7.8 `RealOverlayRenderer`

职责：

- 在 `@MainActor` 上更新浮窗可见内容
- 把 snapshot 投影到 UI，而不是维护业务真状态

## 8. 当前里程碑状态

### 8.1 Milestone A: 采集与识别

状态：大体完成，仍在调优。

已完成：

- 麦克风采集
- 系统音频采集通路
- `faster-whisper` 主链路
- `SpeechFramework` fallback
- partial / final 事件流

未完成：

- 分段策略还不够稳定
- 闪退、卡死等边缘问题仍需继续压测

### 8.2 Milestone B: 浮窗 UI

状态：已完成基础闭环。

已完成：

- 双浮窗渲染
- 菜单栏启动
- 设置页主要交互
- 可见性控制

未完成：

- 更系统的渲染性能观测
- 更细的 UI diff 稳定性优化

### 8.3 Milestone C: 增量翻译

状态：已完成主闭环，但仍需稳定性优化。

已完成：

- committed 后串行翻译
- 本地 Ollama 默认翻译
- 系统 provider fallback
- 翻译结果按 `segment.id` 回填

未完成：

- 更严格的 pending 队列去重
- 彻底避免同一长段前缀被重复送翻译

### 8.4 Milestone D: 分句与可读性

状态：进行中。

已完成：

- 静音提交
- 稳定提交
- 基于标点和词边界的启发式切分
- 利用 `faster-whisper` 自带 segment 边界进行更早切分

未完成：

- 复杂连续口播的细粒度断句仍不稳定
- 某些长句仍会以滚动扩写方式多次进入翻译

### 8.5 Milestone E: 稳定性与产品化

状态：进行中。

已完成：

- 基本的失败降级
- 基础 debug 日志
- App bundle 开发打包脚本

未完成：

- 系统化 crash 报告回收
- 长时间 soak test 基线
- 配置持久化

### 8.6 Milestone F: 系统音频输入模式

状态：部分完成。

已完成：

- 系统音频入口
- 通过 `ScreenCaptureKit` 进入统一 ASR 管线

未完成：

- 更细粒度的显示器 / 应用 / 窗口选择
- 更完整的用户可见授权引导

### 8.7 Milestone G: 本地翻译后端

状态：已从规划转为当前主链路。

当前结论：

- 旧的 `MLX` 规划已不再适用
- 当前本地翻译主方案是 `Ollama`
- 默认模型是 `qwen3.5:2b`
- 开发文档不应再把 `MLX` 写成当前目标

## 9. 开发运行指引

### 9.1 本地构建

基础构建：

```bash
swift build
```

### 9.2 打包开发版 App

第一次做权限验证或真实 UI 验证时，优先用：

```bash
/Users/asukabot/Speechflow/Scripts/build_dev_app_bundle.sh
```

产物位置：

- `dist/Speechflow.app`

### 9.3 本地翻译跑分

用于验证当前 Ollama 模型速度：

```bash
/Users/asukabot/Speechflow/Scripts/run_local_translation_bench.sh
```

对应目标：

- [main.swift](/Users/asukabot/Speechflow/Sources/LocalTranslationBench/main.swift)

### 9.4 调试原则

- 先确认 ASR 是否有稳定 partial/final
- 再确认 commit 是否触发
- 最后确认翻译是否入队与回填

不要在“原文都没稳定出来”时直接先调翻译 prompt。

## 10. 关键环境变量

### 10.1 ASR 相关

常用变量：

- `SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH`
- `SPEECHFLOW_FASTER_WHISPER_MODEL`
- `SPEECHFLOW_FASTER_WHISPER_MODEL_PATH`
- `SPEECHFLOW_FASTER_WHISPER_DOWNLOAD_ROOT`
- `SPEECHFLOW_FASTER_WHISPER_DEVICE`
- `SPEECHFLOW_FASTER_WHISPER_COMPUTE_TYPE`
- `SPEECHFLOW_WHISPER_POLL_SECONDS`
- `SPEECHFLOW_WHISPER_MIN_START_SECONDS`
- `SPEECHFLOW_WHISPER_MIN_INCREMENT_SECONDS`
- `SPEECHFLOW_WHISPER_MAX_WINDOW_SECONDS`
- `SPEECHFLOW_FASTER_WHISPER_BEAM_SIZE`
- `SPEECHFLOW_FASTER_WHISPER_BEST_OF`
- `SPEECHFLOW_FASTER_WHISPER_VAD_MIN_SPEECH_MS`
- `SPEECHFLOW_FASTER_WHISPER_VAD_MIN_SILENCE_MS`
- `SPEECHFLOW_FASTER_WHISPER_VAD_SPEECH_PAD_MS`

### 10.2 翻译相关

常用变量：

- `SPEECHFLOW_OLLAMA_MODEL`
- `SPEECHFLOW_LOCAL_MODEL_ID`
- `SPEECHFLOW_LOCAL_MODEL_NAME`
- `SPEECHFLOW_OLLAMA_BASE_URL`
- `SPEECHFLOW_OLLAMA_TIMEOUT_SECONDS`
- `SPEECHFLOW_OLLAMA_KEEP_ALIVE`
- `SPEECHFLOW_OLLAMA_MAX_TOKENS`
- `SPEECHFLOW_OLLAMA_THINK`

### 10.3 跑分相关

`LocalTranslationBench` 支持：

- `SPEECHFLOW_BENCH_SOURCE`
- `SPEECHFLOW_BENCH_TARGET`
- `SPEECHFLOW_BENCH_SOURCE_WARM`
- `SPEECHFLOW_BENCH_TARGET_WARM`
- `SPEECHFLOW_BENCH_TEXT`
- `SPEECHFLOW_BENCH_TEXT_WARM`

## 11. 当前主要风险

### 11.1 连续口播断句仍偏粗

风险：

- 长句会以滚动扩写形式重复进入翻译

当前方向：

- 优先利用模型原生 segment
- 再叠加更稳的前缀去重
- 后续必要时引入基于词时间轴的切分

### 11.2 识别与 UI 回调链仍可能出现边缘崩溃

风险：

- 高频事件回调叠加 UI 更新时，容易出现线程和重入问题

当前方向：

- 保守控制单次识别回调内触发的 final 数量
- 保持主线程 UI 更新集中在 renderer

### 11.3 文档名与旧类型名仍有历史包袱

风险：

- 新 agent 容易被 `remotePreferred`、旧里程碑名等误导

当前方向：

- 优先遵循当前实现和本文档
- 后续逐步收敛命名，而不是一次性大改模型

## 12. 下一步优先级

建议后续开发优先按这个顺序推进：

1. 先稳定 ASR 分段，确保长句不会重复触发整段翻译。
2. 再给翻译队列补真正的 pending 去重和旧任务淘汰。
3. 把 `InMemorySettingsStore` 换成持久化存储。
4. 把 `StubNetworkMonitor` 换成真实网络状态源。
5. 最后再做更激进的字幕体验优化，例如更细粒度的滚动策略或更强的译文缓存。
