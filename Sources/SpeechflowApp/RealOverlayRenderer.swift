import Foundation
import SpeechflowCore
import SwiftUI

final class RealOverlayRenderer: OverlayRendering, @unchecked Sendable {
    private let originalController: OverlayWindowController
    private let translatedController: OverlayWindowController
    private let viewModel: OverlayViewModel
    
    init(originalController: OverlayWindowController, translatedController: OverlayWindowController, viewModel: OverlayViewModel) {
        self.originalController = originalController
        self.translatedController = translatedController
        self.viewModel = viewModel
    }
    
    func render(snapshot: OverlayRenderModel) {
        print("[Renderer] render called — original: \(snapshot.originalLines.count) lines, translated: \(snapshot.translatedLines.count) lines")
        if let first = snapshot.originalLines.first { print("[Renderer] first originalLine: \"\(first.text)\"") }
        let viewModel = viewModel
        Task { @MainActor in
            viewModel.originalLines = snapshot.originalLines
            viewModel.translatedLines = snapshot.translatedLines
            print("[Renderer @MainActor] OverlayViewModel updated — originalLines: \(viewModel.originalLines.count)")
        }
    }
    
    func setVisibility(_ isVisible: Bool) {
        let originalController = originalController
        let translatedController = translatedController
        Task { @MainActor in
            originalController.setVisibility(isVisible)
            translatedController.setVisibility(isVisible)
        }
    }
}
