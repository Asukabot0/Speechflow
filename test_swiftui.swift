import SwiftUI
import Translation

@available(macOS 15.0, *)
struct TestView: View {
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Text("Hello")
            .translationTask(config) { session in
                do {
                    let response = try await session.translate("Hello world")
                    print(response.targetText)
                } catch {
                    print(error)
                }
            }
    }
}
