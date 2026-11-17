import AppKit
import Foundation
@preconcurrency import UserNotifications

/// 저장 완료 알림과 Finder 표시. ViewModel 테스트에서는 가짜 구현을 쓴다.
@MainActor
protocol CompletionNotifying: AnyObject {
    /// 알림 권한을 요청한다(처음 추출할 때 한 번).
    func prepare()
    func notifyCompleted(title: String, file: URL)
    func revealInFinder(_ file: URL)
}

/// macOS 알림 센터로 완료를 알린다. 알림을 누르면 Finder에서 파일을 보여 준다.
@MainActor
final class SystemCompletionNotifier: NSObject, CompletionNotifying, UNUserNotificationCenterDelegate {
    private nonisolated static let fileKey = "file"
    private var prepared = false

    /// 앱이 시작할 때 만든다. 처리기를 바로 등록해야, 이전 실행에서 보낸 알림을 눌러 앱이 열렸을 때도
    /// Finder에서 파일을 보여 줄 수 있다.
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyCompleted(title: String, file: URL) {
        let content = UNMutableNotificationContent()
        content.title = "저장 완료"
        content.body = "\(title) → \(file.lastPathComponent)"
        content.sound = .default
        content.userInfo = [Self.fileKey: file.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func revealInFinder(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // 앱이 앞에 있어도 배너를 보여 준다.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let path = response.notification.request.content.userInfo[Self.fileKey] as? String else { return }
        await MainActor.run { revealInFinder(URL(filePath: path)) }
    }
}
