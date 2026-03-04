# Speechflow Troubleshooting Guide

## 1. 适用范围

这份手册用于排查当前代码基线下最常见的五类问题：

- 启动后直接闪退
- 没有原文字幕
- 有原文但没有翻译
- 断句太长或同一段被反复翻译
- 本地 Ollama 不可用或翻译速度异常

当前手册默认你面对的是这套实际链路：

- ASR 主链路：`faster-whisper`
- ASR fallback：`SpeechFramework`
- 翻译默认：本地 `Ollama`
- 默认模型：`qwen3.5:2b`

## 2. 先确认运行方式

很多“看起来像 bug”的问题，其实是运行方式不对。

优先确认这两点：

1. 首次做权限验证时，是否通过打包后的 `.app` 运行，而不是 `swift run`
2. 当前测试的是哪种输入源
   - 麦克风
   - 系统音频

推荐先用开发打包脚本：

```bash
/Users/asukabot/Speechflow/Scripts/build_dev_app_bundle.sh
```

再从这里启动：

- `dist/Speechflow.app`

原因：

- `SystemPermissionService` 会避免在原始 SwiftPM 进程里直接触发敏感权限弹窗，因为这类场景下 macOS TCC 可能直接终止进程。

## 3. 先收集哪些信息

开始深入排查前，先把下面这些信息收集齐。

### 3.1 日志

优先看：

- `/tmp/speechflow_debug.log`

常用命令：

```bash
tail -n 200 /tmp/speechflow_debug.log
```

### 3.2 崩溃报告

如果是闪退，优先看：

- `~/Library/Logs/DiagnosticReports`

常用命令：

```bash
ls -1t ~/Library/Logs/DiagnosticReports | head -n 10
```

重点关注：

- `Speechflow*.ips`
- `SpeechflowApp*.ips`
- 与当前测试时间接近的 `python3*.ips`

### 3.3 当前症状边界

先分清楚是哪一层出问题：

1. 应用直接退出
2. 应用还在，但没有原文
3. 原文有了，但没有翻译
4. 翻译有了，但断句很差
5. 断句和翻译都有，但速度明显越来越慢

如果症状边界没分清，排查会很容易跑偏。

## 4. 快速健康检查

遇到问题时，先做这几项。

### 4.1 工程是否还能正常构建

```bash
cd /Users/asukabot/Speechflow
swift build
```

如果这里都失败，先不要继续做运行时判断。

### 4.2 Ollama 是否活着

```bash
ollama list
curl -s http://127.0.0.1:11434/api/tags
```

如果 `api/tags` 都不通，本地翻译默认一定会失败。

### 4.3 默认模型是否存在

默认模型是：

- `qwen3.5:2b`

如果不在 `ollama list` 中，先拉模型：

```bash
ollama pull qwen3.5:2b
```

### 4.4 本地翻译基线速度是否正常

```bash
/Users/asukabot/Speechflow/Scripts/run_local_translation_bench.sh
```

这个命令能快速告诉你：

- 当前选中的模型
- 当前 Ollama endpoint
- cold / warm 的耗时

如果 bench 都跑不通，不要先怀疑 UI 或字幕逻辑。

## 5. 问题一：启动后直接闪退

### 5.1 最常见原因

当前最常见的几类直接闪退来源是：

- 通过错误的运行方式触发权限流程
- 识别事件回调和 UI 更新发生了异常重入
- Python runner 或系统权限相关进程在启动时直接异常退出

### 5.2 第一轮排查顺序

按这个顺序看：

1. 先确认是不是从 `.app` 启动
2. 看 `/tmp/speechflow_debug.log` 是否已经写到 `WhisperTurboASRService launching faster-whisper runner`
3. 看 `DiagnosticReports` 里有没有新的 `.ips`

### 5.3 如何判断崩在什么阶段

如果日志停在这些位置，大致可以这样判断：

- 只有 `PreferredLocalASRService starting primary ASR backend`
  - 说明刚进入主识别启动阶段

- 到了 `WhisperTurboASRService validated faster-whisper runtime`
  - 说明 Python 路径、runner 路径和模型配置至少通过了前置校验

- 到了 `WhisperTurboASRService received first audio buffer`
  - 说明采集开始工作了

- 到了 `WhisperTurboASRService scheduling transcription`
  - 说明已经在送第一轮转写

- 到了 `WhisperTurboASRService launching faster-whisper runner`
  - 说明崩点很可能在 runner 或其后的回调链

### 5.4 需要保留的材料

如果要继续定位闪退，至少保留：

- 最新 `speechflow_debug.log` 尾部
- 最新 `.ips` 文件名
- 是在点了哪一个启动入口后崩的

## 6. 问题二：没有原文字幕

这类问题先不要看翻译，先只盯 ASR。

### 6.1 先确认权限

麦克风模式需要：

- 麦克风权限
- 语音识别权限

系统音频模式当前至少需要：

- 语音识别权限

如果权限没过，`AppCoordinator` 会先进入错误态，不应该继续指望字幕出来。

### 6.2 看日志卡在哪一跳

这几行是最关键的分界点：

- `PreferredLocalASRService starting primary ASR backend`
- `WhisperTurboASRService validated faster-whisper runtime`
- `WhisperTurboASRService received first audio buffer`
- `WhisperTurboASRService accepted first resampled audio chunk`
- `WhisperTurboASRService scheduling transcription`
- `WhisperTurboASRService launching faster-whisper runner`
- `WhisperTurboASRService faster-whisper runner ready`

### 6.3 各阶段对应的问题

如果没有 `received first audio buffer`：

- 问题更偏向采集层
- 先检查输入源是否正确
- 再检查权限和设备

如果有 `received first audio buffer`，但没有 `accepted first resampled audio chunk`：

- 问题更偏向重采样或音频格式处理

如果有 `accepted first resampled audio chunk`，但没有 `scheduling transcription`：

- 问题更偏向窗口阈值太高，或有效音频不够

如果有 `scheduling transcription`，但没有 `faster-whisper runner ready`：

- 问题更偏向 Python runner 或 `faster-whisper` 本身

### 6.4 `faster-whisper` 主链路失败但 app 没崩

当前设计里，主链路失败后会尝试回退到 `SpeechFrameworkASRService`。

如果你看到：

- 原文还是完全没有
- 同时日志出现 `.localASRFailed`

那要继续确认 fallback 是否真的成功启动。

## 7. 问题三：有原文，但没有翻译

这类问题先确认是不是“根本还没 commit”，而不是翻译坏了。

### 7.1 当前翻译只对 committed segment 生效

这点非常重要：

- partial 文本默认不会正式进入翻译区
- 只有 committed segment 才会进翻译队列

所以如果你看到原文一直在滚动，但一直没有稳定提交，翻译为空是符合当前设计的。

### 7.2 先确认翻译开关和后端

先看：

- `Enable Translation by Default` 是否开启
- 当前 `Backend` 是 `Local Ollama` 还是 `System`

### 7.3 排查本地 Ollama

如果后端是 `Local Ollama`，先检查：

```bash
ollama list
curl -s http://127.0.0.1:11434/api/tags
```

默认模型缺失时，当前实现会直接报错提示：

- `ollama pull qwen3.5:2b`

### 7.4 判断是“没入队”还是“入队失败”

在日志里重点找：

- `[Translation][LocalOllama] queued ...`

如果根本没有这行：

- 更可能是 segment 还没 commit
- 或者翻译开关关闭了

如果有这行，但界面仍没译文：

- 更可能是 Ollama 请求失败
- 或系统 provider fallback 没成功

## 8. 问题四：断句太长，或同一段被反复翻译

这是当前最需要持续调优的部分。

### 8.1 先分清是哪一层重复

常见有两种：

1. ASR 本身不断把长句扩写
2. 同一长句前缀被重复送入翻译

这两层现象很像，但根因不同。

### 8.2 当前系统如何尽量缩短句子

现在的策略是：

1. 优先用 `faster-whisper` 原生返回的 `segments`
2. 如果有多段，只先提交最前面的一段
3. 剩余部分继续作为滚动 `partial`
4. 如果模型只给一大段，再做启发式切分

### 8.3 为什么仍然会出现长句

当前最常见原因：

- 说话人连续口播，模型本轮只返回一个长 segment
- 新一轮转写把旧前缀又带回来了
- commit 虽然更快了，但前缀去重还不够激进

### 8.4 哪些参数最值得先调

先调这几项，而不是先改 prompt：

- `SPEECHFLOW_WHISPER_POLL_SECONDS`
- `SPEECHFLOW_WHISPER_MIN_START_SECONDS`
- `SPEECHFLOW_WHISPER_MIN_INCREMENT_SECONDS`
- `SPEECHFLOW_WHISPER_MAX_WINDOW_SECONDS`
- `SPEECHFLOW_FASTER_WHISPER_VAD_MIN_SILENCE_MS`

总体原则：

- 想更快滚动：减小轮询和增量窗口
- 想少切碎：增大静音和窗口阈值

### 8.5 什么时候应该继续改代码而不是只调参

如果你看到这种现象，就说明单纯调参数不够了：

- 同一段前缀稳定重复出现在多次 committed 中
- 翻译明显越来越慢，因为每次都在重译长前缀
- 句子虽然有内部自然边界，但系统仍然总是等到很长才切

这时下一步应该优先考虑：

1. 更强的 pending translation 去重
2. 基于词时间轴的切分，而不是继续只靠字符阈值

## 9. 问题五：Ollama 不可用或速度异常

### 9.1 先看服务是否可达

```bash
curl -s http://127.0.0.1:11434/api/tags
```

如果这里不通，当前默认本地翻译一定不可用。

### 9.2 先看模型是否存在

```bash
ollama list
```

确认有没有：

- `qwen3.5:2b`

### 9.3 速度异常时先做基线跑分

```bash
/Users/asukabot/Speechflow/Scripts/run_local_translation_bench.sh
```

先看：

- cold 是否异常慢
- warm 是否也异常慢

判断逻辑：

- cold 慢、warm 正常：更像是模型装载开销
- cold 和 warm 都慢：更像是 Ollama 服务、模型体积或机器负载问题

### 9.4 常见配置项

如果需要调 Ollama 行为，优先看这些环境变量：

- `SPEECHFLOW_OLLAMA_MODEL`
- `SPEECHFLOW_OLLAMA_BASE_URL`
- `SPEECHFLOW_OLLAMA_TIMEOUT_SECONDS`
- `SPEECHFLOW_OLLAMA_MAX_TOKENS`
- `SPEECHFLOW_OLLAMA_KEEP_ALIVE`
- `SPEECHFLOW_OLLAMA_THINK`

## 10. 常用诊断命令

建议优先使用下面这一组最小命令集：

```bash
cd /Users/asukabot/Speechflow
swift build
tail -n 200 /tmp/speechflow_debug.log
ls -1t ~/Library/Logs/DiagnosticReports | head -n 10
ollama list
curl -s http://127.0.0.1:11434/api/tags
/Users/asukabot/Speechflow/Scripts/run_local_translation_bench.sh
```

## 11. 提交问题时最好附带什么

如果要继续深入排查，最好一次性附上这些信息：

- 你用的是麦克风模式还是系统音频模式
- 是否通过 `.app` 启动
- 是否有原文、是否有翻译
- 当前 backend 是 `Local Ollama` 还是 `System`
- `/tmp/speechflow_debug.log` 最后 50 到 200 行
- 最新 `.ips` 文件名（如果有闪退）
- 一小段能稳定复现问题的原始口播内容

## 12. 当前建议的排查顺序

碰到复杂问题时，统一按这个顺序查：

1. 先确认运行方式和权限
2. 再确认有没有原文
3. 再确认有没有 commit
4. 再确认翻译是否入队
5. 最后才调 prompt、断句阈值或模型

这样能避免把采集问题误判成翻译问题，也能避免把 commit 问题误判成 Ollama 问题。
