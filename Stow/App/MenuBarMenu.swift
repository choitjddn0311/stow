import KeyboardShortcuts
import SwiftUI

/// 메뉴 막대 아이콘의 메뉴. 창을 닫아도 앱이 여기 남아 빠른 추출 단축키가 동작한다(사용자 결정 2026-11-14).
struct MenuBarMenu: View {
    let coordinator: AppCoordinator
    let updateReminder: UpdateReminder
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let queue = coordinator.queue, queue.hasPendingItems {
            Text(queueSummary(queue))
            Divider()
        }
        if let version = updateReminder.pendingVersion {
            Button {
                NSApp.activate()
                updateReminder.showPendingUpdate()
            } label: {
                Text(verbatim: "새 버전 \(version) 설치…")
            }
            Divider()
        }
        Button("빠른 추출…") { coordinator.showQuickPanel() }
            .globalKeyboardShortcut(.quickExtract)
        Button("Stow 창 열기") { coordinator.openMainWindow() }
        Divider()
        Button("설정…") {
            NSApp.activate()
            openSettings()
        }
        Divider()
        Button("Stow 종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func queueSummary(_ queue: ExtractQueue) -> String {
        let running = queue.items.first { $0.status == .running }
        let waiting = queue.waitingCount
        switch (running, waiting) {
        case (let item?, 0): return "추출 중: \(item.title)"
        case (let item?, _): return "추출 중: \(item.title) 외 대기 \(waiting)개"
        case (nil, _): return "대기 \(waiting)개"
        }
    }
}
