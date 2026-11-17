import Foundation
import Observation
import OSLog
import Sparkle

/// 자동 확인으로 찾은 새 버전을 언제 알림 창으로 띄울지 정한다.
///
/// - 처음 찾은 버전은 바로 띄운다(릴리스 직후 알림).
/// - 사용자가 "나중에"로 미룬 같은 버전은 `remindInterval`(하루)이 지날 때까지 창을 다시 띄우지 않는다.
///   확인 주기가 1시간이라, 그대로 두면 미룬 업데이트를 1시간마다 다시 묻게 된다.
struct UpdateReminderPolicy {
    static let remindInterval: TimeInterval = 24 * 60 * 60

    /// 마지막으로 알린 버전(빌드 번호)·표시 버전·시각
    var lastShownVersion: String?
    var lastShownDisplayVersion: String?
    var lastShownDate: Date?

    func shouldShowAlert(for version: String, now: Date = .now) -> Bool {
        guard version == lastShownVersion, let lastShownDate else { return true }
        return now.timeIntervalSince(lastShownDate) >= Self.remindInterval
    }

    mutating func recordShown(_ version: String, displayVersion: String, at date: Date = .now) {
        lastShownVersion = version
        lastShownDisplayVersion = displayVersion
        lastShownDate = date
    }

    /// 아직 설치하지 않은 알린 버전(메뉴 막대 메뉴에 "새 버전 설치…"로 보여 줄 표시 버전).
    /// 지금 앱보다 새 빌드이고 사용자가 건너뛰지 않았을 때만.
    func pendingDisplayVersion(currentBuild: String, skippedVersion: String?) -> String? {
        guard let lastShownVersion, let lastShownDisplayVersion,
              lastShownVersion != skippedVersion,
              lastShownVersion.compare(currentBuild, options: .numeric) == .orderedDescending
        else { return nil }
        return lastShownDisplayVersion
    }
}

/// Sparkle 표준 업데이트 창의 부드러운 알림(gentle reminders) 처리.
/// 미룬 업데이트는 창 대신 메뉴 막대 메뉴의 "새 버전 설치…" 항목으로 알린다.
///
/// Sparkle은 미룬 업데이트를 앱을 다시 켤 때 이어서 들고 있어 델리게이트에 다시 알리지 않으므로,
/// 메뉴 항목은 콜백이 아니라 저장해 둔 "마지막으로 알린 버전"과 지금 앱 버전을 비교해 정한다.
@MainActor
@Observable
final class UpdateReminder: NSObject, SPUStandardUserDriverDelegate {
    /// 아직 설치하지 않은 새 버전(메뉴 막대 메뉴에 보여 준다). nil이면 없음.
    private(set) var pendingVersion: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentBuild: String
    @ObservationIgnored weak var updater: SPUUpdater?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Stow", category: "update-reminder")
    private static let versionKey = "updateReminder.lastShownVersion"
    private static let displayVersionKey = "updateReminder.lastShownDisplayVersion"
    private static let dateKey = "updateReminder.lastShownDate"
    /// Sparkle이 "이 버전 건너뛰기"를 기록하는 키
    private static let skippedVersionKey = "SUSkippedVersion"

    init(
        defaults: UserDefaults = .standard,
        currentBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    ) {
        self.defaults = defaults
        self.currentBuild = currentBuild
        super.init()
        refreshPending()
    }

    private var policy: UpdateReminderPolicy {
        get {
            UpdateReminderPolicy(
                lastShownVersion: defaults.string(forKey: Self.versionKey),
                lastShownDisplayVersion: defaults.string(forKey: Self.displayVersionKey),
                lastShownDate: defaults.object(forKey: Self.dateKey) as? Date
            )
        }
        set {
            defaults.set(newValue.lastShownVersion, forKey: Self.versionKey)
            defaults.set(newValue.lastShownDisplayVersion, forKey: Self.displayVersionKey)
            defaults.set(newValue.lastShownDate, forKey: Self.dateKey)
        }
    }

    private func refreshPending() {
        let pending = policy.pendingDisplayVersion(
            currentBuild: currentBuild, skippedVersion: defaults.string(forKey: Self.skippedVersionKey)
        )
        // 같은 값을 다시 넣으면 메뉴 막대 메뉴가 쓸데없이 다시 만들어지므로 바뀔 때만 넣는다.
        if pending != pendingVersion { pendingVersion = pending }
        Self.log.info("pending update: \(self.pendingVersion ?? "none", privacy: .public) (current build \(self.currentBuild, privacy: .public))")
    }

    /// 메뉴 막대 메뉴의 "새 버전 설치…": 업데이트 창을 앞으로 띄운다(사용자가 연 확인이라 항상 창이 뜬다).
    func showPendingUpdate() {
        updater?.checkForUpdates()
    }

    // MARK: - SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        let version = update.versionString
        return MainActor.assumeIsolated {
            let show = policy.shouldShowAlert(for: version)
            Self.log.info("scheduled update \(version, privacy: .public): show alert \(show)")
            return show
        }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.versionString
        let displayVersion = update.displayVersionString
        MainActor.assumeIsolated {
            // 창을 띄울 때만 "알린 시각"을 새로 남긴다(창을 띄우지 않은 확인이 하루 대기를 늘리지 않게).
            if handleShowingUpdate {
                var policy = policy
                policy.recordShown(version, displayVersion: displayVersion)
                self.policy = policy
            }
            refreshPending()
        }
    }

    /// 사용자가 업데이트 창을 닫거나 건너뛴 뒤(건너뛰면 메뉴 항목도 뺀다).
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { refreshPending() }
    }
}
