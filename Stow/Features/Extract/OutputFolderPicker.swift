import AppKit

/// 저장 폴더 선택 창(메인 창 "변경…", 빠른 추출 패널 "다른 폴더…"가 함께 쓴다).
@MainActor
enum OutputFolderPicker {
    /// 폴더 선택 창을 띄우고 고른 폴더를 돌려준다. 취소하면 nil.
    /// - Parameter level: 선택 창을 이 창 수준 위에 띄운다(떠 있는 패널 뒤에 가려지지 않게).
    static func choose(current: URL, above level: NSWindow.Level? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        panel.prompt = "선택"
        panel.message = "추출한 파일을 저장할 폴더를 선택하세요."
        if let level {
            panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
