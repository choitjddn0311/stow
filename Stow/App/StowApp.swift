import AppKit
import Sparkle
import SwiftUI

@main
struct StowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var coordinator: AppCoordinator
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
        let coordinator: AppCoordinator
        let engineUpdates: EngineUpdateCoordinator?
        do {
            let bundled = try EngineLocator.bundled()
            // 앱 안에서 yt-dlp를 업데이트하면 source가 바뀌고, 다음 추출부터 새 엔진을 쓴다.
            let source = EngineSource(bundled)
            var client = YtDlpClient(engine: bundled)
            client.engineSource = source
            // 추출은 대기열이 한 번에 하나씩 한다. 화면(ViewModel)은 불러오기와 대기열에 추가를 맡는다.
            let queue = ExtractQueue(engine: client, notifier: SystemCompletionNotifier())
            // 빠른 추출 패널은 자기 화면 모델을 따로 갖고, 대기열·설정은 메인 창과 같이 쓴다.
            let panelModel = QuickPanelModel(
                extract: ExtractViewModel(settings: settings, engine: client, queue: queue),
                clipboard: SystemClipboard()
            )
            coordinator = AppCoordinator(
                settings: settings,
                mainModel: ExtractViewModel(settings: settings, engine: client, queue: queue),
                panelModel: panelModel
            )
            engineUpdates = EngineUpdateCoordinator(
                updater: EngineUpdater(storage: EngineUpdater.defaultStorage(), python: bundled.python),
                source: source,
                bundled: bundled
            )
            engineError = nil
        } catch {
            coordinator = AppCoordinator(settings: settings, mainModel: nil, panelModel: nil)
            engineUpdates = nil
            engineError = error
        }
        if !Self.isTestHost { coordinator.registerGlobalShortcut() }
        _coordinator = State(initialValue: coordinator)
        _engineUpdates = State(initialValue: engineUpdates)
        // 창은 시작할 때 열리지 않을 수도 있으므로(닫은 채 종료하면 복원되지 않음), 종료 처리와 엔진 업데이트는
        // 창이 아니라 앱 시작에 연결한다.
        AppDelegate.queue = coordinator.queue
        let startUpdaters = !Self.updatersDisabled
        AppDelegate.onLaunch = { if startUpdaters { engineUpdates?.start() } }
    }

    var body: some Scene {
        // 창은 하나뿐이다(메뉴 막대·패널에서 "창 열기"가 새 창을 만들지 않고 이 창을 연다).
        Window("Stow", id: AppCoordinator.mainWindowID) {
            RootView(model: coordinator.mainModel, settings: settings, engineError: engineError)
                .modifier(OpenMainWindowBinder(coordinator: coordinator))
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

        Settings {
            SettingsView()
        }

        // 창을 닫아도 앱은 메뉴 막대에 남아 빠른 추출 단축키가 동작한다(사용자 결정 2026-11-14).
        MenuBarExtra {
            MenuBarMenu(coordinator: coordinator)
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("Stow")
                .modifier(OpenMainWindowBinder(coordinator: coordinator))
        }
    }

    /// 테스트 호스트로 실행 중(전역 단축키를 등록하지 않는다)
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// 업데이터(Sparkle·엔진 업데이트)를 켜지 않는 실행: 테스트 호스트, 또는 STOW_DISABLE_UPDATERS=1
    /// (release.sh가 배포 전 앱을 실행해 볼 때 실제 설정·엔진 저장소를 건드리지 않도록).
    private static var updatersDisabled: Bool {
        isTestHost || ProcessInfo.processInfo.environment["STOW_DISABLE_UPDATERS"] == "1"
    }
}

/// SwiftUI 환경의 `openWindow`를 코디네이터에 연결한다. 단축키·패널처럼 SwiftUI 밖에서 메인 창을 열 때 쓴다.
/// 메뉴 막대 아이콘은 앱 시작부터 있으므로, 메인 창을 닫은 뒤에도 연결이 남는다.
private struct OpenMainWindowBinder: ViewModifier {
    let coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let openWindow = openWindow
            coordinator.openMainWindowAction = { openWindow(id: AppCoordinator.mainWindowID) }
        }
    }
}

/// 앱 종료 처리. 추출 중에 종료하면 엔진 프로세스(yt-dlp, ffmpeg, deno)를 먼저 끝내고 작업 폴더를 정리한다.
/// 엔진은 별도 프로세스 그룹에서 돌기 때문에 앱만 끝나면 남는다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 종료할 때 진행 중인 추출을 정리할 대기열(앱 시작 전에 `StowApp`이 넣는다)
    static var queue: ExtractQueue?
    /// 앱이 시작되면 한 번 부른다(엔진 업데이트 시작). 테스트 호스트·배포 전 확인 때는 업데이트를 켜지 않는다.
    static var onLaunch: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.onLaunch?()
        Self.onLaunch = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let queue = Self.queue, queue.isRunning else { return .terminateNow }
        Task {
            await queue.cancelAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 창을 닫아도 앱은 메뉴 막대에 남는다(빠른 추출 단축키, 사용자 결정 2026-11-14). 종료는 ⌘Q나 메뉴 막대 메뉴로.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
