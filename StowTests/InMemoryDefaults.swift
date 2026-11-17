import Foundation
import Testing
@testable import Stow

/// 디스크에 쓰지 않는 테스트용 `UserDefaults`.
///
/// `UserDefaults(suiteName:)`로 테스트마다 새 이름을 만들면 `~/Library/Preferences`에 설정 파일이 하나씩 쌓인다.
/// 이 클래스는 값을 메모리에만 두고, 테스트가 끝나 객체가 사라지면 같이 사라진다.
/// 같은 저장소를 다시 여는 상황(앱 재시작)은 같은 인스턴스를 다시 넘겨 흉내 낸다.
///
/// `string(forKey:)`·`integer(forKey:)`·`set(_: Int, forKey:)` 같은 편의 메서드는 Foundation이
/// `object(forKey:)`·`set(_: Any?, forKey:)`로 처리하므로, 이 둘과 `removeObject(forKey:)`만 바꾸면 된다.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    /// 덮어쓰지 않은 메서드가 혹시 쓰더라도 앱 설정과 섞이지 않게 하는 빈 영역(실제로는 쓰이지 않아야 한다).
    static let backingSuiteName = "stow-tests-in-memory"

    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: Self.backingSuiteName)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        lock.withLock { values[defaultName] = nil }
    }
}

/// 메모리 전용 저장소가 앱이 쓰는 방식 그대로 동작하는지 확인한다.
@MainActor
struct InMemoryDefaultsTests {
    @Test func typedAccessorsRoundTripInMemory() {
        let defaults = InMemoryDefaults()
        defaults.set("mp3", forKey: "string")
        defaults.set(320, forKey: "int")
        defaults.set(["a", "b"], forKey: "array")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(date, forKey: "date")

        #expect(defaults.string(forKey: "string") == "mp3")
        #expect(defaults.integer(forKey: "int") == 320)
        #expect(defaults.stringArray(forKey: "array") == ["a", "b"])
        #expect(defaults.object(forKey: "date") as? Date == date)
        #expect(defaults.integer(forKey: "missing") == 0)

        defaults.removeObject(forKey: "string")
        #expect(defaults.string(forKey: "string") == nil)
        // 다른 인스턴스와 값이 섞이지 않는다.
        #expect(InMemoryDefaults().string(forKey: "array") == nil)
    }

    /// 앱 설정(AppSettings)이 쓰는 값이 디스크(뒤에 있는 영역)로 새지 않는다.
    @Test func appSettingsNeverWritesToDisk() throws {
        let defaults = InMemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.formatKind = .flac
        settings.mp3Bitrate = .kbps192
        settings.acceptedNoticeVersion = 3
        settings.outputDirectory = FileManager.default.temporaryDirectory

        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.formatKind == .flac)
        #expect(reopened.mp3Bitrate == .kbps192)
        #expect(reopened.acceptedNoticeVersion == 3)

        let backing = try #require(UserDefaults(suiteName: InMemoryDefaults.backingSuiteName))
        #expect(backing.dictionaryRepresentation().keys.contains("formatKind") == false)
        #expect(backing.persistentDomain(forName: InMemoryDefaults.backingSuiteName)?.isEmpty ?? true)
    }
}
