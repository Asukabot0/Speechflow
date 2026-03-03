import AppKit

#if canImport(Translation)
import SwiftUI
import SpeechflowCore
@preconcurrency import Translation

@MainActor
final class TranslationWorkerWindowController: NSObject {
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?

    init(nativeTranslationService: NativeTranslationService) {
        super.init()
        setupWindow(nativeTranslationService: nativeTranslationService)
    }

    private func setupWindow(nativeTranslationService: NativeTranslationService) {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle]

        let rootView = TranslationWorkerRootView(nativeTranslationService: nativeTranslationService)
        let hostingController = NSHostingController(rootView: AnyView(rootView))
        window.contentViewController = hostingController

        self.window = window
        self.hostingController = hostingController

        // Order the window so SwiftUI mounts the view tree, but keep it effectively invisible.
        window.orderFront(nil)
        window.orderBack(nil)
    }
}

@available(macOS 15.0, *)
private struct TranslationWorkerRootView: View {
    @ObservedObject var nativeTranslationService: NativeTranslationService

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(nativeTranslationService.configuration) { session in
                await nativeTranslationService.processQueue(with: session)
            }
    }
}
#endif
