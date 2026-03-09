# Speechflow Dependency Inventory

This document records the dependencies used by the live codebase as of March 7, 2026.

It is an inventory, not a lockfile:

- Swift build dependencies are defined in [Package.swift](/Users/asukabot/Speechflow/Package.swift).
- Checked-in Python ASR dependencies are defined in [requirements.txt](/Users/asukabot/Speechflow/requirements.txt).
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

- [qwen_asr_runner.py](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Resources/qwen_asr_runner.py)
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
- Apple Silicon with MLX / Metal support for the primary ASR path
- Local Hugging Face model cache for ASR downloads, or an explicit `SPEECHFLOW_ASR_MODEL_PATH`
- OpenRouter API access for cloud translation
- Local Ollama HTTP service for translation (`http://127.0.0.1:11434` by default)

Optional host tools used by scripts:

- `codesign` (used opportunistically by the app bundle script if present)

## 5. Python ASR Dependencies

The live ASR runner now targets `mlx-audio` with `mlx-community/Qwen3-ASR-1.7B-4bit` on Apple Silicon. The repo ships a minimal [requirements.txt](/Users/asukabot/Speechflow/requirements.txt) for the primary Python dependency.

### 5.1 Direct Python Packages Used by the ASR Runtime

- `mlx-audio==0.3.1`
- `mlx>=0.25.2`
- `mlx-lm==0.30.5`
- `transformers==5.0.0rc3`
- `huggingface_hub>=0.27.0`
- `numpy>=1.26.4`
- `librosa==0.11.0`

Key import/runtime expectations:

- `mlx_audio` must be importable from the Python executable referenced by `SPEECHFLOW_ASR_PYTHON_PATH`
- `mlx.core.metal.is_available()` must return `True` for the primary path to start
- Legacy `SPEECHFLOW_FASTER_WHISPER_*` environment aliases are still accepted by the Swift runtime descriptor

### 5.2 Immediate Python Dependencies Introduced by MLX Audio

Selected transitive dependencies declared by `mlx-audio==0.3.1`:

- `miniaudio>=1.61`
- `librosa==0.11.0`
- `numba>=0.60.0`
- `pyloudnorm>=0.2.0`
- `sounddevice==0.5.3`
- `tqdm>=4.67.1`

## 6. Model Dependencies

Default ASR model:

- `mlx-community/Qwen3-ASR-1.7B-4bit`

Default local translation models expected by the current code:

- `qwen3.5:0.8b`
- `qwen3.5:2b`

Default cloud translation model:

- `openai/gpt-oss-120b` via OpenRouter

## 7. Operational Notes

- The repo now includes a minimal [requirements.txt](/Users/asukabot/Speechflow/requirements.txt) for the primary ASR dependency, but it is not a full lockfile.
- Updating the Python environment can change behavior outside this repo because the ASR runtime is resolved from the active machine Python installation.
- If dependency reproducibility becomes important, the next step should be adding a checked-in Python dependency file and documenting the bootstrap command in the same place.
