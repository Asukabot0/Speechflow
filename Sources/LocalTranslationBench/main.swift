import Darwin
import Foundation
import SpeechflowCore

private struct BenchSample {
    let name: String
    let languagePair: LanguagePair
    let text: String
}

private struct BenchConfiguration {
    let descriptor: LocalModelDescriptor
    let samples: [BenchSample]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let assetStore = LocalModelAssetStore(environment: environment)
        self.descriptor = assetStore.preferredLocalModelDescriptor()

        let primaryPair = LanguagePair(
            sourceCode: environment["SPEECHFLOW_BENCH_SOURCE"] ?? "en-US",
            targetCode: environment["SPEECHFLOW_BENCH_TARGET"] ?? "zh-Hans"
        )
        let secondaryPair = LanguagePair(
            sourceCode: environment["SPEECHFLOW_BENCH_SOURCE_WARM"] ?? primaryPair.targetCode,
            targetCode: environment["SPEECHFLOW_BENCH_TARGET_WARM"] ?? primaryPair.sourceCode
        )

        let coldText = environment["SPEECHFLOW_BENCH_TEXT"]
            ?? "Good morning everyone. Let's start the meeting and review today's priorities."
        let warmText = environment["SPEECHFLOW_BENCH_TEXT_WARM"]
            ?? "这个版本先保证稳定，再逐步优化首句延迟。"

        self.samples = [
            BenchSample(name: "cold", languagePair: primaryPair, text: coldText),
            BenchSample(name: "warm", languagePair: secondaryPair, text: warmText)
        ]
    }
}

@main
struct LocalTranslationBench {
    static func main() async {
        let configuration = BenchConfiguration()
        let assetStore = LocalModelAssetStore()
        let installState = assetStore.installState(for: configuration.descriptor)

        print("model_id=\(configuration.descriptor.id)")
        print("model_name=\(configuration.descriptor.modelName)")
        print("ollama_endpoint=\(configuration.descriptor.endpoint)")
        print("runtime_preference=\(configuration.descriptor.runtimePreference.rawValue)")
        print("install_state=\(installState.rawValue)")
        fflush(stdout)

        guard installState == .ready else {
            fputs("Local model is not ready.\n", stderr)
            Foundation.exit(2)
        }

        let promptBuilder = TranslationPromptBuilder()
        let runtime = LocalOllamaRuntime()

        for sample in configuration.samples {
            do {
                let prompt = promptBuilder.makePrompt(
                    for: sample.text,
                    languagePair: sample.languagePair
                )
                let start = ContinuousClock.now
                let output = try await runtime.translate(
                    prompt: prompt,
                    using: configuration.descriptor
                )
                let duration = start.duration(to: .now)
                let seconds = duration.components.seconds
                let attoseconds = duration.components.attoseconds
                let elapsedSeconds = Double(seconds)
                    + Double(attoseconds) / 1_000_000_000_000_000_000
                let charCount = output.count
                let charsPerSecond = elapsedSeconds > 0
                    ? Double(charCount) / elapsedSeconds
                    : 0

                print("=== \(sample.name) ===")
                print("source_pair=\(sample.languagePair.sourceCode)->\(sample.languagePair.targetCode)")
                print("elapsed_seconds=\(String(format: "%.3f", elapsedSeconds))")
                print("output_chars=\(charCount)")
                print("chars_per_second=\(String(format: "%.2f", charsPerSecond))")
                print("output=\(output)")
                fflush(stdout)
            } catch {
                fputs("=== \(sample.name) FAILED ===\n", stderr)
                fputs("\(error.localizedDescription)\n", stderr)
                await runtime.unloadModel()
                Foundation.exit(1)
            }
        }

        await runtime.unloadModel()
    }
}
