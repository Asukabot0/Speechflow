# Speechflow Interface Contracts

## 1. Purpose

This document describes the current code-level contracts for the live codebase, not the original skeleton.

Use it as the implementation-facing companion to [MVP_DEVELOPMENT_PLAN.md](/Users/asukabot/Speechflow/MVP_DEVELOPMENT_PLAN.md).

It answers four practical questions:

- Which target owns which responsibility today
- Which shared types are stable cross-module contracts
- Which runtime paths are live, fallback, or still stubbed
- Which invariants future changes must preserve

## 2. Package Layout

File: [Package.swift](/Users/asukabot/Speechflow/Package.swift)

Current targets:

- `SpeechflowCore`
  Shared models, protocols, orchestration, service implementations, and the bundled `faster_whisper_runner.py` resource.

- `SpeechflowApp`
  The macOS menu bar app, SwiftUI views, overlay windows, and live renderer wiring.

- `LocalTranslationBench`
  A CLI executable for measuring local Ollama translation latency against the currently selected model.

Notable packaging rule:

- `SpeechflowCore` has no Swift package dependencies. Local ASR and translation rely on system frameworks plus local external runtimes:
  - Python 3 + `faster-whisper`
  - local Ollama HTTP service

## 3. Shared Model Contracts

### 3.1 App State

File: [AppState.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Models/AppState.swift)

- `AppState`
- `AppErrorContext`

Rules:

- `AppCoordinator` is the only owner that should mutate global app state.
- Service failures should surface as events first, then be mapped into `AppState` transitions by the coordinator.

### 3.2 Transcript Models

File: [TranscriptModels.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Models/TranscriptModels.swift)

- `SegmentStatus`
- `CommitReason`
- `TranscriptSegment`
- `TranscriptSnapshot`
- `TranscriptBufferMutation`

Rules:

- `partialText` always represents the current uncommitted text only.
- Translation results are attached by `segment.id`, never by display index.
- Committed display order is stable, but the buffer is allowed to replace a few recent trailing segments when a newer ASR refinement clearly supersedes them.
- Consumers must treat `segment.id` as the durable identity, not raw text.

Important current behavior:

- `TranscriptBuffer` suppresses exact duplicate commits within a short window.
- `TranscriptBuffer` can replace up to several recent overlapping tail segments to avoid repeated rolling refinements stacking in the UI.

### 3.3 Settings Models

File: [SettingsModels.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Models/SettingsModels.swift)

- `LanguagePair`
- `RecognitionTuning`
- `OverlayScreenMode`
- `OverlayFrame`
- `SpeechflowSettings`

Rules:

- `SpeechflowSettings` is the runtime source of truth for user-configurable defaults.
- `translationBackendPreference` is now a first-class shared setting.
- `recognitionTuning.pauseCommitDelay` is user-facing and directly influences commit timing.

Current limitation:

- The live app still uses `InMemorySettingsStore`, so settings are process-local and not persisted across app relaunches yet.

### 3.4 Translation Models

File: [TranslationModels.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Models/TranslationModels.swift)

- `NetworkQuality`
- `TranslationBackend`
- `TranslationBackendPreference`
- `TranslationStrategy`
- `TranslationPolicy`
- `LocalModelDescriptor`
- `LocalModelInstallState`
- `LocalModelRuntimePreference`
- `TranslationExecutionMetadata`
- `TranslationResult`

Rules:

- `TranslationResult` is the only shared success payload for translation completion.
- `TranslationExecutionMetadata` is the canonical place to record fallback and latency facts.
- `TranslationBackendPreference` controls the initial provider route.
- `TranslationBackend` records the actual backend that handled the segment.

Important compatibility note:

- `TranslationPolicy.strategy` still contains legacy names such as `remotePreferred`.
- Current routing no longer means "remote-first network translation" in the default path. The router is now "local Ollama or system provider", but the policy type has not been renamed yet.

### 3.5 Event Model

File: [EventModels.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Interfaces/EventModels.swift)

- `PermissionSet`
- `SpeechflowEvent`

Rules:

- All async service callbacks and user intents enter the system as `SpeechflowEvent`.
- New feature paths should add shared event cases here before adding ad hoc callbacks elsewhere.

Important current behavior:

- `PermissionSet.isReady(for:)` is source-aware:
  - microphone mode requires microphone + speech permission
  - system-audio mode requires speech permission only

## 4. Service Protocol Contracts

File: [ServiceProtocols.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Interfaces/ServiceProtocols.swift)

### 4.1 `AudioEngineServicing`

Responsibilities:

- Select the active capture source
- Start, pause, and stop capture
- Forward `AVAudioPCMBuffer` frames downstream
- Apply recognition tuning at the capture layer

Current live implementations:

- `SystemAudioEngineService`
- `ScreenCaptureSystemAudioService`
- `SelectableAudioCaptureService`

Rules:

- Capture services own audio acquisition only.
- They must not emit transcript text directly.
- They must remain swappable without changing ASR contracts.

### 4.2 `LocalASRServicing`

Responsibilities:

- Start and stop local recognition
- Accept locale changes
- Emit `.asrPartialReceived` and `.asrFinalReceived`
- Emit `.localASRFailed` when the active recognition path cannot continue

Current live implementations:

- `WhisperTurboASRService`
- `SpeechFrameworkASRService`
- `PreferredLocalASRService`

Rules:

- ASR must remain usable when translation is disabled, degraded, or unavailable.
- Local ASR failure should not crash the app directly; it should surface as an event.

### 4.3 `NetworkMonitoring`

Responsibilities:

- Emit `NetworkQuality` changes to translation services

Current live implementation:

- `StubNetworkMonitor`

Rules:

- Network quality is advisory for translation only.
- ASR must not be blocked by network state.

Current limitation:

- This is still a stubbed input. The live app does not yet have real path monitoring.

### 4.4 `PermissionServicing`

Responsibilities:

- Request runtime permissions before startup
- Emit `.permissionsResolved` or `.permissionRequestFailed`

Current live implementation:

- `SystemPermissionService`

Rules:

- Permission requests must be asynchronous.
- Permission denial must route through coordinator error handling.

Important runtime caveat:

- `SystemPermissionService` refuses to prompt for protected resources when running as a raw SwiftPM executable because macOS TCC can terminate the process in that mode.
- Use the bundled `.app` for first-time permission prompts.

### 4.5 `TranscriptBuffering`

Responsibilities:

- Track the active partial text
- Commit draft text into stable segments
- Mark translation in flight
- Apply translation results or failures back onto the right segment
- Reset session-local transcript state

Rules:

- The buffer does not talk to UI directly.
- The buffer does not choose translation providers.
- Tail refinements may replace recent overlapping segments, but historical order still remains chronological.

### 4.6 `TranslateServicing`

Responsibilities:

- Accept committed segments
- Keep translation ordering stable
- Expose backend selection updates
- Emit `.translationFinished` or `.translationFailed`

Current live implementations:

- `TranslationRouterService`
- `LocalOllamaTranslationService`
- `NativeTranslationService` (App target on macOS 15 when `Translation` is available)
- `StubTranslateService`

Rules:

- Translation operates on committed segments only.
- Translation failure is non-fatal to the live subtitle session.
- Translation must not block original subtitle rendering.

### 4.7 `OverlayRendering`

Responsibilities:

- Render the latest `OverlayRenderModel`
- Toggle overlay visibility

Current live implementations:

- `RealOverlayRenderer` in the app target
- `StubOverlayRenderer` in core-only or test wiring

Rule:

- Renderers consume read models only; they must never mutate transcript state.

### 4.8 `SettingsStoring`

Responsibilities:

- Load settings
- Save settings

Current live implementation:

- `InMemorySettingsStore`

Rule:

- Replace the storage backend without changing the coordinator or views.

## 5. Current Live Runtime Graph

### 5.1 Bootstrap Wiring

Files:

- [SpeechflowContainer.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/App/SpeechflowContainer.swift)
- [SpeechflowApp.swift](/Users/asukabot/Speechflow/Sources/SpeechflowApp/SpeechflowApp.swift)

Current live graph:

1. `SelectableAudioCaptureService`
   - microphone: `SystemAudioEngineService`
   - system audio: `ScreenCaptureSystemAudioService`
2. `PreferredLocalASRService`
   - primary: `WhisperTurboASRService`
   - fallback: `SpeechFrameworkASRService`
3. `TranslationRouterService`
   - local provider: `LocalOllamaTranslationService`
   - system provider:
     - `NativeTranslationService` in the app target on macOS 15
     - `StubTranslateService` in core bootstrap and older environments
4. `AppCoordinator`
5. `RealOverlayRenderer` in app target, `StubOverlayRenderer` in core bootstrap

### 5.2 End-to-End Data Flow

The current live flow is:

1. Capture source produces audio buffers.
2. `WhisperTurboASRService` resamples to 16 kHz mono and sends audio windows to the Python `faster-whisper` runner.
3. `PreferredLocalASRService` forwards primary ASR events, or switches to `SpeechFrameworkASRService` if the primary fails.
4. `AppCoordinator` updates partial text, schedules commit timers, and commits draft text when final/stable/silence conditions are met.
5. `TranscriptBuffer` suppresses duplicate commits and folds recent overlapping refinements.
6. `TranslationRouterService` chooses a provider based on `translationBackendPreference`, then may fallback across providers if the active provider fails.
7. `TranslationResult` is applied back by `segment.id`.
8. `OverlayViewModelBuilder` converts the snapshot into render lines.
9. `OverlayRendering` updates the visible overlay.

## 6. ASR Runtime Contracts

Primary files:

- [WhisperTurboASRService.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Services/WhisperTurboASRService.swift)
- [faster_whisper_runner.py](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Resources/faster_whisper_runner.py)

### 6.1 Primary Recognition Path

`WhisperTurboASRService` is the primary local recognizer.

It currently:

- validates a local Python 3 runtime
- launches a persistent bundled Python runner
- uses `faster-whisper` as the inference engine
- defaults to the `turbo` model
- converts incoming audio to 16 kHz mono
- emits partial and final events
- performs aggressive subtitle-oriented segmentation before forwarding text downstream

### 6.2 Fallback Path

`PreferredLocalASRService` automatically falls back to `SpeechFrameworkASRService` when:

- the primary recognizer fails to start
- the primary emits `.localASRFailed` during a live session

This fallback is non-fatal. The session should continue if the fallback starts successfully.

### 6.3 Current Segmentation Rules

Segmentation is intentionally layered:

1. Prefer `faster-whisper`'s own returned segment boundaries.
2. If the model returns multiple segments, commit the earliest segment and keep the tail rolling as partial text.
3. If the model returns a single long segment, apply heuristic split rules:
   - terminal punctuation first
   - clause punctuation next
   - token-boundary forced split last
4. Strip already committed leading overlap from later rolling transcriptions to avoid resending long repeated prefixes.

This logic is still under active tuning. It is expected to evolve.

### 6.4 ASR Environment Variables

Most important runtime overrides:

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

Rule:

- Future ASR changes should keep environment-based tuning overrides compatible unless there is a strong reason to break them.

## 7. Translation Runtime Contracts

Primary files:

- [TranslationRouterService.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Services/TranslationRouterService.swift)
- [LocalOllamaRuntime.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Services/LocalOllamaRuntime.swift)
- [NativeTranslationService.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Services/NativeTranslationService.swift)

### 7.1 Router Contract

`TranslationRouterService` is the only translation service that `AppCoordinator` should depend on.

It owns:

- initial provider selection
- per-segment pending execution tracking
- fallback routing after provider failure
- final normalization of `TranslationExecutionMetadata`

Rule:

- Keep the provider split behind the router. Do not let `AppCoordinator` call provider-specific APIs.

### 7.2 Local Provider Contract

`LocalOllamaTranslationService` is the current local model provider.

It currently:

- checks installed models through `GET /api/tags`
- selects a preferred model descriptor
- builds a spoken-style live-subtitle prompt
- queues requests through a serial `AsyncStream`
- calls `LocalOllamaRuntime` for the actual HTTP `POST /api/generate`

Rule:

- Local translation must remain serial and ordered.

### 7.3 System Provider Contract

The "system" provider is environment-dependent:

- In the app target on macOS 15, `NativeTranslationService` uses `TranslationSession`.
- In core bootstrap or unsupported environments, `StubTranslateService` is used instead.

This distinction matters for docs and debugging:

- core-only runs can compile without proving the real system translation path
- app runs on macOS 15 have a real system translation fallback path

### 7.4 Current Default Backend

The default backend preference is `localOllama`.

The default model descriptor is `qwen3.5:2b`, unless overridden.

### 7.5 Translation Environment Variables

Most important translation overrides:

- `SPEECHFLOW_OLLAMA_MODEL`
- `SPEECHFLOW_LOCAL_MODEL_ID`
- `SPEECHFLOW_LOCAL_MODEL_NAME`
- `SPEECHFLOW_OLLAMA_BASE_URL`
- `SPEECHFLOW_OLLAMA_TIMEOUT_SECONDS`
- `SPEECHFLOW_OLLAMA_KEEP_ALIVE`
- `SPEECHFLOW_OLLAMA_MAX_TOKENS`
- `SPEECHFLOW_OLLAMA_THINK`

Rule:

- Keep model selection and Ollama endpoint resolution inside translation services, not in views or the coordinator.

## 8. Coordinator Rules

File: [AppCoordinator.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Coordinator/AppCoordinator.swift)

The coordinator is the only layer that should:

- mutate `AppState`
- start, pause, resume, or stop the active session
- request permissions
- react to ASR partial/final events
- trigger commit timing
- decide when a committed segment is sent to translation
- re-render the overlay

Important current behavior:

- Commit timing is optimized for subtitle-style rolling output, not paragraph buffering.
- `silenceTimeout` and `partialStableTimeout` both participate.
- `Pause` cancels translation work and stops the current ASR stream.
- `Stop` tears down capture, ASR, network monitoring, translation, and transcript state.

Do not:

- move app-state transitions into SwiftUI views
- let services directly orchestrate each other
- make translation failure escalate to fatal app termination by itself

## 9. Rendering Model

Files:

- [OverlayRenderModel.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Overlay/OverlayRenderModel.swift)
- [OverlayViewModel.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Overlay/OverlayViewModel.swift)
- [RealOverlayRenderer.swift](/Users/asukabot/Speechflow/Sources/SpeechflowApp/RealOverlayRenderer.swift)

Rules:

- Original lines render committed source segments first, then the active partial line.
- Translated lines render only committed segments that already have `translatedText`.
- UI should reflect the current snapshot, not infer hidden transcript state on its own.

Current implementation detail:

- `RealOverlayRenderer` forwards render updates onto `@MainActor`.

## 10. Developer Entry Points

Useful local entry points:

- Build the app bundle:
  - [build_dev_app_bundle.sh](/Users/asukabot/Speechflow/Scripts/build_dev_app_bundle.sh)

- Run the translation benchmark:
  - [run_local_translation_bench.sh](/Users/asukabot/Speechflow/Scripts/run_local_translation_bench.sh)
  - [main.swift](/Users/asukabot/Speechflow/Sources/LocalTranslationBench/main.swift)

- Troubleshooting guide:
  - [TROUBLESHOOTING.md](/Users/asukabot/Speechflow/Docs/TROUBLESHOOTING.md)

Important runtime caveat:

- First-time permission prompts should be tested through the built `.app`, not raw `swift run`, because `SystemPermissionService` intentionally avoids risky TCC prompts in a non-bundled process.

## 11. Known Incomplete Areas

These are deliberate gaps, not hidden bugs in the interface design:

- `InMemorySettingsStore` is still in use.
- `StubNetworkMonitor` is still in use.
- `TranslationPolicy` naming still reflects an older remote-first design.
- Subtitle segmentation is functional but still being tuned.
- `SpeechflowContainer.makeLiveContainer()` still wires `StubOverlayRenderer`; the app target constructs its own real renderer in `SpeechflowApp`.

## 12. Change Rules for Future Agents

When extending the codebase:

- Add shared event types in [EventModels.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Interfaces/EventModels.swift) first.
- Add shared models in `Models` before inventing ad hoc tuples or dictionaries.
- Keep `AppCoordinator` as the only orchestration owner.
- Preserve `segment.id` as the identity boundary for translation application.
- Keep translation segment-scoped and ordered.
- Keep ASR independent from translation/network degradation.
- Keep capture-source switching behind `AudioEngineServicing`, not in views.

Do not:

- make overlay code mutate transcript state
- make translation operate on the full transcript on every partial update
- bypass `TranslationRouterService` for provider-specific direct calls
- make ASR depend on whether Ollama is up
- let a local model failure crash the original subtitle chain
