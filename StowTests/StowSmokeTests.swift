import Foundation
import Testing
@testable import Stow

/// 1단계 기반 구축 확인용 스모크 테스트.
@MainActor
struct StowSmokeTests {
    @Test func hostAppBundleIsLoaded() {
        #expect(Bundle.main.bundleIdentifier == "com.example.stow")
    }

    @Test func minimumSystemVersionIs14() throws {
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String)
        #expect(version.hasPrefix("14.0"))
    }

    @Test func rootViewCanBeCreated() {
        _ = RootView().body
    }
}
