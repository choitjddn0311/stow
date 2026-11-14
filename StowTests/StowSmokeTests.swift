import AppKit
import SwiftUI
import Testing
@testable import Stow

/// 1단계 기반 구축 확인용 스모크 테스트.
@MainActor
struct StowSmokeTests {
    /// 테스트가 Stow.app 안에서 호스팅되어 실행되는지 확인한다(번들 ID 값에는 의존하지 않음).
    @Test func testsRunHostedInApp() throws {
        #expect(Bundle.main.bundleURL.pathExtension == "app")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Stow")
        let identifier = try #require(Bundle.main.bundleIdentifier)
        #expect(!identifier.isEmpty)
    }

    /// 최소 지원 OS가 macOS 14인지 확인한다("14", "14.0" 표기 모두 허용).
    @Test func minimumSystemVersionIsMacOS14() throws {
        let raw = try #require(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String)
        let parts = raw.split(separator: ".").map { Int($0) }
        #expect(parts.first == 14)
        #expect(parts.dropFirst().allSatisfy { $0 == 0 })
    }

    /// 루트 화면을 실제로 렌더링해 내용(텍스트)이 그려지는지 확인한다(이용 고지, 추출 화면 각각).
    /// 배경이 투명하므로, 그려진 픽셀(알파 > 0)이 없으면 화면 내용이 비어 있는 것이다.
    @Test(arguments: [false, true])
    func rootViewRendersContent(noticeAccepted: Bool) throws {
        let defaults = try #require(UserDefaults(suiteName: "stow-smoke-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.acceptedNoticeVersion = noticeAccepted ? UsageNotice.version : 0
        let model = ExtractViewModel(
            settings: settings, engine: YtDlpClient(engine: try EngineLocator.bundled()), notifier: SilentNotifier()
        )
        let renderer = ImageRenderer(content: RootView(model: model, settings: settings))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width >= 560)
        #expect(image.height >= 500)
        #expect(Self.drawnPixelCount(in: image) > 0)
    }

    private static func drawnPixelCount(in image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 0 ? 1 : 0) }
    }
}
