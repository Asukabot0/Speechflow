import SwiftUI
import SpeechflowCore

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var originalLines: [OverlayLine] = []
    @Published var translatedLines: [OverlayLine] = []
}

enum SubtitleType {
    case original
    case translated
}

struct SubtitleWindowView: View {
    @ObservedObject var controller: OverlayWindowController
    @EnvironmentObject var viewModel: OverlayViewModel
    var appViewModel: AppViewModel?
    let type: SubtitleType
    
    // Derived settings
    private var settings: SpeechflowSettings {
        appViewModel?.settings ?? .defaultValue
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                // Background Layer covers entire geometry
                backgroundLayer
                    .edgesIgnoringSafeArea(.all)
                
                // Texts Layer
                VStack(alignment: .leading, spacing: 10) {
                    contentLayer
                }
                .padding()
                // Constrain the text block boundaries to the geometry bounds without expanding
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                .clipped()
                
                // Resize Handle Layer
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.3))
                            .padding(24)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        if value.translation == .zero {
                                            controller.startResizing()
                                        } else {
                                            controller.resizeWindow(translation: value.translation)
                                        }
                                    }
                                    .onEnded { _ in
                                        controller.endResizing()
                                    }
                            )
                            .onHover { isHovering in
                                if isHovering {
                                    NSCursor.crosshair.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .frame(minWidth: 400, minHeight: 120)
        .cornerRadius(12)
        .clipped()
    }
    
    @ViewBuilder
    private var backgroundLayer: some View {
        switch type {
        case .original:
            settings.sourceBackgroundColor.suColor.opacity(settings.opacity)
        case .translated:
            settings.targetBackgroundColor.suColor.opacity(settings.opacity)
        }
    }
    
    @ViewBuilder
    private var contentLayer: some View {
        switch type {
        case .original:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.originalLines, id: \.id) { line in
                    subtitleText(
                        line.text,
                        font: .system(size: settings.fontSize, weight: .bold, design: .default),
                        color: settings.sourceTextColor.suColor,
                        opacity: line.isCommitted ? 1.0 : 0.7
                    )
                    .animation(.easeInOut(duration: 0.2), value: line.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .translated:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.translatedLines, id: \.id) { line in
                    subtitleText(
                        line.text,
                        font: .system(size: max(10, settings.fontSize - 2), weight: .semibold, design: .default),
                        color: settings.targetTextColor.suColor,
                        opacity: line.isCommitted ? 1.0 : 0.7
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func subtitleText(
        _ text: String,
        font: Font,
        color: Color,
        opacity: Double
    ) -> some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
            .opacity(opacity)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
