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

    /// 루트 화면을 실제로 호스팅해 레이아웃까지 수행되는지 확인한다.
    @Test func rootViewLaysOut() {
        let host = NSHostingView(rootView: RootView())
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width >= 420)
        #expect(host.fittingSize.height >= 300)
    }
}
