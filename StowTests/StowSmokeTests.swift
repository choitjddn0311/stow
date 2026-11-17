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

    /// 앱 새 버전 확인: 자동 확인을 켜고 1시간마다(릴리스 직후 알림이 뜨도록).
    /// 3600초는 Sparkle이 허용하는 가장 짧은 주기다.
    @Test func sparkleChecksHourly() throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int == 3600)
    }

    /// 루트 화면을 실제 앱과 같은 방식(`NSHostingView`)으로 그려 내용이 그려지는지 확인한다(이용 고지, 추출 화면 각각).
    ///
    /// `ImageRenderer`는 쓰지 않는다. TextField 같은 기본 컨트롤을 그리지 못하고 SwiftUI 런타임 이슈
    /// ("Accessing FocusState's value outside of the body of a View")를 낸다. XCTest가 이 이슈를 보고하며
    /// 빌드 산출물을 읽을 때, 저장소가 데스크탑 폴더에 있으면 macOS 권한 확인(TCC)에 걸려 테스트가 끝나지 않는다.
    @Test(arguments: [false, true])
    func rootViewRendersContent(noticeAccepted: Bool) throws {
        let defaults = InMemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.acceptedNoticeVersion = noticeAccepted ? UsageNotice.version : 0
        let engine = YtDlpClient(engine: try EngineLocator.bundled())
        let model = ExtractViewModel(
            settings: settings, engine: engine, queue: ExtractQueue(engine: engine, notifier: SilentNotifier())
        )
        let view = NSHostingView(rootView: RootView(model: model, settings: settings))
        // 최소 크기(560×500)를 지키는지 확인한 뒤 기본 창 크기로 그린다.
        #expect(view.fittingSize.width >= 560)
        #expect(view.fittingSize.height >= 500)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 540)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        // 화면이 비어 있으면 모든 픽셀이 같은 색이다.
        #expect(Self.distinctPixelCount(in: image) > 10)
    }

    private static func distinctPixelCount(in image: CGImage) -> Int {
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
        var colors = Set<UInt32>()
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            colors.insert(UInt32(pixels[offset]) << 24 | UInt32(pixels[offset + 1]) << 16
                | UInt32(pixels[offset + 2]) << 8 | UInt32(pixels[offset + 3]))
        }
        return colors.count
    }
}
