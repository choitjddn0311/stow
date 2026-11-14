import AppKit
import Sparkle
import SwiftUI

@main
struct StowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var model: ExtractViewModel?
    @State private var engineUpdates: EngineUpdateCoordinator?
    private let engineError: EngineError?
    /// Sparkle 앱 자동 업데이트(하루 한 번 확인 후 설치 여부를 묻는다. 설정은 Config/Stow-Info.plist).
    /// 테스트 호스트나 배포 전 실행 확인(release.sh) 때는 시작하지 않는다.
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !Self.updatersDisabled, updaterDelegate: nil, userDriverDelegate: nil
        )
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
                    // 테스트 호스트나 배포 전 실행 확인 때는 네트워크로 엔진을 받지 않는다.
                    if !Self.updatersDisabled { engineUpdates?.start() }
                }
        }
        .defaultSize(width: 600, height: 540)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
                Divider()
                Button("엔진 업데이트 확인…") { engineUpdates?.checkNow() }
                    .disabled(engineUpdates == nil)
                Button("앱에 들어 있는 엔진으로 되돌리기") { engineUpdates?.revertToBundled() }
                    .disabled(engineUpdates == nil)
            }
        }
    }

    /// 업데이터(Sparkle·엔진 업데이트)를 켜지 않는 실행: 테스트 호스트, 또는 STOW_DISABLE_UPDATERS=1
    /// (release.sh가 배포 전 앱을 실행해 볼 때 실제 설정·엔진 저장소를 건드리지 않도록).
    private static var updatersDisabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["STOW_DISABLE_UPDATERS"] == "1"
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
