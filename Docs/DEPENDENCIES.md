# Speechflow Dependency Inventory

This document records the dependencies used by the live codebase as of March 4, 2026.

It is an inventory, not a lockfile:

- Swift build dependencies are defined in [Package.swift](/Users/asukabot/Speechflow/Package.swift).
- Python package versions below reflect the currently active runtime used by this workspace (`python3` -> `/opt/homebrew/Caskroom/miniconda/base/bin/python3`).
- Optional Apple frameworks and local services can still be absent at runtime if the host machine is not configured for them.

## 1. Build Toolchain

- Swift toolchain: `6.2` (`// swift-tools-version: 6.2`)
- Minimum deployment target: `macOS 15`
- Build system: Swift Package Manager (`swift build`, `swift run`)
- Script shell: `zsh`

Build scripts currently checked into the repo:

- [build_dev_app_bundle.sh](/Users/asukabot/Speechflow/Scripts/build_dev_app_bundle.sh)
- [run_local_translation_bench.sh](/Users/asukabot/Speechflow/Scripts/run_local_translation_bench.sh)

## 2. Swift Package Dependencies

Direct SwiftPM package dependencies:

- None

Internal package targets:

- `SpeechflowCore`
- `SpeechflowApp`
- `LocalTranslationBench`

Bundled package resources:

- [faster_whisper_runner.py](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Resources/faster_whisper_runner.py)
- [Info.plist](/Users/asukabot/Speechflow/Sources/SpeechflowApp/Resources/Info.plist)

## 3. Apple Framework Dependencies

Direct Apple frameworks imported by the current source tree:

- `Foundation`
- `Dispatch`
- `AVFoundation`
- `Speech`
- `ScreenCaptureKit`
- `CoreMedia`
- `SwiftUI`
- `AppKit`
- `Combine`
- `Translation`
- `Darwin`

Notes:

- `Translation` is guarded by `canImport(Translation)` and is only used when the system framework is available.
- `Speech` is used for permissions and the fallback `SFSpeechRecognizer` path.
- `ScreenCaptureKit` is used for system audio capture.

## 4. External Runtime Dependencies

Required or expected local runtimes outside SwiftPM:

- `Python 3`
- Local Hugging Face model cache for ASR under `~/Library/Application Support/Speechflow/Models/ASR`
- OpenRouter API access for cloud translation
- Local Ollama HTTP service for translation (`http://127.0.0.1:11434` by default)

Optional host tools used by scripts:

- `codesign` (used opportunistically by the app bundle script if present)

## 5. Python ASR Dependencies

The ASR runner supports both the current Qwen path and the legacy faster-whisper path. The app does not ship a `requirements.txt` yet, so the versions below are the currently installed runtime versions rather than repo-pinned versions.

### 5.1 Direct Python Packages Used by the ASR Runtime

- `qwen-asr==0.0.6`
- `faster-whisper==1.2.1`
- `torch==2.10.0`
- `transformers==4.57.6`
- `huggingface_hub==0.36.2`
- `qwen-omni-utils==0.0.9`
- `sox==1.5.0`

Current availability in the active Python runtime:

- `qwen_asr`: installed
- `faster_whisper`: installed

### 5.2 Immediate Python Dependencies Introduced by Qwen ASR

Observed package chain for the currently installed `qwen-asr` runtime:

- `accelerate==1.12.0`
- `Flask==3.0.0`
- `gradio==6.8.0`
- `librosa==0.11.0`
- `nagisa==0.2.11`
- `pytz==2026.1.post1`
- `qwen-omni-utils==0.0.9`
- `soundfile==0.13.1`
- `sox==1.5.0`
- `soynlp==0.0.493`
- `transformers==4.57.6`

### 5.3 Immediate Python Dependencies Introduced by Faster Whisper

Observed package chain for the currently installed `faster-whisper` runtime:

- `av==16.1.0`
- `ctranslate2==4.7.1`
- `huggingface_hub==0.36.2`
- `onnxruntime==1.24.2`
- `tokenizers==0.22.2`
- `tqdm==4.67.1`

## 6. Model Dependencies

Default ASR model:

- `Qwen/Qwen3-ASR-1.7B`

Alternative ASR backend still supported by the same runner:

- `faster-whisper` models, when selected through `SPEECHFLOW_ASR_BACKEND=faster_whisper` or legacy faster-whisper environment variables

Default local translation models expected by the current code:

- `qwen3.5:0.8b`
- `qwen3.5:2b`

Default cloud translation model:

- `openai/gpt-oss-120b` via OpenRouter

## 7. Operational Notes

- There is currently no repo-managed `requirements.txt`, `pyproject.toml`, or lockfile for the Python runtime.
- Updating the Python environment can change behavior outside this repo because the ASR runtime is resolved from the active machine Python installation.
- If dependency reproducibility becomes important, the next step should be adding a checked-in Python dependency file and documenting the bootstrap command in the same place.
