import AppKit
import SwiftUI

@main
struct StowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 600, height: 540)
        .windowResizability(.contentMinSize)
    }
}

/// 앱 종료 처리. 추출 중에 종료하면 엔진 프로세스(yt-dlp, ffmpeg, deno)를 먼저 끝내고 작업 폴더를 정리한다.
/// 엔진은 별도 프로세스 그룹에서 돌기 때문에 앱만 끝나면 남는다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: ExtractViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        Task {
            await model.cancelAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 창을 닫으면 앱도 끝낸다(창이 하나뿐인 앱). 이때도 위의 종료 처리를 거친다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
