import Foundation
import Testing
@testable import Stow

/// 미룬 업데이트 다시 알림: 새 버전은 바로, 같은 버전은 하루에 한 번. 그사이 메뉴 막대 메뉴로 알림.
@MainActor
struct UpdateReminderTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func newVersionIsShownImmediately() {
        let policy = UpdateReminderPolicy()
        #expect(policy.shouldShowAlert(for: "6", now: start))
    }

    @Test func sameVersionWaitsADay() {
        var policy = UpdateReminderPolicy()
        policy.recordShown("6", displayVersion: "0.6.0", at: start)
        #expect(!policy.shouldShowAlert(for: "6", now: start.addingTimeInterval(60 * 60)))
        #expect(!policy.shouldShowAlert(for: "6", now: start.addingTimeInterval(23 * 60 * 60)))
        #expect(policy.shouldShowAlert(for: "6", now: start.addingTimeInterval(24 * 60 * 60)))
    }

    @Test func newerVersionIsShownEvenRightAfterPostponing() {
        var policy = UpdateReminderPolicy()
        policy.recordShown("6", displayVersion: "0.6.0", at: start)
        #expect(policy.shouldShowAlert(for: "7", now: start.addingTimeInterval(60)))
    }

    @Test func pendingVersionUntilInstalledOrSkipped() {
        var policy = UpdateReminderPolicy()
        #expect(policy.pendingDisplayVersion(currentBuild: "5", skippedVersion: nil) == nil)
        policy.recordShown("6", displayVersion: "0.6.0", at: start)
        #expect(policy.pendingDisplayVersion(currentBuild: "5", skippedVersion: nil) == "0.6.0")
        // 설치해서 앱 빌드가 같거나 새로워지면 없음
        #expect(policy.pendingDisplayVersion(currentBuild: "6", skippedVersion: nil) == nil)
        #expect(policy.pendingDisplayVersion(currentBuild: "7", skippedVersion: nil) == nil)
        // 건너뛴 버전이면 없음
        #expect(policy.pendingDisplayVersion(currentBuild: "5", skippedVersion: "6") == nil)
        // 빌드 번호는 숫자로 비교한다(10 > 9)
        policy.recordShown("10", displayVersion: "1.0.0", at: start)
        #expect(policy.pendingDisplayVersion(currentBuild: "9", skippedVersion: nil) == "1.0.0")
    }

    @Test func reminderReadsSavedStateAtLaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "stow-reminder-\(UUID().uuidString)"))
        #expect(UpdateReminder(defaults: defaults, currentBuild: "5").pendingVersion == nil)

        defaults.set("6", forKey: "updateReminder.lastShownVersion")
        defaults.set("0.6.0", forKey: "updateReminder.lastShownDisplayVersion")
        defaults.set(Date(), forKey: "updateReminder.lastShownDate")
        let reminder = UpdateReminder(defaults: defaults, currentBuild: "5")
        #expect(reminder.supportsGentleScheduledUpdateReminders)
        #expect(reminder.pendingVersion == "0.6.0")

        defaults.set("6", forKey: "SUSkippedVersion")
        #expect(UpdateReminder(defaults: defaults, currentBuild: "5").pendingVersion == nil)
    }
}
