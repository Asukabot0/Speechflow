# Speechflow Agent-Oriented PRD

## 1. 文档定位

本文件是面向 AI agent 和开发者协作的 MVP PRD。

目标不是写产品宣传文案，而是提供一个可直接执行的单一事实来源，明确以下内容：

- 做什么
- 不做什么
- 按什么顺序做
- 各模块负责什么
- 关键状态和数据如何流转
- 什么算完成

如果后续实现细节与本文件冲突，优先遵守以下顺序：

1. 核心产品约束
2. 状态机与数据不变量
3. 里程碑和验收标准
4. 实现偏好

## 2. 产品定义

### 2.1 一句话定义

Speechflow 是一个 macOS 菜单栏实时字幕工具，支持按输入源模式监听麦克风或系统输出音频，使用本地 ASR 作为低延迟主链路，实时显示原文字幕，并在分段提交后通过可选翻译链路追加显示译文字幕。

### 2.2 目标用户

- 在会议、演示、课堂、线上通话中需要实时看字幕的用户
- 需要低打扰字幕浮窗的用户
- 需要实时理解另一种语言内容，但不要求专业同传级准确率的用户

### 2.3 MVP 核心价值

- 快速启动
- 低延迟
- ASR 不依赖网络
- 字幕稳定
- 可读
- 长时间运行不崩

## 3. MVP 范围

### 3.1 必做功能

- 菜单栏 app
- `启动翻译麦克风 / 启动翻译系统音频 / Pause / Stop`
- 源语言选择
- 目标语言选择
- 翻译开关
- 浮窗开关
- 全局浮窗显示原文和译文
- 麦克风实时语音识别（本地 ASR）
- 系统输出音频实时监听与翻译（用户显式选择的内容源）
- 菜单栏双启动入口：`启动翻译麦克风` / `启动翻译系统音频`
- partial 和 final 文本处理
- committed segment 增量翻译
- 远端优先翻译 + 系统翻译 / 原文显示降级
- 基础分句与标点后处理
- 设置持久化

### 3.2 明确不做

- 说话人分离
- 多人会议 diarization
- 同时并行监听麦克风和系统音频
- 绕过系统授权的后台静默系统音频捕获
- 录屏
- 翻译链路完全离线
- partial 预测翻译正式上线
- 摘要、纪要、语义分析
- 术语词典和术语记忆

### 3.3 MVP 成功标准

- 首次启动后，用户能在几分钟内完成授权并开始使用
- `30` 分钟连续使用无崩溃
- `1` 小时长会场景无明显内存失控
- 原文实时更新主观延迟在 `500ms` 到 `1.5s`
- committed 到译文显示主观延迟在 `1s` 到 `3s`
- 译文不会因 partial 抖动反复重写整段
- 断网或弱网时，原文链路持续可用
- 浮窗在 Space、全屏、多显示器下行为可预测

## 4. 核心产品约束

这些约束是后续所有 agent 开发时必须遵守的硬规则。

### 4.1 文本显示约束

- 原文区显示 `committed + current partial`
- 译文区只显示 committed segment 的翻译结果
- partial 默认不进入正式译文区
- UI 必须优先增量 append，不允许每次更新都重绘整块历史内容

### 4.2 ASR 约束

- ASR 必须是本地主链路
- ASR 不得依赖翻译网络状态
- 翻译链路故障不得中断原文字幕
- 原文链路优先级始终高于译文链路

### 4.3 翻译约束

- 翻译单位是 segment，不是整个 transcript
- 不允许每次 partial 改动都触发全量重翻
- 翻译请求必须串行保序
- 翻译失败不能阻塞原文识别和显示
- 默认策略是远端优先
- 网络好时可走远端翻译 / 润色
- 网络差时应优先降级到系统翻译
- 若系统翻译不可用，允许只显示原文

### 4.4 生命周期约束

- 任一启动入口都必须建立完整会话
- `Pause` 必须停止活跃处理但保留会话上下文
- `Stop` 必须释放会话资源
- 任意时刻只能存在一个活跃输入源会话（麦克风或系统音频二选一）

### 4.5 性能约束

- partial UI 更新应节流到 `120ms` 到 `250ms`
- UI 总刷新频率上限应控制在 `10` 到 `15 FPS`
- 历史字幕内存缓存应限制在最近 `80` 到 `200` 行

## 5. 用户流程

1. 用户打开菜单栏 app
2. 用户选择源语言和目标语言
3. 用户点击 `启动翻译麦克风` 或 `启动翻译系统音频`
4. 若是麦克风模式，系统检查麦克风和语音识别权限
5. 若是系统音频模式，系统检查语音识别权限，并要求用户完成内容选择与系统录制授权
6. 应用开始采集所选输入源音频并流式识别
7. partial 文本实时显示在原文区
8. segment 满足提交条件后进入 committed
9. 网络状态决定 committed segment 的翻译路由
10. committed segment 被送入远端优先的翻译队列
11. 译文按 segment 顺序追加到译文区，若降级为原文模式则只显示原文
12. 用户可随时 `Pause`、恢复、隐藏浮窗或 `Stop`

## 6. 核心状态机

系统状态必须统一由一个顶层状态机驱动。

### 6.1 状态定义

- `Idle`
- `Listening`
- `Paused`
- `Error`

### 6.2 状态语义

- `Idle`
  无活跃识别会话，可修改设置，可开始新会话

- `Listening`
  正在采集音频、接收本地 ASR 事件、处理 segment、按网络状态路由翻译、刷新 UI

- `Paused`
  不再推进新的识别和翻译处理，但保留当前上下文和已显示内容

- `Error`
  当前流程发生不可自动恢复的问题，需要提示并允许重试

### 6.3 关键状态转换

- `Idle -> Listening`
  条件：权限满足，音频引擎启动成功，识别服务启动成功

- `Listening -> Paused`
  条件：用户主动暂停

- `Paused -> Listening`
  条件：用户恢复，依赖服务恢复成功

- `Listening -> Idle`
  条件：用户停止，资源完整释放

- `Listening -> Error`
  条件：关键服务启动失败、运行中断且无法自动恢复

- `Error -> Idle`
  条件：用户确认并清理失败会话

## 7. 数据模型与不变量

这些模型不要求一次性严格编码为同名类型，但实现逻辑必须符合这些语义。

### 7.1 TranscriptSegment

建议字段：

- `id`
- `sourceText`
- `normalizedSourceText`
- `translatedText`
- `status`
- `createdAt`
- `committedAt`
- `translatedAt`
- `sourceLanguage`
- `targetLanguage`

### 7.2 SegmentStatus

- `draft`
- `committed`
- `translating`
- `translated`
- `skipped`
- `failed`

### 7.3 SessionModel

建议字段：

- `sessionId`
- `appState`
- `inputSource`
- `partialText`
- `committedSegments`
- `translationEnabled`
- `overlayVisible`
- `sourceLanguage`
- `targetLanguage`

### 7.4 数据不变量

- `partialText` 只能代表当前未提交文本
- `committedSegments` 一旦写入，不允许被整体重排
- 已 translated 的 segment 不允许因后续 partial 更新被整段覆盖
- 任意一个 segment 的翻译结果必须和其 `id` 绑定
- UI 显示顺序必须与 committed 顺序一致

## 8. 关键事件与处理规则

实现时建议围绕事件驱动，而不是让 UI 直接操纵底层服务。

### 8.1 输入事件

- `StartMicrophoneRequested`
- `StartSystemAudioRequested`
- `PauseRequested`
- `ResumeRequested`
- `StopRequested`
- `PermissionsResolved`
- `NetworkQualityChanged`
- `ASRPartialReceived`
- `ASRFinalReceived`
- `SilenceTimeoutTriggered`
- `PartialStableTimeoutTriggered`
- `TranslationFinished`
- `TranslationFailed`
- `OverlayToggled`
- `TranslationToggled`

### 8.2 commit 触发规则

优先级从高到低：

1. 收到 `ASRFinalReceived`
2. 静音持续超过 `400ms` 到 `700ms`
3. partial 文本在约 `800ms` 内无变化

### 8.3 commit 后动作

一旦 segment commit，系统必须按顺序执行：

1. 把当前 draft 文本转换为 committed segment
2. 清空或重置 `partialText`
3. 将 segment 追加到 `committedSegments`
4. 若翻译开启，则将 segment 按当前翻译策略入队
5. 原文区按 append 逻辑刷新
6. 翻译完成后，译文区按相同 segment `id` 追加
7. 若降级为 `original only`，则保留原文链路，跳过该段译文显示

## 9. UI 需求

### 9.1 菜单栏

必须提供：

- `启动翻译麦克风`
- `启动翻译系统音频`
- `Pause`
- `Stop`
- 源语言选择
- 目标语言选择
- 翻译开关
- 浮窗开关
- 设置入口

### 9.2 浮窗

必须满足：

- 使用 `NSPanel` 或等效可置顶方案
- 可拖动
- 可调整大小
- 不抢焦点
- 透明背景
- 圆角
- 支持跨 Space
- 支持全屏辅助显示

推荐行为：

- `collectionBehavior` 包含 `.canJoinAllSpaces`
- `collectionBehavior` 包含 `.fullScreenAuxiliary`

### 9.3 浮窗内容布局

- 上方为原文区
- 下方为译文区
- 原文区可显示 `committed + partial`
- 译文区仅显示 committed 对应内容
- 支持最大行数限制

### 9.4 设置项 (Settings Window)

MVP 必须至少支持以下设定并在 `SettingsView` 配置面板中闭环：

- 权限申请状态检测 (Microphone & Speech Recognition)
- 字体大小与动态预览
- 透明度控制
- 最大行数限制
- 翻译开关默认值
- 浮窗显示默认值
- 源语言与目标语言 (在 MenuBarApp 同样包含)

**当前实现状态 (App Target)**：
- 已实现包含 General 和 Permissions 双 Tab 的独立偏好设置窗口 (`SettingsWindowManager`单例控制)。
- 权限页已连入 `AVFoundation` 麦克风动态申请。
- General 配置修改会通过 `ObservableObject` 实时同步回 Core 层和 SwiftUI 界面。

## 10. 模块划分

模块边界要尽量稳定，便于多个 agent 并行开发。

### 10.1 `AudioEngineService`

职责：

- 麦克风采集
- 音频引擎启动与停止
- 音频格式适配
- 可选静音检测基础输入

不负责：

- UI
- 翻译
- 字幕渲染

### 10.2 `LocalASRService`

职责：

- 对接本地语音识别框架
- 输出 partial 和 final 事件
- 维护识别会话生命周期

不负责：

- segment commit 逻辑
- 翻译逻辑

### 10.3 `NetworkMonitor`

职责：

- 感知当前网络质量
- 把网络状态变化转成事件
- 为翻译链路提供路由信号

不负责：

- 识别
- UI 渲染

### 10.4 `TranscriptBuffer`

职责：

- 保存 `partialText`
- 管理 `committedSegments`
- 执行 commit 规则
- 限制回滚只发生在当前未提交区域

不负责：

- 直接调用 UI
- 直接决定翻译 provider

### 10.5 `TranslateService`

职责：

- 接收 committed segment
- 根据策略选择远端 / 系统 / 原文降级路径
- 串行翻译
- 保证顺序
- 做缓存
- 做超时、重试和失败回调

不负责：

- 直接修改 transcript 历史顺序

### 10.6 `CaptionOverlayWindow`

职责：

- 渲染原文和译文
- 管理浮窗位置、大小、显示状态
- 执行节流后的 UI 更新

不负责：

- 自己维护业务真状态

### 10.7 `SettingsStore`

职责：

- 读取和持久化用户配置
- 提供默认值

### 10.8 `Coordinator`

职责：

- 持有系统主状态机
- 编排服务协作
- 处理错误恢复
- 作为唯一的业务流转入口

## 11. 推荐实现策略

### 11.1 默认增量翻译策略

这是 MVP 的默认方案，后续 agent 不应擅自改成更复杂逻辑。

- 原文区显示 `committed + partial`
- 译文区只显示 committed translations
- partial 不进入正式译文
- commit 后按 segment 翻译
- 网络好时优先远端翻译，允许远端润色
- 网络差时优先降级到系统翻译
- 系统翻译不可用时允许只显示原文
- 译文只 append，不全量重绘

### 11.2 为什么必须这样做

- 能显著减少视觉抖动
- 能避免翻译顺序错乱
- 能降低调用成本
- 能保证 ASR 永远是稳定主链路
- 能保持架构简单且可扩展

### 11.3 允许的未来扩展

- partial 预测翻译
- 浅色未定稿翻译块
- commit 后仅替换对应块

这些扩展不属于当前 MVP，除非用户明确要求，否则不要实现。

## 12. 里程碑与交付要求

### 12.1 Milestone A: 项目骨架、权限、音频管线 (UI Shell 已实现 ✅)

目标：

- 菜单栏 app 跑起来
- 权限流程跑通
- 音频采集跑通
- 本地语音识别 partial/final 能持续输出

完成定义：

- 通过任一启动入口后都能持续输出识别文本
- `Pause` 和 `Resume` 正常
- `Stop` 后资源释放
- 连续运行 `30` 分钟不崩溃

**当前实现状态 (App Target & Core Target)**：
- 已实现 `SpeechflowApp` 入口及 `MenuBarView` 基础交互。
- 已实现 `SystemAudioEngineService` (基于 `AVAudioEngine` 采集音频) 和 `SpeechFrameworkASRService` (基于 `SFSpeechRecognizer` 提供本地识别)。
- 已实现 `SettingsWindowManager` 与 `SettingsView`，支持主动唤起系统麦克风和语音识别权限的授权。权限层有基于 `AVCaptureDevice` 的 `SystemPermissionService` 支持。
- Core 逻辑层已通过 `AppCoordinator` 建立事件驱动的状态机骨架并对接 SwiftUI 状态。

### 12.2 Milestone B: 浮窗 UI (已实现 ✅)

目标：

- 浮窗可显示原文
- 浮窗跨 Space、全屏、多显示器基础可用

完成定义：

- 浮窗置顶、无焦点、可拖动、可缩放
- 原文实时更新
- 设置项可调字体、透明度、最大行数、位置
- 多显示器下不丢失到屏幕外

**当前实现状态 (App Target)**：
- 已通过 `OverlayWindowController` 封装 `NSPanel` 满足所有苛刻的辅助窗口约束（去背景、跨屏、浮窗级高度）。
- 已通过 `OverlayView` 和 `RealOverlayRenderer` 实现 UI 渲染逻辑，包含原文半透明状态与平滑动画。

### 12.3 Milestone C: 增量翻译

目标：

- segment commit 机制稳定
- 翻译顺序稳定
- 译文显示不抖动

完成定义：

- 有 `TranscriptBuffer`
- 有串行 `TranslationQueue`
- 译文按 committed 顺序 append
- 正常讲话时不会整段频繁改写

**当前实现状态 (Core Target 已实现 ✅)**：
- 已实现 `TranscriptBuffer` 以严格执行 `partial` 和 `commit` 拆分。
- 保证了 `committedSegments` 提交后不再重排，翻译状态和 `id` 绑定。
- **真实管线已接通**：利用 macOS 15 级别的内部 `TranslationSession` 接口以及串行 `AsyncStream` 队列，完成了 `NativeTranslationService`，支持无乱序的本地翻译注入返回并实时渲染至下游视图。

### 12.4 Milestone D: 分句与标点

目标：

- committed 字幕达到可读标准

完成定义：

- 有规则分句
- 有基础标点补齐
- 可选智能润色开关
- `10` 分钟连续对话后字幕仍可读

### 12.5 Milestone E: 稳定性与产品化

目标：

- 能支撑真实长会场景

完成定义：

- `1` 小时稳定运行
- 错误恢复可用
- 日志可用
- 设置面板闭环

### 12.6 Milestone F: 系统音频输入模式

目标：

- 在不破坏麦克风链路的前提下，新增系统输出音频实时翻译模式

完成定义：

- 菜单栏单独提供 `启动翻译系统音频`
- 用户可以明确选择被监听的显示器、窗口或应用
- 系统音频被送入与麦克风模式相同的 ASR / segment / 翻译链路
- 系统音频权限失败不会影响麦克风模式可用性
- 同一时刻仍只允许一个活跃输入源会话

## 13. 验收测试清单

### 13.1 功能验收

- `启动翻译麦克风 / 启动翻译系统音频 / Pause / Resume / Stop` 行为正确
- 语言切换正确
- 翻译开关正确
- 浮窗开关正确
- 设置持久化正确

### 13.2 场景验收

- 安静环境单人讲话
- 快速连续讲话
- 系统音频模式（单应用）
- 系统音频模式（单显示器）
- 内容选择取消与重新选择
- 中英混输
- 数字和单位混输
- Space 切换
- 全屏浏览器
- 全屏演示
- 多显示器切换

### 13.3 稳定性验收

- `30` 分钟连续识别
- `1` 小时长会模拟
- 多次暂停恢复
- 多次系统音频开始 / 停止切换
- 睡眠唤醒恢复
- 麦克风断开重连

## 14. 风险与处理策略

### 14.1 partial 抖动

风险：

- partial 高频变化导致 UI 频闪

处理：

- 对 partial 更新做节流
- 用差分更新替代整块重绘

### 14.2 翻译乱序

风险：

- 异步翻译返回顺序不一致

处理：

- 强制串行队列
- 用 segment `id` 对齐回填

### 14.3 浮窗丢失

风险：

- 在全屏或 Space 切换时浮窗不可见

处理：

- 正确设置窗口行为
- 做专门场景回归测试

### 14.4 长会内存增长

风险：

- 历史字幕无限增长

处理：

- 只保留最近 N 行
- 旧记录写入日志

### 14.5 翻译网络失败

风险：

- 网络差时整体体验断裂

处理：

- 翻译失败不阻塞原文
- 做超时和有限重试
- 优先降级到系统翻译
- 系统翻译不可用时回退只显示原文

### 14.6 系统音频授权与可用性

风险：

- macOS 系统音频抓取依赖用户显式授权与内容选择，失败路径比麦克风复杂

处理：

- 把系统音频模式视为独立启动入口，不污染麦克风模式
- 首选 `ScreenCaptureKit` 音频输出，不依赖私有全局音频钩子
- 权限拒绝、选择取消、源对象失效都必须回到可重试状态
- 明确提示“系统音频模式需要用户选择内容源”，不承诺后台静默全局抓取

## 15. 开发顺序要求

后续 agent 开发必须按以下顺序推进，除非用户明确改变优先级：

1. 先打通麦克风识别链路
2. 再补系统音频输入模式
3. 再做浮窗显示
4. 再做 segment commit 和增量翻译
5. 再做分句与标点
6. 最后做性能、稳定性、设置与日志

原因：

- 没有稳定识别，后续模块没有可靠输入
- 没有稳定 commit，翻译体验一定会抖
- 没有先控制数据流，后续优化只会加复杂度

## 16. Agent 开发规则

本节用于约束未来的 AI agent，减少重复犯错。

### 16.1 允许的实现倾向

- 优先实现最小闭环
- 优先做可验证的小步提交
- 优先保留模块边界
- 优先让 `Coordinator` 管主流程

### 16.2 不允许的实现倾向

- 不要把 UI 当业务状态真源
- 不要在每次 partial 时重翻整个 transcript
- 不要让多个翻译请求并发写同一段输出
- 不要在 MVP 阶段加入未要求的“智能增强”功能
- 不要让远端翻译状态影响本地 ASR 主链路
- 不要为了“更聪明”破坏稳定性

### 16.3 并行开发建议

适合并行拆分的工作包：

- 菜单栏与设置壳层
- 音频与 ASR 管线
- `TranscriptBuffer`
- 浮窗渲染
- 翻译服务与缓存
- 稳定性和日志

共享约束：

- 所有模块必须通过统一事件或协调层接入
- 不允许各模块私自维护彼此的主状态副本

## 17. 后续版本方向与新增需求变更

### 17.1 已提升优先级的新需求：系统音频实时翻译

本轮新增需求将“系统音频捕获”从延后项提升为当前正式需求，目标是让用户可以在菜单栏直接选择两种启动方式：

- `启动翻译麦克风`
- `启动翻译系统音频`

本需求的产品与技术边界如下：

- 第一版只支持单一活跃输入源，不支持麦克风与系统音频同时并行翻译
- 系统音频模式复用既有 ASR、`TranscriptBuffer`、翻译队列和浮窗渲染，不另起第二套字幕链路
- 系统音频模式在 macOS 上应优先使用 `ScreenCaptureKit` 的音频输出能力，并要求用户明确选择显示器、窗口或应用
- 系统音频模式与录屏不同，但它仍依赖系统内容捕获授权，因此必须把授权失败、取消选择、源对象失效视为正常可恢复路径
- 菜单栏的“启动”不再是单一动作，而是显式区分输入源的两个动作，避免用户误以为系统会自动判断来源
- 若系统音频模式不可用，麦克风模式必须继续可用，不能因为新增能力破坏现有主链路

推荐分阶段落地：

1. 先支持“选择单个显示器并抓取其系统音频”
2. 再支持“选择单个应用或窗口并抓取其系统音频”
3. 最后再考虑更复杂的目标切换、重选和更细粒度的 UX 提示

### 17.2 仍然延后的方向

以下仍属于明确延后项，仅记录，不纳入当前 PRD 执行范围：

- partial 预测翻译
- 本地离线 ASR（绝对离线且不回退服务端）
- 本地离线翻译
- 摘要和导出增强
- 说话人分离

## 18. 最终执行摘要

本 MVP 的核心设计决策是：

- 本地 ASR 是实时主链路，必须独立于网络持续工作
- 输入源必须显式区分为麦克风模式和系统音频模式，并保持单会话约束
- 译文只能基于 committed segment 稳定追加
- 翻译必须支持远端优先和自动降级

只要守住这些规则，系统就能在 5 到 6 周内以较低复杂度实现一个稳定、可信、可继续扩展的实时字幕 MVP。
