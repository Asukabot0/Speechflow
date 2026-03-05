# Speechflow AI Agent Runbook

This file is for AI agents. It describes the minimum deterministic process to install, build, deploy, and validate Speechflow.

Language: [English](AI_AGENT_README.en.md) | [中文](AI_AGENT_README.zh-CN.md)

## 1. Goal and Expected Output

- Install all required dependencies on macOS 15+
- Produce a runnable app bundle: `dist/Speechflow.app`
- Complete minimum acceptance checks (dependencies, model, build, launch)

## 2. Preconditions

- OS: macOS 15+
- Network access to Homebrew and Ollama model registry
- Current working directory is the repository root: `/Users/asukabot/Speechflow`

## 3. Standard Install Flow (recommended)

Run in order:

```bash
cd /Users/asukabot/Speechflow
./Scripts/install_dev_dependencies.sh
export SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH="/Users/asukabot/Speechflow/.venv/bin/python"
swift build
./Scripts/build_dev_app_bundle.sh
open dist/Speechflow.app
```

Notes:

- `install_dev_dependencies.sh` installs `python`, `ollama`, and `ffmpeg`
- The script creates `.venv` and installs `qwen-asr` and `faster-whisper`
- It starts Ollama and pulls `qwen3.5:0.8b` by default

## 4. Optional Install Modes

- Skip Python dependency install:

```bash
./Scripts/install_dev_dependencies.sh --no-python-deps
```

- Skip model pull:

```bash
./Scripts/install_dev_dependencies.sh --no-ollama-model-pull
```

- Pull multiple models in one run:

```bash
SPEECHFLOW_BOOTSTRAP_OLLAMA_MODELS="qwen3.5:0.8b,qwen3.5:2b" ./Scripts/install_dev_dependencies.sh
```

## 5. Deployment Flow

### 5.1 Local Deployment (dev/test)

```bash
cd /Users/asukabot/Speechflow
swift build
./Scripts/build_dev_app_bundle.sh
open dist/Speechflow.app
```

Artifact path:

- `dist/Speechflow.app`

### 5.2 Team Distribution

```bash
cd /Users/asukabot/Speechflow
./Scripts/build_dev_app_bundle.sh
tar -czf dist/Speechflow.app.tar.gz -C dist Speechflow.app
```

Before external distribution, add in CI/CD:

- Developer ID signing
- Apple notarization
- Release artifact verification (hashes and versioning)

## 6. Agent Acceptance Checklist

Run and verify all checks pass:

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

Expected results:

- `swift build` succeeds
- `run_local_translation_bench.sh` prints cold/warm benchmark output
- `dist/Speechflow.app` exists and can be launched

## 7. Common Failures and Fixes

- Symptom: permission prompt fails or process is terminated by the system
  Fix: do first permission flow with `dist/Speechflow.app`, not `swift run SpeechflowApp`

- Symptom: local translation fails due to missing model
  Fix: run `ollama pull qwen3.5:0.8b`

- Symptom: cannot connect to Ollama
  Fix: run `ollama serve` and check `curl http://127.0.0.1:11434/api/tags`

- Symptom: ASR reports invalid Python path
  Fix: set `SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH` to `.venv/bin/python`

## 8. Critical Entry Files

- Dependency bootstrap script: `Scripts/install_dev_dependencies.sh`
- App bundle build script: `Scripts/build_dev_app_bundle.sh`
- Translation benchmark: `Scripts/run_local_translation_bench.sh`
- Troubleshooting: `Docs/TROUBLESHOOTING.md`
