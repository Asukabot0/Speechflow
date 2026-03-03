# Speechflow Interface Contracts

## 1. Purpose

This document defines the code-level contracts for the current MVP skeleton.

It is intended for AI agents and developers who will continue implementing the project. Treat this file as the implementation companion to the product PRD in [MVP_DEVELOPMENT_PLAN.md](/Users/asukabot/Speechflow/MVP_DEVELOPMENT_PLAN.md).

The goal of this file is to answer:

- Which module owns which responsibility
- Which types are considered shared contracts
- Which state transitions are allowed
- Which extension points are placeholders vs. stable interfaces

## 2. Package Layout

- `Package.swift`
  Declares the `SpeechflowCore` library target.

- `Sources/SpeechflowCore/Models`
  Shared state, translation policy, and data contracts.

- `Sources/SpeechflowCore/Interfaces`
  Service protocols and event definitions.

- `Sources/SpeechflowCore/Coordinator`
  Top-level orchestration and state transitions.

- `Sources/SpeechflowCore/Services`
  Stateful domain services and stub implementations.

- `Sources/SpeechflowCore/Overlay`
  Overlay render contracts and view model shaping.

- `Sources/SpeechflowCore/Settings`
  Settings persistence abstractions and current in-memory implementation.

- `Sources/SpeechflowCore/App`
  Bootstrap wiring for a default dependency graph.

## 3. Shared Contracts

### 3.1 App State

File: [AppState.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Models/AppState.swift)

- `AppState`
  Global coordinator state.

- `AppErrorContext`
  Error payload for recoverable and non-recoverable failures.

Rule:

- Only the coordinator should directly mutate global app state.

### 3.2 Transcript Models

File: [TranscriptModels.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Models/TranscriptModels.swift)

- `SegmentStatus`
  Lifecycle of a single committed unit.

- `CommitReason`
  Why a draft became committed.

- `TranscriptSegment`
  Stable segment record. Once appended, its order must not change.

- `TranscriptSnapshot`
  Read model for render and downstream consumers.

- `TranscriptBufferMutation`
  Result object returned by the transcript buffer after partial or commit updates.

Rules:

- `partialText` represents only the current uncommitted text.
- `committedSegments` are append-only in order.
- Translations are attached by segment `id`, not by index guesswork.

### 3.3 Settings Models

File: [SettingsModels.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Models/SettingsModels.swift)

- `LanguagePair`
- `OverlayScreenMode`
- `OverlayFrame`
- `SpeechflowSettings`

Rules:

- Settings are the source of truth for default behavior.
- Runtime state may diverge temporarily, but persisted defaults should be synchronized through `SettingsStoring`.

### 3.4 Translation Models

File: [TranslationModels.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Models/TranslationModels.swift)

- `NetworkQuality`
- `TranslationBackend`
- `TranslationStrategy`
- `TranslationPolicy`
- `TranslationResult`

Rules:

- ASR is treated as local-first and should not depend on these network states.
- Translation routing is selected from these types.
- `TranslationResult` is the single shared payload for successful translation completion, including degraded fallback paths.

### 3.5 Event Model

File: [EventModels.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Interfaces/EventModels.swift)

- `PermissionSet`
- `SpeechflowEvent`

Rules:

- All user actions and async service callbacks should enter the system as `SpeechflowEvent`.
- New event types should be added here before wiring new feature paths.
- Frontend preference edits should be routed through `settingsUpdated`.

## 4. Service Protocols

File: [ServiceProtocols.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Interfaces/ServiceProtocols.swift)

### 4.1 `AudioEngineServicing`

Responsibilities:

- Start microphone capture
- Forward captured audio buffers to the current downstream consumer
- Pause capture
- Stop and tear down capture

Non-responsibilities:

- ASR
- Translation
- UI updates

Contract:

- The audio service owns the microphone and `AVAudioEngine` lifecycle.
- The audio service exposes captured audio through `setBufferHandler`.
- The audio service must not interpret transcript text.

### 4.2 `LocalASRServicing`

Responsibilities:

- Start local streaming recognition
- Receive microphone audio from the audio engine service
- Support source locale updates
- Emit recognition results through `SpeechflowEvent`
- Stop recognition

Contract:

- The service should emit `.asrPartialReceived` and `.asrFinalReceived`.
- Runtime failures should emit `.localASRFailed`.
- The service should remain functional even when translation routes are degraded or unavailable.

### 4.3 `NetworkMonitoring`

Responsibilities:

- Observe network quality for translation routing
- Emit `.networkQualityChanged`
- Stay independent from ASR and UI rendering

Contract:

- Network quality is advisory input for translation only.
- Loss of network must never pause the ASR chain.

### 4.4 `PermissionServicing`

Responsibilities:

- Request runtime permissions required for MVP startup
- Emit `.permissionsResolved`

Contract:

- MVP startup depends on microphone and speech recognition permission.
- Permission requests should report asynchronously through `SpeechflowEvent`.
- Permission denial should route through coordinator error handling rather than crashing the app.

Current implementations:

- `SystemPermissionService`
- `StubPermissionService`

### 4.5 `TranscriptBuffering`

Responsibilities:

- Track the current partial text
- Commit draft text into stable segments
- Mark translation in-flight
- Attach translation back onto the correct segment
- Reset session-local transcript state

Contract:

- The buffer does not talk to UI directly.
- The buffer does not choose translation providers.

### 4.6 `TranslateServicing`

Responsibilities:

- Accept committed segments
- Apply routing policy
- React to network quality changes
- Preserve ordering semantics
- Emit translation success or failure events

Current placeholder:

- The stub translation service simulates:
  - remote translation when network is good
  - system translation fallback when network is constrained
  - original-only fallback when no translation path is available

Future implementation rule:

- Preserve serial ordering. Do not send parallel writes that can reorder UI output.
- Translation failure is non-fatal to the live session.
- Translation must never block original captions.

### 4.7 `OverlayRendering`

Responsibilities:

- Render the latest overlay read model
- Toggle visibility

Contract:

- This interface consumes `OverlayRenderModel`.
- UI layers should not own transcript truth.

### 4.8 `SettingsStoring`

Responsibilities:

- Load persisted settings
- Save updated settings

Current placeholder:

- In-memory only. Replace with `UserDefaults` later without changing callers.

## 5. Coordinator Rules

File: [AppCoordinator.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Coordinator/AppCoordinator.swift)

The coordinator is the only place that should:

- Mutate `AppState`
- Interpret top-level events
- Decide when to start or stop services
- Decide when a committed segment should be translated
- Apply network quality updates to translation routing
- Trigger overlay re-rendering

Rules:

- Keep business flow centralized here.
- Do not move app-state transitions into UI or service layers.
- Prefer new event handlers over ad hoc cross-module calls.
- Do not escalate the app to fatal error state for translation degradation alone.

## 6. Rendering Model

Files:

- [OverlayRenderModel.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Overlay/OverlayRenderModel.swift)
- [OverlayViewModel.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Overlay/OverlayViewModel.swift)

Rendering rules:

- Original lines render committed source segments first.
- Current partial is appended as a non-committed line.
- Translated lines include only segments with `translatedText`.
- The builder trims both areas to the configured line limit.

Important constraint:

- The current builder generates a fresh UUID for the active partial line. Real UI diffing can replace this with a more stable transient identity later.

## 7. Current Stubs

File: [StubServices.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Services/StubServices.swift)

Available placeholders:

- `StubAudioEngineService`
- `StubASRService`
- `StubNetworkMonitor`
- `StubTranslateService`
- `StubOverlayRenderer`
- `SystemClock`

Why these exist:

- Allow the package to compile now
- Give future agents stable dependency injection points
- Allow unit tests to be added before real framework integration

## 8. Local Recognition Backend

File: [LocalRecognitionServices.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Services/LocalRecognitionServices.swift)

Live implementations now available:

- `SystemAudioEngineService`
- `SpeechFrameworkASRService`

Behavior:

- `SystemAudioEngineService` owns the `AVAudioEngine` input tap and forwards `AVAudioPCMBuffer` frames.
- `SpeechFrameworkASRService` binds to the audio service, creates an `SFSpeechAudioBufferRecognitionRequest`, and emits partial/final ASR events.
- The recognizer is configured for local-first recognition by setting `requiresOnDeviceRecognition = true`.
- The recognizer can update its source locale through `updateLocaleIdentifier`.

## 9. Permission Backend

File: [PermissionServices.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/Services/PermissionServices.swift)

Live implementation:

- `SystemPermissionService`

Behavior:

- Requests microphone access via `AVCaptureDevice.requestAccess(for: .audio)`
- Requests speech authorization via `SFSpeechRecognizer.requestAuthorization`
- Emits a unified `PermissionSet` once the current permission state is known

## 10. Bootstrap Entry Point

File: [SpeechflowContainer.swift](/Users/asukabot/Speechflow/Sources/SpeechflowCore/App/SpeechflowContainer.swift)

`SpeechflowBootstrap.makeDefaultContainer()` provides:

- a default settings store
- a transcript buffer
- a network monitor
- a permission service
- live local recognition services
- a fully wired `AppCoordinator`

Additional factory:

- `SpeechflowBootstrap.makeStubContainer()`
  Keeps the old stub-only wiring for tests and isolated flow checks.

Usage rule:

- Replace the stub services with real implementations through the same constructor path rather than bypassing the container.

## 11. Next Implementation Targets

The next agents should implement features in this order:

1. Replace `InMemorySettingsStore` with `UserDefaults`
2. Replace `StubOverlayRenderer` with a real `NSPanel`-backed renderer
3. Replace `StubNetworkMonitor` with a real reachability or path monitor
4. Replace `StubTranslateService` with a serial translation router:
   remote-first, system fallback, original-only fallback

## 12. Change Rules for Future Agents

When extending this codebase:

- Add new shared event types in `EventModels.swift`
- Add new shared models in `Models` before using ad hoc dictionaries or tuples
- Prefer protocol expansion over direct concrete-type coupling
- Keep `AppCoordinator` as the main orchestration layer
- Preserve append-only ordering of committed transcript segments
- Preserve the rule that only committed segments enter the formal translation path
- Preserve the rule that ASR remains local-first and independent of network quality

Do not:

- Make the overlay renderer mutate transcript state
- Make translation operate on the full transcript each update
- Introduce parallel translation writes without explicit ordering control
- Allow translation failure to interrupt the original subtitle path

## 13. Planned Extension: Dual Capture Sources

The product PRD now includes a new requirement: add a separate system-audio translation mode in addition to the existing microphone mode.

This is a requirements-level direction, not a claim that the current code already supports it.

Planned rules for that extension:

- Keep a single active capture session at a time. The first implementation should not run microphone and system-audio capture concurrently.
- Do not overload the existing microphone capture path with opaque branching.
- Prefer a new shared `AudioCaptureSource` model plus source-aware coordinator logic, or a dedicated `SystemAudioCaptureServicing` protocol that plugs into the same downstream ASR pipeline.
- Treat system-audio capture as a separate startup intent from microphone capture. The current generic `StartRequested` flow should evolve into source-specific start actions.
- On macOS, system-audio capture should be designed around `ScreenCaptureKit` audio output, not private or hidden global audio hooks.
- System-audio mode must have its own permission and failure handling path. Authorization failure for system audio must not break microphone translation mode.
- Reuse the same downstream contracts after audio buffers are obtained: `LocalASRServicing`, `TranscriptBuffering`, `TranslateServicing`, `OverlayRendering`.

Implementation consequence:

- The coordinator remains the place that decides which capture source is active and when to transition between idle, active, paused, and stopped states.
