import Foundation
import SpeechflowCore
import SwiftUI

final class RealOverlayRenderer: OverlayRendering, @unchecked Sendable {
    private let originalController: OverlayWindowController
    private let translatedController: OverlayWindowController
    private let assistantController: OverlayWindowController
    private let viewModel: OverlayViewModel
    
    init(
        originalController: OverlayWindowController,
        translatedController: OverlayWindowController,
        assistantController: OverlayWindowController,
        viewModel: OverlayViewModel
    ) {
        self.originalController = originalController
        self.translatedController = translatedController
        self.assistantController = assistantController
        self.viewModel = viewModel
    }
    
    func render(snapshot: OverlayRenderModel) {
        print("[Renderer] render called — original: \(snapshot.originalLines.count) lines, translated: \(snapshot.translatedLines.count) lines, assistant: \(snapshot.assistantLines.count) lines")
        if let first = snapshot.originalLines.first { print("[Renderer] first originalLine: \"\(first.text)\"") }
        let viewModel = viewModel
        Task { @MainActor in
            viewModel.originalLines = snapshot.originalLines
            viewModel.translatedLines = snapshot.translatedLines
            viewModel.assistantLines = snapshot.assistantLines
            viewModel.assistantStatus = snapshot.assistantStatus
            print("[Renderer @MainActor] OverlayViewModel updated — originalLines: \(viewModel.originalLines.count)")
        }
    }
    
    func setVisibility(_ isVisible: Bool) {
        let originalController = originalController
        let translatedController = translatedController
        let assistantController = assistantController
        Task { @MainActor in
            originalController.setVisibility(isVisible)
            translatedController.setVisibility(isVisible)
            assistantController.setVisibility(isVisible)
        }
    }
}
