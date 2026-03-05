import SwiftUI
import AppKit
import SpeechflowCore

#if canImport(Translation)
@preconcurrency import Translation
#endif

@MainActor
final class OverlayWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var appViewModel: AppViewModel?
    
    @Published var isVisible: Bool = true {
        didSet {
            updateVisibility()
        }
    }
    
    private let viewModel: OverlayViewModel
    private let subtitleType: SubtitleType

    init(viewModel: OverlayViewModel, subtitleType: SubtitleType) {
        self.viewModel = viewModel
        self.subtitleType = subtitleType
        super.init()
        setupWindow()
    }
    
    private func setupWindow() {
        let initialY: CGFloat
        switch subtitleType {
        case .original:
            initialY = 100
        case .translated:
            initialY = 250
        case .assistant:
            initialY = 400
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: initialY, width: 800, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        
        self.window = panel
        
        // Setup initial view
        let view = OverlayRootView(controller: self, overlayViewModel: viewModel, subtitleType: subtitleType)
        let hosting = NSHostingController(rootView: AnyView(view))
        panel.contentViewController = hosting
        self.hostingController = hosting
        
        if isVisible {
            panel.orderFront(nil)
        }
    }
    
    func setupTranslationEnvironment(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
        
        // Rebuild root view so subtitle styling reacts to the app view model.
        let view = OverlayRootView(
            controller: self,
            overlayViewModel: viewModel,
            appViewModel: appViewModel,
            subtitleType: subtitleType
        )
        hostingController?.rootView = AnyView(view)
    }
    
    private var dragStartFrame: NSRect?
    
    func startResizing() {
        dragStartFrame = window?.frame
    }
    
    func resizeWindow(translation: CGSize) {
        guard let window = self.window, let startFrame = dragStartFrame else { return }
        
        let newWidth = max(400, startFrame.width + translation.width)
        let newHeight = max(120, startFrame.height + translation.height)
        
        let newMinY = startFrame.maxY - newHeight
        
        let newFrame = NSRect(
            x: startFrame.minX,
            y: newMinY,
            width: newWidth,
            height: newHeight
        )
        window.setFrame(newFrame, display: true)
    }
    
    func endResizing() {
        dragStartFrame = nil
    }
    
    func render(snapshot: Any) {
        // The real renderer will inject data directly into OverlayView or a ViewModel
        // For MVP simplicity, we will let RealOverlayRenderer update a shared observable model.
    }
    
    func setVisibility(_ isVisible: Bool) {
        self.isVisible = isVisible
    }
    
    private func updateVisibility() {
        if isVisible {
            window?.orderFront(nil)
        } else {
            window?.orderOut(nil)
        }
    }
}

// OverlayRootView: just shows subtitle content.
// NOTE: .translationTask is NOT here — it lives exclusively in TranslationWorkerWindowController
// (an invisible off-screen window) so there is exactly one processQueue consumer at a time.
struct OverlayRootView: View {
    @ObservedObject var controller: OverlayWindowController
    @ObservedObject var overlayViewModel: OverlayViewModel
    var appViewModel: AppViewModel?
    var subtitleType: SubtitleType?

    var body: some View {
        Group {
            if let type = subtitleType {
                SubtitleWindowView(controller: controller, appViewModel: appViewModel, type: type)
                    .environmentObject(overlayViewModel)
            } else {
                Text("Error: SubtitleType missing")
            }
        }
    }
}
