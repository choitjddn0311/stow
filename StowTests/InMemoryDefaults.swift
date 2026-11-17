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
/// `object(forKey:)`·`set(_: Any?, forKey:)`로 처리하므로, 이 둘과 `removeObject(forKey:)`만 바꾸면 된다
/// (앱이 쓰는 것은 `InMemoryDefaultsTests`가 확인한다).
///
/// 실제 저장소처럼 값을 프로퍼티 목록으로 직렬화했다가 다시 읽어 보관한다. 그래서 저장할 수 없는 값은 실제처럼 실패하고,
/// 읽을 때는 저장한 객체가 아니라 복사본이 나온다. `register(defaults:)`·변경 알림(KVO)은 흉내 내지 않는다(앱이 쓰지 않음).
/// 실제 디스크 저장·읽기는 `AppSettingsTests.persistsOnDisk`가 진짜 저장소로 확인한다.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    /// 덮어쓰지 않은 메서드가 혹시 쓰더라도 앱 설정과 섞이지 않게 하는 빈 영역(실제로는 쓰이지 않아야 한다).
    static let backingSuiteName = "stow-tests-in-memory"

    private let lock = NSLock()
    private var values: [String: Any] = [:]

    /// 테스트 기본 저장 폴더. 앱 기본값(사용자의 "다운로드")을 쓰면 재생목록을 대기열에 넣는 테스트가
    /// 실제 다운로드 폴더에 재생목록 이름의 폴더를 만든다.
    static let testOutputDirectory = FileManager.default.temporaryDirectory
        .appending(path: "stow-tests-output", directoryHint: .isDirectory)

    /// - Parameter keepAppDefaults: true면 저장 폴더도 비워 앱 기본값(다운로드 폴더)을 그대로 확인할 수 있게 한다.
    init(keepAppDefaults: Bool = false) {
        super.init(suiteName: Self.backingSuiteName)!
        if !keepAppDefaults {
            try? FileManager.default.createDirectory(at: Self.testOutputDirectory, withIntermediateDirectories: true)
            values["outputDirectory"] = Self.testOutputDirectory.path
        }
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard let value else {
            removeObject(forKey: defaultName)
            return
        }
        // 실제 UserDefaults는 프로퍼티 목록이 아닌 값을 받으면 예외로 멈춘다. 테스트도 같은 버그를 잡도록 실패시킨다.
        guard let data = try? PropertyListSerialization.data(fromPropertyList: [defaultName: value], format: .binary, options: 0),
              let copy = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?[defaultName]
        else {
            preconditionFailure("InMemoryDefaults: '\(defaultName)'에 프로퍼티 목록이 아닌 값을 저장함: \(type(of: value))")
        }
        lock.withLock { values[defaultName] = copy }
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

        defaults.set(true, forKey: "bool")
        defaults.set(1.5, forKey: "double")
        #expect(defaults.bool(forKey: "bool"))
        #expect(defaults.double(forKey: "double") == 1.5)

        // 저장한 객체가 아니라 복사본이 나온다(실제 저장소와 같다).
        let mutable = NSMutableArray(array: ["x"])
        defaults.set(mutable, forKey: "copied")
        mutable.add("y")
        #expect(defaults.stringArray(forKey: "copied") == ["x"])

        defaults.removeObject(forKey: "string")
        #expect(defaults.string(forKey: "string") == nil)
        defaults.set(nil, forKey: "int")
        #expect(defaults.object(forKey: "int") == nil)
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

        // 덮어쓰지 않은 메서드로 새는 값이 있으면 뒤쪽 영역의 설정 파일이 생긴다.
        let backing = try #require(UserDefaults(suiteName: InMemoryDefaults.backingSuiteName))
        #expect(backing.persistentDomain(forName: InMemoryDefaults.backingSuiteName)?["formatKind"] == nil)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/\(InMemoryDefaults.backingSuiteName).plist")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
