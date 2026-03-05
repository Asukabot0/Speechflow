@preconcurrency import AVFoundation
import Foundation

public final class PreferredLocalASRService: LocalASRServicing, @unchecked Sendable {
    private enum ActiveBackend {
        case none
        case primary
        case fallback
    }

    private let primary: LocalASRServicing
    private let fallback: LocalASRServicing
    private let coordinationQueue = DispatchQueue(label: "Speechflow.PreferredLocalASRService")
    private let stateLock = NSLock()
    private var activeBackend: ActiveBackend = .none
    private var downstreamEventSink: ((SpeechflowEvent) -> Void)?

    public init(
        primary: LocalASRServicing,
        fallback: LocalASRServicing
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func updateLocaleIdentifier(_ localeIdentifier: String) {
        primary.updateLocaleIdentifier(localeIdentifier)
        fallback.updateLocaleIdentifier(localeIdentifier)
    }

    public func startStreaming(eventSink: @escaping (SpeechflowEvent) -> Void) throws {
        stopStreaming()
        debugLog("PreferredLocalASRService starting primary ASR backend")

        stateLock.lock()
        downstreamEventSink = eventSink
        activeBackend = .primary
        stateLock.unlock()

        do {
            try primary.startStreaming { [weak self] event in
                self?.handlePrimaryEvent(event)
            }
            return
        } catch {
            stateLock.lock()
            activeBackend = .none
            stateLock.unlock()
            do {
                try startFallback()
            } catch {
                stateLock.lock()
                downstreamEventSink = nil
                stateLock.unlock()
                throw error
            }
        }
    }

    public func stopStreaming() {
        primary.stopStreaming()
        fallback.stopStreaming()
        stateLock.lock()
        activeBackend = .none
        downstreamEventSink = nil
        stateLock.unlock()
    }

    private func handlePrimaryEvent(_ event: SpeechflowEvent) {
        switch event {
        case .localASRFailed(let message):
            debugLog("PreferredLocalASRService primary ASR failed, switching to fallback: \(message)")
            coordinationQueue.async { [weak self] in
                self?.handlePrimaryFailure(message)
            }
        default:
            guard isPrimaryActive else {
                return
            }
            currentEventSink?(event)
        }
    }

    private func handlePrimaryFailure(_ message: String) {
        guard isPrimaryActive else {
            return
        }

        do {
            try startFallback()
            debugLog("PreferredLocalASRService fallback ASR started")
        } catch {
            debugLog("PreferredLocalASRService fallback ASR failed: \(error.localizedDescription)")
            currentEventSink?(
                .localASRFailed(
                    message: "\(message) Fallback to system speech recognition also failed: \(error.localizedDescription)"
                )
            )
        }
    }

    private func startFallback() throws {
        primary.stopStreaming()

        let sink = currentEventSink
        stateLock.lock()
        activeBackend = .fallback
        stateLock.unlock()
        debugLog("PreferredLocalASRService starting fallback ASR backend")
        do {
            try fallback.startStreaming { [weak self] event in
                guard self?.isFallbackActive ?? true else {
                    return
                }
                sink?(event)
            }
        } catch {
            stateLock.lock()
            activeBackend = .none
            stateLock.unlock()
            throw error
        }
    }

    private var currentEventSink: ((SpeechflowEvent) -> Void)? {
        stateLock.lock()
        let sink = downstreamEventSink
        stateLock.unlock()
        return sink
    }

    private var isPrimaryActive: Bool {
        stateLock.lock()
        let isActive = activeBackend == .primary
        stateLock.unlock()
        return isActive
    }

    private var isFallbackActive: Bool {
        stateLock.lock()
        let isActive = activeBackend == .fallback
        stateLock.unlock()
        return isActive
    }
}
