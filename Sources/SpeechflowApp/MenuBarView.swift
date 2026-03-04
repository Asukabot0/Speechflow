import SwiftUI
import SpeechflowCore

#if canImport(Translation)
import Translation
#endif

struct MenuBarView: View {
    @ObservedObject var viewModel: AppViewModel
    
    var body: some View {
        mainContent
    }
    
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            controlsView
            Divider()
            settingsView
            Divider()
            footerView
        }
        .padding()
        .frame(width: 320)
    }

    private var headerView: some View {
        HStack {
            Text("Speechflow")
                .font(.headline)
            Spacer()
            statusBadge
        }
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        let (color, text) = statusProperties
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var statusProperties: (Color, String) {
        switch viewModel.state {
        case .idle: return (.gray, "Idle")
        case .listening:
            return (.green, viewModel.activeInputSource?.displayName ?? "Live")
        case .paused:
            return (.orange, viewModel.activeInputSource?.displayName ?? "Paused")
        case .error: return (.red, "Error")
        }
    }

    private var errorMessage: String? {
        guard case .error(let context) = viewModel.state else {
            return nil
        }

        return context.message
    }
    
    @ViewBuilder
    private var controlsView: some View {
        switch viewModel.state {
        case .idle, .error:
            VStack(spacing: 10) {
                Button(action: { viewModel.startMicrophoneTranslation() }) {
                    Label("Translate Microphone", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: { viewModel.startSystemAudioTranslation() }) {
                    Label("Translate System Audio", systemImage: "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        case .listening:
            HStack(spacing: 20) {
                Button(action: { viewModel.pause() }) {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                
                Button(action: { viewModel.stop() }) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        case .paused:
            HStack(spacing: 20) {
                Button(action: { viewModel.resume() }) {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                
                Button(action: { viewModel.stop() }) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable Translation", isOn: Binding(
                get: { viewModel.settings.translationEnabledByDefault },
                set: { viewModel.toggleTranslation(isEnabled: $0) }
            ))
            
            Toggle("Show Overlay", isOn: Binding(
                get: { viewModel.settings.overlayVisibleByDefault },
                set: { viewModel.toggleOverlay(isVisible: $0) }
            ))
            
            HStack {
                Text("Input:")
                Spacer()
                Picker("Input", selection: Binding(
                    get: { viewModel.settings.languagePair.sourceCode },
                    set: { viewModel.updateSourceLanguage($0) }
                )) {
                    ForEach(SupportedLanguages.inputOptions(including: viewModel.settings.languagePair.sourceCode)) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 165)
            }
            .font(.caption)
            
            HStack {
                Text("Output:")
                Spacer()
                Picker("Output", selection: Binding(
                    get: { viewModel.settings.languagePair.targetCode },
                    set: { viewModel.updateTargetLanguage($0) }
                )) {
                    ForEach(SupportedLanguages.outputOptions(including: viewModel.settings.languagePair.targetCode)) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 165)
            }
            .font(.caption)
        }
    }

    private var footerView: some View {
        HStack {
            Button("Preferences...") {
                SettingsWindowManager.shared.showSettings(viewModel: viewModel)
            }
            .keyboardShortcut(",", modifiers: .command)
            
            Spacer()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.top, 4)
    }
}
