import AppKit
import Foundation

/// 앱 안 엔진(yt-dlp) 업데이트 흐름(사용자 결정 2026-11-14: 자동 확인 + 자동 설치, stable 채널).
///
/// - 앱 시작: 받아 둔 버전이 번들 버전보다 새로우면 그것을 쓰고, 쓰지 않는 옛 버전을 지운다.
/// - 하루에 한 번 자동으로 확인해, 새 버전이 있으면 조용히 받아 검증·설치한다. 다음 추출부터 쓴다.
/// - 메뉴 "엔진 업데이트 확인…": 바로 확인하고 결과를 알림창으로 알린다.
@MainActor
final class EngineUpdateCoordinator {
    static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastEngineUpdateCheck"

    private let updater: EngineUpdater
    private let source: EngineSource
    private let bundled: EngineLocator
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    init(updater: EngineUpdater, source: EngineSource, bundled: EngineLocator, defaults: UserDefaults = .standard) {
        self.updater = updater
        self.source = source
        self.bundled = bundled
        self.defaults = defaults
    }

    /// 앱 시작 시 한 번 부른다.
    func start() {
        guard task == nil else { return }
        task = Task {
            await activateInstalled()
            await performCheck(manual: false)
            task = nil
        }
    }

    /// 메뉴 "엔진 업데이트 확인…".
    func checkNow() {
        guard task == nil else {
            present("엔진 업데이트를 확인하는 중입니다.", detail: "잠시 후 다시 시도해 주세요.")
            return
        }
        task = Task {
            await performCheck(manual: true)
            task = nil
        }
    }

    /// 받아 둔 버전이 번들보다 새로우면 사용한다. 앱 업데이트로 번들이 같거나 더 새로워졌으면 받아 둔 것을 지운다.
    func activateInstalled() async {
        guard let installed = updater.installed() else {
            updater.removeVersions(except: nil)
            return
        }
        if let bundledVersion = try? await updater.version(of: bundled.ytDlp),
           !EngineUpdater.isNewer(installed.version, than: bundledVersion) {
            updater.removeVersions(except: nil)
            return
        }
        updater.removeVersions(except: installed.version)
        source.update(bundled.replacingYtDlp(with: installed.url))
    }

    private func performCheck(manual: Bool) async {
        if !manual, let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }
        do {
            let current = try await updater.version(of: source.current.ytDlp)
            let latest = try await updater.latestRelease()
            defaults.set(Date(), forKey: Self.lastCheckKey)
            guard EngineUpdater.isNewer(latest.version, than: current) else {
                if manual { present("추출 엔진이 최신 버전입니다.", detail: "yt-dlp \(current)") }
                return
            }
            let installed = try await updater.install(latest)
            source.update(bundled.replacingYtDlp(with: installed))
            if manual {
                present("추출 엔진을 업데이트했습니다.", detail: "yt-dlp \(current) → \(latest.version)\n다음 추출부터 새 엔진을 씁니다.")
            }
        } catch is CancellationError {
            return
        } catch {
            // 자동 확인의 실패는 조용히 넘어간다(다음 실행 때 다시 확인).
            if manual {
                present("엔진 업데이트를 확인하지 못했습니다.", detail: error.localizedDescription, style: .warning)
            }
        }
    }

    private func present(_ message: String, detail: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = style
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
