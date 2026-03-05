import SwiftUI
import SpeechflowCore

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var originalLines: [OverlayLine] = []
    @Published var translatedLines: [OverlayLine] = []
    @Published var assistantLines: [OverlayLine] = []
    @Published var assistantStatus: AssistantResponseStatus = .idle
}

enum SubtitleType {
    case original
    case translated
    case assistant
}

struct SubtitleWindowView: View {
    private static let assistantSummaryPrefix = "__assistant_summary__:"
    private static let originalScrollAnchor = "original-scroll-anchor"
    private static let translatedScrollAnchor = "translated-scroll-anchor"
    private static let assistantScrollAnchor = "assistant-scroll-anchor"

    private struct AssistantBubble: Identifiable {
        let id: String
        let label: String
        let summary: String?
        let body: String
    }

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
                    sectionBadge
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
        case .assistant:
            settings.targetBackgroundColor.suColor.opacity(min(1.0, settings.opacity + 0.06))
        }
    }

    private var badgeTitle: String {
        switch type {
        case .original:
            return "Original"
        case .translated:
            return "Translation"
        case .assistant:
            return "Assistant | \(assistantStatusLabel)"
        }
    }

    private var badgeColor: Color {
        switch type {
        case .original:
            return settings.sourceTextColor.suColor
        case .translated:
            return settings.targetTextColor.suColor
        case .assistant:
            return assistantStatusColor
        }
    }

    private var assistantStatusLabel: String {
        switch viewModel.assistantStatus {
        case .idle:
            return "Idle"
        case .asking:
            return "Asking"
        case .answered:
            return "Answered"
        case .noQuestion:
            return "No Question"
        case .unavailable:
            return "Unavailable"
        }
    }

    private var assistantStatusColor: Color {
        switch viewModel.assistantStatus {
        case .idle:
            return .white.opacity(0.85)
        case .asking:
            return .orange
        case .answered:
            return .green
        case .noQuestion:
            return .white.opacity(0.85)
        case .unavailable:
            return .red
        }
    }

    private var sectionBadge: some View {
        Text(badgeTitle)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(badgeColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.28))
            )
    }

    private var assistantBubbles: [AssistantBubble] {
        var bubbles: [AssistantBubble] = []
        var currentLabel: String?
        var currentSummary: String?
        var currentBodyLines: [String] = []

        func flushCurrentBubble() {
            guard let currentLabel else {
                return
            }

            let body = currentBodyLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                return
            }

            bubbles.append(
                AssistantBubble(
                    id: currentLabel,
                    label: currentLabel,
                    summary: currentSummary,
                    body: body
                )
            )
        }

        for line in viewModel.assistantLines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if isAssistantQuestionLabel(trimmed) {
                flushCurrentBubble()
                currentLabel = trimmed
                currentSummary = nil
                currentBodyLines = []
                continue
            }

            if trimmed.hasPrefix(Self.assistantSummaryPrefix) {
                let summary = String(trimmed.dropFirst(Self.assistantSummaryPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentSummary = summary.isEmpty ? nil : summary
                continue
            }

            if currentLabel == nil {
                currentLabel = "Q\(bubbles.count + 1)"
            }
            currentBodyLines.append(trimmed)
        }

        flushCurrentBubble()
        return bubbles
    }

    private func isAssistantQuestionLabel(_ text: String) -> Bool {
        guard text.hasPrefix("Q"), text.count > 1 else {
            return false
        }
        return text.dropFirst().allSatisfy(\.isNumber)
    }

    private func scrollingLineList(
        lines: [OverlayLine],
        anchorID: String,
        font: Font,
        color: Color
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(lines, id: \.id) { line in
                        subtitleText(
                            line.text,
                            font: font,
                            color: color,
                            opacity: line.isCommitted ? 1.0 : 0.7
                        )
                        .animation(.easeInOut(duration: 0.2), value: line.text)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(anchorID)
                }
            }
            .onAppear {
                scrollToBottom(proxy: proxy, anchorID: anchorID)
            }
            .onChange(of: lines.last?.id) {
                scrollToBottom(proxy: proxy, anchorID: anchorID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, anchorID: String) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(anchorID, anchor: .bottom)
            }
        }
    }
    
    @ViewBuilder
    private var contentLayer: some View {
        switch type {
        case .original:
            scrollingLineList(
                lines: viewModel.originalLines,
                anchorID: Self.originalScrollAnchor,
                font: .system(size: settings.fontSize, weight: .bold, design: .default),
                color: settings.sourceTextColor.suColor
            )
        case .translated:
            scrollingLineList(
                lines: viewModel.translatedLines,
                anchorID: Self.translatedScrollAnchor,
                font: .system(size: max(10, settings.fontSize - 2), weight: .semibold, design: .default),
                color: settings.targetTextColor.suColor
            )

        case .assistant:
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(assistantBubbles) { bubble in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bubble.label)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(settings.targetTextColor.suColor.opacity(0.95))
                                if let summary = bubble.summary, !summary.isEmpty {
                                    Text("Question: \(summary)")
                                        .font(.system(size: max(9, settings.fontSize - 7), weight: .semibold, design: .default))
                                        .foregroundColor(settings.targetTextColor.suColor.opacity(0.75))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                subtitleText(
                                    bubble.body,
                                    font: .system(size: max(10, settings.fontSize - 3), weight: .medium, design: .default),
                                    color: settings.targetTextColor.suColor,
                                    opacity: 1.0
                                )
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.black.opacity(0.24))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(settings.targetTextColor.suColor.opacity(0.18), lineWidth: 1)
                            )
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.assistantScrollAnchor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    scrollToBottom(proxy: proxy, anchorID: Self.assistantScrollAnchor)
                }
                .onChange(of: assistantBubbles.last?.id) {
                    scrollToBottom(proxy: proxy, anchorID: Self.assistantScrollAnchor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
