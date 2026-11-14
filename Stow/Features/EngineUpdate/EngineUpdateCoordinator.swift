import AppKit
import Foundation

/// 앱 안 엔진(yt-dlp) 업데이트 흐름(사용자 결정 2026-11-14: 자동 확인 + 자동 설치, stable 채널).
///
/// - 앱 시작(실행당 한 번): 받아 둔 버전이 번들보다 새롭고 실제로 실행되면 그것을 쓴다.
///   아니면 받아 둔 것을 지우고 번들 엔진을 쓴다. 옛 버전 파일은 이때만 지운다(추출 중 삭제 방지).
/// - 앱이 켜져 있는 동안 1시간마다 확인 시점을 보고, 마지막 확인 뒤 하루가 지났으면 확인·설치한다.
///   새 엔진은 다음 추출부터 쓴다. 실패하면 확인 시각을 남기지 않아 다음 기회에 다시 시도한다.
/// - 메뉴 "엔진 업데이트 확인…": 바로 확인하고 결과를 알린다.
/// - 메뉴 "앱에 들어 있는 엔진으로 되돌리기": 받은 버전에 문제가 있을 때. 그 버전은 자동으로 다시 설치하지 않는다.
@MainActor
final class EngineUpdateCoordinator {
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let pollInterval: Duration = .seconds(60 * 60)
    static let lastCheckKey = "lastEngineUpdateCheck"
    static let rejectedVersionKey = "rejectedEngineVersion"

    typealias Presenter = @MainActor (_ message: String, _ detail: String, _ style: NSAlert.Style) -> Void

    private let updater: EngineUpdater
    private let source: EngineSource
    private let bundled: EngineLocator
    private let defaults: UserDefaults
    private let present: Presenter

    /// 번들 yt-dlp 버전. `bin/yt-dlp.version`이 없으면 처음 필요할 때 실행해서 읽는다.
    private var bundledVersion: String?
    /// 지금 쓰는 yt-dlp 버전(알면). 확인할 때마다 Python을 실행하지 않도록 기억한다.
    private(set) var activeVersion: String?
    private var activated = false
    private var isChecking = false
    private var loop: Task<Void, Never>?

    init(
        updater: EngineUpdater,
        source: EngineSource,
        bundled: EngineLocator,
        defaults: UserDefaults = .standard,
        bundledVersion: String? = nil,
        present: @escaping Presenter = EngineUpdateCoordinator.alert
    ) {
        self.updater = updater
        self.source = source
        self.bundled = bundled
        self.defaults = defaults
        self.present = present
        // bundledVersion: 테스트에서 번들 버전을 바꿔 볼 때만 지정한다.
        self.bundledVersion = bundledVersion ?? bundled.bundledYtDlpVersion
    }

    var isUsingDownloadedEngine: Bool {
        source.current.ytDlp != bundled.ytDlp
    }

    /// 앱 시작 시 부른다. 창을 여러 번 열어도 한 번만 돈다.
    func start() {
        guard loop == nil else { return }
        loop = Task {
            await activateInstalled()
            while !Task.isCancelled {
                await performCheck(manual: false)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// 메뉴 "엔진 업데이트 확인…".
    func checkNow() {
        Task { await performCheck(manual: true) }
    }

    /// 메뉴 "앱에 들어 있는 엔진으로 되돌리기".
    func revertToBundled() {
        guard isUsingDownloadedEngine else {
            present("앱에 들어 있는 엔진을 쓰고 있습니다.", "되돌릴 업데이트가 없습니다.", .informational)
            return
        }
        if let activeVersion { defaults.set(activeVersion, forKey: Self.rejectedVersionKey) }
        updater.clearCurrent()
        source.update(bundled)
        let rejected = activeVersion
        activeVersion = bundledVersion
        present(
            "앱에 들어 있는 엔진으로 되돌렸습니다.",
            "다음 추출부터 yt-dlp \(bundledVersion ?? "")을 씁니다."
                + (rejected.map { " \($0) 버전은 자동으로 다시 설치하지 않고, 더 새 버전이 나오면 받습니다." } ?? ""),
            .informational
        )
    }

    /// 받아 둔 버전을 쓸지 정한다. 실행당 한 번만 한다(옛 버전 파일 삭제가 추출과 겹치지 않게).
    func activateInstalled() async {
        guard !activated else { return }
        activated = true
        let bundled = await resolvedBundledVersion()
        activeVersion = bundled

        guard let installed = updater.installed() else {
            updater.removeVersions(except: nil)
            return
        }
        // 번들 버전을 알 수 없거나, 받아 둔 버전이 더 새롭지 않거나, 되돌린 버전이면 쓰지 않는다.
        guard let bundled, EngineUpdater.isNewer(installed.version, than: bundled),
              installed.version != defaults.string(forKey: Self.rejectedVersionKey)
        else {
            updater.removeVersions(except: nil)
            return
        }
        // 손상된 파일이면 쓰지 않는다(실행해 본 버전이 기록과 같아야 한다).
        guard (try? await updater.version(of: installed.url)) == installed.version else {
            updater.removeVersions(except: nil)
            return
        }
        updater.removeVersions(except: installed.version)
        source.update(self.bundled.replacingYtDlp(with: installed.url))
        activeVersion = installed.version
    }

    func performCheck(manual: Bool) async {
        guard !isChecking else {
            if manual { present("엔진 업데이트를 확인하는 중입니다.", "잠시 후 다시 시도해 주세요.", .informational) }
            return
        }
        if !manual, let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }
        isChecking = true
        defer { isChecking = false }

        do {
            let current = await currentVersion()
            let latest = try await updater.latestRelease()
            if latest.version == defaults.string(forKey: Self.rejectedVersionKey) {
                defaults.set(Date(), forKey: Self.lastCheckKey)
                if manual {
                    present("새로 설치할 엔진이 없습니다.", "최신 버전 \(latest.version)은 되돌린 버전이라 설치하지 않았습니다.", .informational)
                }
                return
            }
            guard EngineUpdater.isNewer(latest.version, than: current ?? "0") else {
                defaults.set(Date(), forKey: Self.lastCheckKey)
                if manual { present("추출 엔진이 최신 버전입니다.", "yt-dlp \(current ?? latest.version)", .informational) }
                return
            }
            let installed = try await updater.install(latest)
            source.update(bundled.replacingYtDlp(with: installed))
            activeVersion = latest.version
            // 성공했을 때만 기록한다. 실패하면 다음 확인 때 다시 시도한다.
            defaults.set(Date(), forKey: Self.lastCheckKey)
            if manual {
                present(
                    "추출 엔진을 업데이트했습니다.",
                    "yt-dlp \(current.map { "\($0) → " } ?? "")\(latest.version)\n다음 추출부터 새 엔진을 씁니다.",
                    .informational
                )
            }
        } catch is CancellationError {
            return
        } catch {
            // 자동 확인의 실패는 조용히 넘어간다(확인 시각을 남기지 않았으므로 다음에 다시 시도).
            if manual { present("엔진 업데이트를 확인하지 못했습니다.", error.localizedDescription, .warning) }
        }
    }

    /// 지금 쓰는 버전. 모르면 실행해서 읽고, 받은 엔진이 실행되지 않으면 번들 엔진으로 돌아간다.
    private func currentVersion() async -> String? {
        if let activeVersion { return activeVersion }
        if let version = try? await updater.version(of: source.current.ytDlp) {
            activeVersion = version
            return version
        }
        if isUsingDownloadedEngine {
            source.update(bundled)
            updater.clearCurrent()
            activeVersion = await resolvedBundledVersion()
        }
        return activeVersion
    }

    private func resolvedBundledVersion() async -> String? {
        if bundledVersion == nil {
            bundledVersion = try? await updater.version(of: bundled.ytDlp)
        }
        return bundledVersion
    }

    static func alert(_ message: String, _ detail: String, _ style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = style
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
