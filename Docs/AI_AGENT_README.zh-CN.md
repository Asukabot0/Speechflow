# Speechflow AI Agent Runbook

本文件给 AI Agent 使用，目标是让 Agent 在最少上下文下完成本项目的安装、构建、部署与验收。

语言 / Language: [中文](AI_AGENT_README.zh-CN.md) | [English](AI_AGENT_README.en.md)

## 1. 目标与输出

- 在 macOS 15+ 机器上完成依赖安装
- 产出可运行应用：`dist/Speechflow.app`
- 完成最小可用验证（依赖、模型、构建、启动）

## 2. 前置条件

- 系统：macOS 15+
- 网络可访问 Homebrew 和 Ollama 模型仓库
- 当前目录是仓库根目录：`/Users/asukabot/Speechflow`

## 3. 标准安装流程（推荐）

按顺序执行：

```bash
cd /Users/asukabot/Speechflow
./Scripts/install_dev_dependencies.sh
export SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH="/Users/asukabot/Speechflow/.venv/bin/python"
swift build
./Scripts/build_dev_app_bundle.sh
open dist/Speechflow.app
```

说明：

- `install_dev_dependencies.sh` 会安装 `python`、`ollama`、`ffmpeg`
- 脚本会创建 `.venv` 并安装 `qwen-asr`、`faster-whisper`
- 脚本会启动 Ollama 并默认拉取 `qwen3.5:0.8b`

## 4. 可选安装参数

- 跳过 Python 依赖安装：

```bash
./Scripts/install_dev_dependencies.sh --no-python-deps
```

- 跳过模型拉取：

```bash
./Scripts/install_dev_dependencies.sh --no-ollama-model-pull
```

- 一次拉多个模型：

```bash
SPEECHFLOW_BOOTSTRAP_OLLAMA_MODELS="qwen3.5:0.8b,qwen3.5:2b" ./Scripts/install_dev_dependencies.sh
```

## 5. 部署流程

### 5.1 本机部署（开发/测试）

```bash
cd /Users/asukabot/Speechflow
swift build
./Scripts/build_dev_app_bundle.sh
open dist/Speechflow.app
```

产物路径：

- `dist/Speechflow.app`

### 5.2 分发部署（团队内）

```bash
cd /Users/asukabot/Speechflow
./Scripts/build_dev_app_bundle.sh
tar -czf dist/Speechflow.app.tar.gz -C dist Speechflow.app
```

分发前建议在 CI/CD 补齐：

- Developer ID 签名
- Notarization
- 发布物校验（哈希、版本号）

## 6. Agent 验收清单

执行以下检查并确认全部通过：

```bash
cd /Users/asukabot/Speechflow
python3 --version
ollama --version
curl -fsS http://127.0.0.1:11434/api/tags
ollama list
swift build
./Scripts/run_local_translation_bench.sh
test -d dist/Speechflow.app && echo "app bundle ok"
```

期望结果：

- `swift build` 成功
- `run_local_translation_bench.sh` 可以输出 cold/warm 结果
- `dist/Speechflow.app` 存在并可启动

## 7. 常见失败与处理

- 症状：权限申请异常或进程被系统终止  
  处理：不要用 `swift run SpeechflowApp` 做首次权限验证，改为启动 `dist/Speechflow.app`

- 症状：本地翻译失败，提示模型未安装  
  处理：执行 `ollama pull qwen3.5:0.8b`

- 症状：无法连接 Ollama  
  处理：执行 `ollama serve`，再检查 `curl http://127.0.0.1:11434/api/tags`

- 症状：ASR 报 Python 路径错误  
  处理：导出 `SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH` 指向 `.venv/bin/python`

## 8. 关键入口文件

- 依赖安装脚本：`Scripts/install_dev_dependencies.sh`
- 打包脚本：`Scripts/build_dev_app_bundle.sh`
- 翻译基准：`Scripts/run_local_translation_bench.sh`
- 故障排查：`Docs/TROUBLESHOOTING.md`
