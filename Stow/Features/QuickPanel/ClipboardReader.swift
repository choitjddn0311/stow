import AppKit

/// 빠른 추출 패널이 열릴 때 클립보드에서 유튜브 주소를 읽는다(테스트에서는 가짜로 바꾼다).
@MainActor
protocol ClipboardReading {
    /// 클립보드 내용이 바뀔 때마다 늘어나는 값. 읽어도 확인창이 뜨지 않는다.
    var changeCount: Int { get }
    /// 클립보드 첫 항목의 글자. 주소처럼 보이지 않으면 nil(이때는 내용을 읽지 않는다).
    func webURLText() async -> String?
}

/// 시스템 클립보드. macOS 15.4부터는 앱이 클립보드를 읽으면 확인창이 뜰 수 있으므로,
/// 내용을 읽지 않고 주소처럼 보이는지 먼저 확인한 뒤에만 읽는다(주소가 아니면 확인창도 뜨지 않는다).
@MainActor
struct SystemClipboard: ClipboardReading {
    private var pasteboard: NSPasteboard { .general }

    var changeCount: Int { pasteboard.changeCount }

    func webURLText() async -> String? {
        if #available(macOS 15.4, *) {
            // 사용자가 시스템 설정에서 "거부"로 정했으면 읽지 않는다.
            guard pasteboard.accessBehavior != .alwaysDeny else { return nil }
            guard await Self.firstItemLooksLikeWebURL() else { return nil }
        }
        return pasteboard.string(forType: .string)
    }

    /// 내용을 읽지 않고(확인창 없이) 첫 항목이 웹 주소처럼 보이는지만 확인한다.
    @available(macOS 15.4, *)
    private nonisolated static func firstItemLooksLikeWebURL() async -> Bool {
        let pasteboard = NSPasteboard.general
        let webURL: PartialKeyPath<NSPasteboard.DetectedValues> = \.probableWebURL
        guard let patterns = try? await pasteboard.detectedPatterns(for: [webURL]) else { return false }
        return patterns.contains(webURL)
    }
}

enum ClipboardURL {
    /// 클립보드 글자가 유튜브 영상·재생목록 주소면 그대로(앞뒤 공백 제거) 돌려준다.
    static func youTubeText(from text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 여러 줄이거나 너무 길면 주소 하나가 아니다.
        guard !trimmed.isEmpty, trimmed.count <= 2048, !trimmed.contains(where: \.isNewline) else { return nil }
        guard (try? YouTubeURL.parse(trimmed)) != nil else { return nil }
        return trimmed
    }
}
