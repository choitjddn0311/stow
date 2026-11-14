import SwiftUI

@main
struct StowApp: App {
    @State private var settings: AppSettings
    @State private var model: ExtractViewModel?
    private let engineError: EngineError?

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        do {
            let engine = YtDlpClient(engine: try EngineLocator.bundled())
            _model = State(initialValue: ExtractViewModel(
                settings: settings, engine: engine, notifier: SystemCompletionNotifier()
            ))
            engineError = nil
        } catch {
            _model = State(initialValue: nil)
            engineError = error
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, settings: settings, engineError: engineError)
        }
        .defaultSize(width: 600, height: 540)
        .windowResizability(.contentMinSize)
    }
}
