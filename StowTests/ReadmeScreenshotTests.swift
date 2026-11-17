import AppKit
import SwiftUI
import Testing
@testable import Stow

/// README용 스크린샷을 만든다. 평소 테스트에서는 돌지 않고, 폴더를 줄 때만 실행한다.
///
///     TEST_RUNNER_STOW_README_SHOTS=<폴더> xcodebuild ... test -only-testing:StowTests/ReadmeScreenshotTests
///
/// - 실제 유튜브 영상·채널 대신 가상의 제목과 직접 그린 추상 썸네일을 쓴다(저작권·초상권 문제를 피하려고).
/// - 실제 창(제목 막대·유리 패널)을 화면에 띄우고 뒤에 배경 창을 깐 뒤 그 영역을 캡처한다.
///   캡처에는 화면 기록 권한이 필요하다(터미널에서 실행할 때 터미널에 권한이 있어야 함).
/// 스크린샷을 저장할 폴더(환경 변수 `TEST_RUNNER_STOW_README_SHOTS`). 없으면 이 테스트들을 건너뛴다.
private let readmeShotsDirectory: URL? =
    ProcessInfo.processInfo.environment["STOW_README_SHOTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

@MainActor
@Suite(.enabled(if: readmeShotsDirectory != nil), .serialized)
struct ReadmeScreenshotTests {

    nonisolated static let videoURL = "https://www.youtube.com/watch?v=Stow0000001"

    @Test(arguments: [false, true])
    func mainWindowWithQueue(dark: Bool) async throws {
        let fixture = try await Fixture.make(media: .video(Samples.video()))
        let items = [
            fixture.item("새벽 산책 — Ambient Mix", behavior: .done),
            fixture.item("Rainy Afternoon (Lo-fi Session)", behavior: .running(0.64)),
            fixture.item("여름밤 드라이브 플레이리스트 01", behavior: .wait),
            fixture.item("Piano Sketches Vol. 2", behavior: .wait),
        ]
        fixture.queue.add(items)
        try await fixture.waitForRunning()
        try await capture(
            RootView(model: fixture.model, settings: fixture.settings),
            size: CGSize(width: 600, height: 760), dark: dark, name: "main-\(dark ? "dark" : "light")"
        )
        await fixture.tearDown()
    }

    @Test func playlistSelection() async throws {
        let fixture = try await Fixture.make(media: .playlist(Samples.playlist))
        try await capture(
            RootView(model: fixture.model, settings: fixture.settings),
            size: CGSize(width: 600, height: 720), dark: false, name: "playlist-light"
        )
        await fixture.tearDown()
    }

    @Test(arguments: [false, true])
    func quickPanel(dark: Bool) async throws {
        let fixture = try await Fixture.make(media: .video(Samples.video()), fetchNow: false)
        let model = QuickPanelModel(extract: fixture.model, clipboard: SampleClipboard(text: Self.videoURL))
        let controller = QuickPanelController(model: model)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = nil }
        let backdrop = Backdrop.show(dark: dark)
        controller.show()
        // 클립보드를 읽고 영상 정보를 불러올 때까지 기다린다.
        for _ in 0..<300 where fixture.model.stage != .video {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(800))
        guard let panel = NSApp.windows.first(where: { $0 is QuickPanel && $0.isVisible }) else {
            Issue.record("패널이 뜨지 않음")
            return
        }
        // 패널은 마우스가 있는 화면에 뜨므로, 배경을 깐 주 화면 가운데로 옮긴다(다른 화면의 바탕화면이 찍히지 않게).
        if let visible = Self.screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2))
            try await Task.sleep(for: .milliseconds(500))
        }
        try await Self.screencapture(rect: panel.frame.insetBy(dx: -40, dy: -40), name: "panel-\(dark ? "dark" : "light")")
        model.dismiss()
        backdrop.close()
        await fixture.tearDown()
    }

    // MARK: - 창 띄우고 찍기

    private func capture(_ view: some View, size: CGSize, dark: Bool, name: String) async throws {
        let backdrop = Backdrop.show(dark: dark)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Stow"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // 메뉴 막대·화면 가장자리에 걸리지 않게 화면 안쪽 가운데에 둔다(캡처 영역이 화면 밖으로 나가면 해상도가 떨어진다).
        if let visible = Self.screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        }
        // 앱을 앞으로 가져온 뒤 창을 띄워야 활성 창(신호등 버튼에 색이 있는 모양)으로 찍힌다.
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(300))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(1200))
        try await Self.screencapture(rect: window.frame.insetBy(dx: -40, dy: -40), name: name)
        window.close()
        backdrop.close()
    }

    /// 찍을 화면: 주 화면(메뉴 막대가 있는 화면). 배경·창을 모두 여기에 둔다.
    private static var screen: NSScreen? { NSScreen.screens.first }

    /// 화면 좌표(왼쪽 아래 원점)의 영역을 PNG로 찍는다.
    ///
    /// 테스트 앱에는 화면 기록 권한이 없으므로 직접 찍지 않는다. 찍을 영역을 `<이름>.region`에 적고,
    /// 권한이 있는 터미널에서 도는 스크립트가 `screencapture -R`로 `<이름>.png`를 만들 때까지 기다린다.
    /// (스크립트 예: 폴더의 `.region` 파일마다 `screencapture -x -R "$(cat f)" "${f%.region}.png"` 후 `.region` 삭제)
    private static func screencapture(rect: NSRect, name: String) async throws {
        let directory = try #require(readmeShotsDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screenHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        // screencapture -R은 왼쪽 위 원점이다.
        let region = "\(Int(rect.minX)),\(Int(screenHeight - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))"
        let image = directory.appending(path: "\(name).png")
        try? FileManager.default.removeItem(at: image)
        try region.write(to: directory.appending(path: "\(name).region"), atomically: true, encoding: .utf8)
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: image.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(FileManager.default.fileExists(atPath: image.path), "\(name).png를 찍지 못함(캡처 스크립트가 돌고 있는지 확인)")
        try await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - 예시 상태

    private struct Fixture {
        let model: ExtractViewModel
        let queue: ExtractQueue
        let settings: AppSettings
        let engine: SampleEngine
        let options: ExtractOptions

        @MainActor
        static func make(media: FetchedMedia, fetchNow: Bool = true) async throws -> Fixture {
            let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "stow-readme-\(UUID().uuidString)")))
            settings.acceptedNoticeVersion = UsageNotice.version
            // 화면에는 "~/Music/Stow"처럼 보이게, 실제로 있는 폴더를 쓴다.
            let music = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music", directoryHint: .isDirectory)
            settings.outputDirectory = music
            settings.formatKind = .mp3
            settings.mp3Bitrate = .kbps320
            let engine = SampleEngine(media: media)
            let queue = ExtractQueue(engine: engine, notifier: SilentNotifier())
            let model = ExtractViewModel(settings: settings, engine: engine, queue: queue)
            if fetchNow {
                if case .playlist = media {
                    model.urlText = "https://www.youtube.com/playlist?list=PLStowSample"
                } else {
                    model.urlText = ReadmeScreenshotTests.videoURL
                }
                model.fetch()
                await model.waitForTask()
            }
            return Fixture(
                model: model, queue: queue, settings: settings, engine: engine,
                options: ExtractOptions(format: .mp3(.kbps320), outputDirectory: FileManager.default.temporaryDirectory)
            )
        }

        func item(_ title: String, behavior: SampleEngine.Behavior) -> ExtractQueue.Item {
            engine.setBehavior(behavior, for: title)
            return ExtractQueue.Item(url: URL(string: ReadmeScreenshotTests.videoURL)!, title: title, options: options)
        }

        @MainActor
        func waitForRunning() async throws {
            for _ in 0..<300 where !(queue.items.contains { $0.status == .running && $0.progress.value != nil }) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        @MainActor
        func tearDown() async {
            model.cancelFetch()
            await queue.cancelAndWait()
        }
    }

    /// 배경 창: 바탕화면 대신 은은한 그라데이션을 깐다(캡처에 다른 앱이 비치지 않게).
    private enum Backdrop {
        @MainActor
        static func show(dark: Bool) -> NSWindow {
            let frame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            let colors: [Color] = dark
                ? [Color(red: 0.06, green: 0.18, blue: 0.20), Color(red: 0.10, green: 0.10, blue: 0.16)]
                : [Color(red: 0.80, green: 0.93, blue: 0.91), Color(red: 0.88, green: 0.90, blue: 0.97)]
            window.contentView = NSHostingView(
                rootView: LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            window.orderFront(nil)
            return window
        }
    }
}

// MARK: - 예시 데이터

private enum Samples {
    /// 직접 그린 추상 썸네일(16:9)을 임시 폴더에 만들고 그 주소를 돌려준다.
    @MainActor
    static func thumbnail(name: String, hues: (Double, Double)) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "stow-readme-\(name).png")
        let size = CGSize(width: 640, height: 360)
        let image = NSImage(size: size, flipped: false) { rect in
            let gradient = NSGradient(colors: [
                NSColor(hue: hues.0, saturation: 0.55, brightness: 0.85, alpha: 1),
                NSColor(hue: hues.1, saturation: 0.65, brightness: 0.55, alpha: 1),
            ])
            gradient?.draw(in: rect, angle: -35)
            // 겹친 원 몇 개로 앨범 아트 같은 느낌을 낸다.
            for (index, scale) in [0.9, 0.62, 0.36].enumerated() {
                let diameter = rect.height * scale
                let circle = NSRect(
                    x: rect.midX - diameter / 2 + CGFloat(index) * 40, y: rect.midY - diameter / 2,
                    width: diameter, height: diameter
                )
                NSColor(white: 1, alpha: 0.10 + Double(index) * 0.06).setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            return true
        }
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        return url
    }

    @MainActor
    static func video() -> VideoMetadata {
        VideoMetadata(
            id: "Stow0000001", title: "Rainy Afternoon (Lo-fi Session) — 비 오는 오후에 듣는 음악",
            duration: 2_847, thumbnailURL: thumbnail(name: "video", hues: (0.48, 0.62)),
            uploader: "Stow Sample Music",
            webpageURL: URL(string: "https://www.youtube.com/watch?v=Stow0000001")
        )
    }

    static let playlist = Playlist(id: "PLStowSample", title: "작업할 때 듣는 플레이리스트", entries: [
        PlaylistEntry(id: "StowSample1", title: "새벽 산책 — Ambient Mix", duration: 1_820),
        PlaylistEntry(id: "StowSample2", title: "Rainy Afternoon (Lo-fi Session)", duration: 2_847),
        PlaylistEntry(id: "StowSample3", title: "[Private video]", duration: nil),
        PlaylistEntry(id: "StowSample4", title: "여름밤 드라이브 플레이리스트 01", duration: 3_412),
        PlaylistEntry(id: "StowSample5", title: "Piano Sketches Vol. 2", duration: 1_265),
        PlaylistEntry(id: "StowSample6", title: "Focus Beats — 집중이 필요할 때", duration: 3_600),
    ])
}

/// 제목마다 정한 대로 끝나는 가짜 엔진(완료·진행 중·대기).
private final class SampleEngine: AudioExtracting, @unchecked Sendable {
    enum Behavior: Sendable {
        case done
        case running(Double)
        case wait
    }

    private let lock = NSLock()
    private let media: FetchedMedia
    private var behaviors: [String: Behavior] = [:]

    init(media: FetchedMedia) { self.media = media }

    func setBehavior(_ behavior: Behavior, for title: String) {
        lock.withLock { behaviors[FileNaming.sanitize(title)] = behavior }
    }

    func fetchMedia(for url: URL) async throws -> FetchedMedia { media }

    func extract(
        _ url: URL, options: ExtractOptions, fileName: String,
        progress: @escaping @Sendable (ExtractProgress) -> Void
    ) async throws -> URL {
        switch lock.withLock({ behaviors[fileName] }) ?? .wait {
        case .done:
            return options.outputDirectory.appending(path: "\(fileName).\(options.format.fileExtension)")
        case .running(let fraction):
            progress(.downloading(fraction: fraction, bytesPerSecond: 2_400_000, secondsRemaining: 12))
        case .wait:
            break
        }
        try await Task.sleep(for: .seconds(600))
        throw CancellationError()
    }
}

private struct SampleClipboard: ClipboardReading {
    let text: String
    var changeCount: Int { 1 }
    func webURLText() async -> String? { text }
}
