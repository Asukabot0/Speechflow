import SwiftUI
import AVFoundation
import Speech
import SpeechflowCore

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    
    @State private var micAuthorized = false
    @State private var speechAuthorized = false
    @State private var permissionNotice: String?
    
    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            
            permissionsTab
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
        }
        .padding()
        .frame(width: 470, height: 560)
        .onAppear {
            checkPermissions()
        }
    }
    
    private var generalTab: some View {
        Form {
            Section(header: Text("Overlay Appearance").font(.headline)) {
                HStack {
                    Text("Font Size:")
                    Slider(
                        value: Binding(
                            get: { viewModel.settings.fontSize },
                            set: { newValue in
                                var newSettings = viewModel.settings
                                newSettings.fontSize = newValue
                                viewModel.updateSettings(newSettings)
                            }
                        ),
                        in: 12...48,
                        step: 1
                    )
                    Text("\(Int(viewModel.settings.fontSize)) pt")
                        .frame(width: 40, alignment: .trailing)
                }
                
                HStack {
                    Text("Opacity:")
                    Slider(
                        value: Binding(
                            get: { viewModel.settings.opacity },
                            set: { newValue in
                                var newSettings = viewModel.settings
                                newSettings.opacity = newValue
                                viewModel.updateSettings(newSettings)
                            }
                        ),
                        in: 0.1...1.0,
                        step: 0.05
                    )
                    Text(String(format: "%.0f%%", viewModel.settings.opacity * 100))
                        .frame(width: 40, alignment: .trailing)
                }
                
                Stepper(value: Binding(
                    get: { viewModel.settings.maxVisibleLines },
                    set: { newValue in
                        var newSettings = viewModel.settings
                        newSettings.maxVisibleLines = newValue
                        viewModel.updateSettings(newSettings)
                    }
                ), in: 1...20) {
                    Text("Max Visible Lines: \(viewModel.settings.maxVisibleLines)")
                }
                
                ColorPicker("Input Background Color", selection: Binding(
                    get: { viewModel.settings.sourceBackgroundColor.suColor },
                    set: { viewModel.updateSourceBackgroundColor($0) }
                ))
                
                ColorPicker("Output Background Color", selection: Binding(
                    get: { viewModel.settings.targetBackgroundColor.suColor },
                    set: { viewModel.updateTargetBackgroundColor($0) }
                ))
                
                ColorPicker("Input Text Color", selection: Binding(
                    get: { viewModel.settings.sourceTextColor.suColor },
                    set: { viewModel.updateSourceTextColor($0) }
                ))
                
                ColorPicker("Output Text Color", selection: Binding(
                    get: { viewModel.settings.targetTextColor.suColor },
                    set: { viewModel.updateTargetTextColor($0) }
                ))
            }
            
            Divider().padding(.vertical, 8)

            Section(header: Text("Languages").font(.headline)) {
                Picker("Input Language", selection: Binding(
                    get: { viewModel.settings.languagePair.sourceCode },
                    set: { viewModel.updateSourceLanguage($0) }
                )) {
                    ForEach(SupportedLanguages.inputOptions(including: viewModel.settings.languagePair.sourceCode)) { option in
                        Text(option.name).tag(option.code)
                    }
                }

                Picker("Output Language", selection: Binding(
                    get: { viewModel.settings.languagePair.targetCode },
                    set: { viewModel.updateTargetLanguage($0) }
                )) {
                    ForEach(SupportedLanguages.outputOptions(including: viewModel.settings.languagePair.targetCode)) { option in
                        Text(option.name).tag(option.code)
                    }
                }
            }

            Divider().padding(.vertical, 8)

            Section(header: Text("Speech Recognition").font(.headline)) {
                HStack {
                    Text("Input Gain:")
                    Slider(
                        value: Binding(
                            get: { viewModel.settings.recognitionTuning.inputGain },
                            set: { viewModel.updateRecognitionInputGain($0) }
                        ),
                        in: 0.5...4.0,
                        step: 0.1
                    )
                    Text(String(format: "%.1fx", viewModel.settings.recognitionTuning.inputGain))
                        .frame(width: 48, alignment: .trailing)
                }

                Toggle(
                    "Noise Reduction and Voice Processing",
                    isOn: Binding(
                        get: { viewModel.settings.recognitionTuning.voiceProcessingEnabled },
                        set: { viewModel.setVoiceProcessingEnabled($0) }
                    )
                )

                Toggle(
                    "Automatic Gain Control",
                    isOn: Binding(
                        get: { viewModel.settings.recognitionTuning.automaticGainControlEnabled },
                        set: { viewModel.setAutomaticGainControlEnabled($0) }
                    )
                )
                .disabled(!viewModel.settings.recognitionTuning.voiceProcessingEnabled)

                HStack {
                    Text("Pause Detection:")
                    Slider(
                        value: Binding(
                            get: { viewModel.settings.recognitionTuning.pauseCommitDelay },
                            set: { viewModel.updatePauseCommitDelay($0) }
                        ),
                        in: 0.6...2.2,
                        step: 0.05
                    )
                    Text(String(format: "%.2fs", viewModel.settings.recognitionTuning.pauseCommitDelay))
                        .frame(width: 50, alignment: .trailing)
                }

                Text("Lower pause detection values react faster but may split sentences too early.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 8)
            
            Section(header: Text("Defaults").font(.headline)) {
                Toggle("Show Overlay by Default", isOn: Binding(
                    get: { viewModel.settings.overlayVisibleByDefault },
                    set: { newValue in
                        var newSettings = viewModel.settings
                        newSettings.overlayVisibleByDefault = newValue
                        viewModel.updateSettings(newSettings)
                    }
                ))
                
                Toggle("Enable Translation by Default", isOn: Binding(
                    get: { viewModel.settings.translationEnabledByDefault },
                    set: { newValue in
                        var newSettings = viewModel.settings
                        newSettings.translationEnabledByDefault = newValue
                        viewModel.updateSettings(newSettings)
                    }
                ))
            }
        }
        .padding()
    }
    
    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Speechflow requires access to your microphone and speech recognition services to function properly.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                permissionRow(
                    title: "Microphone",
                    description: "Required to hear your voice.",
                    isAuthorized: micAuthorized,
                    action: handleMicrophonePermissionAction
                )
                
                Divider()
                
                permissionRow(
                    title: "Speech Recognition",
                    description: "Required to transcribe your voice locally.",
                    isAuthorized: speechAuthorized,
                    action: handleSpeechPermissionAction
                )
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)

            if let permissionNotice {
                Text(permissionNotice)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            Spacer()
        }
        .padding()
    }
    
    private func permissionRow(title: String, description: String, isAuthorized: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            
            if isAuthorized {
                Label("Authorized", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Request Access") {
                    action()
                }
            }
        }
    }
    
    private func checkPermissions() {
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    
    private func handleMicrophonePermissionAction() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micAuthorized = true
            permissionNotice = nil
        case .notDetermined:
            permissionNotice = "Use Start from the menu to trigger the initial microphone permission prompt safely."
        case .denied, .restricted:
            permissionNotice = "Microphone access was previously denied. Open System Settings to enable it."
            openSystemSettingsPrivacyPane(anchor: "Privacy_Microphone")
        @unknown default:
            permissionNotice = "Unable to determine microphone permission state."
        }
    }
    
    private func handleSpeechPermissionAction() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechAuthorized = true
            permissionNotice = nil
        case .notDetermined:
            permissionNotice = "Use Start from the menu to trigger the initial speech recognition prompt safely."
        case .denied, .restricted:
            permissionNotice = "Speech recognition access was previously denied. Open System Settings to enable it."
            openSystemSettingsPrivacyPane(anchor: "Privacy_SpeechRecognition")
        @unknown default:
            permissionNotice = "Unable to determine speech recognition permission state."
        }
    }

    private func openSystemSettingsPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
