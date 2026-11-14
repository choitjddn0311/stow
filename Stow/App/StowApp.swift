import AppKit
import SwiftUI

@main
struct StowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var model: ExtractViewModel?
    @State private var engineUpdates: EngineUpdateCoordinator?
    private let engineError: EngineError?

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        do {
            let bundled = try EngineLocator.bundled()
            // 앱 안에서 yt-dlp를 업데이트하면 source가 바뀌고, 다음 추출부터 새 엔진을 쓴다.
            let source = EngineSource(bundled)
            var client = YtDlpClient(engine: bundled)
            client.engineSource = source
            _model = State(initialValue: ExtractViewModel(
                settings: settings, engine: client, notifier: SystemCompletionNotifier()
            ))
            _engineUpdates = State(initialValue: EngineUpdateCoordinator(
                updater: EngineUpdater(storage: EngineUpdater.defaultStorage(), python: bundled.python),
                source: source,
                bundled: bundled
            ))
            engineError = nil
        } catch {
            _model = State(initialValue: nil)
            _engineUpdates = State(initialValue: nil)
            engineError = error
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, settings: settings, engineError: engineError)
                .onAppear {
                    appDelegate.model = model
                    // 테스트 호스트로 실행될 때는 네트워크로 엔진을 받지 않는다.
                    if !Self.isRunningTests { engineUpdates?.start() }
                }
        }
        .defaultSize(width: 600, height: 540)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("엔진 업데이트 확인…") { engineUpdates?.checkNow() }
                    .disabled(engineUpdates == nil)
            }
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
