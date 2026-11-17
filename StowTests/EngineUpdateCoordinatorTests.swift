import AppKit
import Foundation
import Testing
@testable import Stow

/// 엔진 업데이트 흐름(활성화·자동 확인·되돌리기). 실제 번들 yt-dlp를 "받은 파일"로 쓰고 네트워크는 가짜 응답.
@MainActor
struct EngineUpdateCoordinatorTests {
    private let engine = try! EngineLocator.bundled()
    /// 실제 번들 yt-dlp 버전(테스트에서 "새 버전" 역할)
    private let realVersion: String

    init() async throws {
        realVersion = try await EngineUpdater(storage: URL(filePath: "/tmp"), python: try! EngineLocator.bundled().python)
            .version(of: try! EngineLocator.bundled().ytDlp)
    }

    private final class Recorder {
        var messages: [String] = []
    }

    private struct Fixture {
        let storage: URL
        let defaults: UserDefaults
        let source: EngineSource
        let updater: EngineUpdater
        let recorder: Recorder
    }

    private func makeFixture(latestTag: String? = nil, failNetwork: Bool = false) throws -> Fixture {
        let storage = FileManager.default.temporaryDirectory.appending(path: "stow-coord-\(UUID().uuidString)")
        let binary = try Data(contentsOf: engine.ytDlp)
        var responses: [URL: Data] = [:]
        if let latestTag, !failNetwork {
            responses[EngineUpdater.latestReleaseAPI] = Data("""
            {"tag_name": "\(latestTag)", "assets": [
              {"name": "yt-dlp", "browser_download_url": "https://example.test/yt-dlp"},
              {"name": "SHA2-256SUMS", "browser_download_url": "https://example.test/SHA2-256SUMS"}]}
            """.utf8)
            responses[URL(string: "https://example.test/yt-dlp")!] = binary
            responses[URL(string: "https://example.test/SHA2-256SUMS")!] = Data("\(EngineUpdater.sha256(of: binary))  yt-dlp\n".utf8)
        }
        var updater = EngineUpdater(storage: storage, python: engine.python)
        updater.fetcher = CoordinatorFakeFetcher(responses: responses)
        return Fixture(
            storage: storage,
            defaults: InMemoryDefaults(),
            source: EngineSource(engine),
            updater: updater,
            recorder: Recorder()
        )
    }

    private func coordinator(_ fixture: Fixture, bundledVersion: String) -> EngineUpdateCoordinator {
        let recorder = fixture.recorder
        return EngineUpdateCoordinator(
            updater: fixture.updater, source: fixture.source, bundled: engine, defaults: fixture.defaults,
            bundledVersion: bundledVersion, present: { message, _, _ in recorder.messages.append(message) }
        )
    }

    /// 실제 번들 파일을 realVersion으로 설치해 둔다.
    private func preinstall(_ fixture: Fixture) async throws {
        let setup = try makeFixture(latestTag: realVersion)
        var updater = fixture.updater
        updater.fetcher = setup.updater.fetcher
        _ = try await updater.install(try await updater.latestRelease())
    }

    // MARK: - 앱 시작 시 활성화

    @Test func activatesNewerValidInstalledVersion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        try await preinstall(fixture)

        let sut = coordinator(fixture, bundledVersion: "2000.01.01")
        await sut.activateInstalled()
        #expect(sut.isUsingDownloadedEngine)
        #expect(sut.activeVersion == realVersion)
        #expect(fixture.source.current.ytDlp == fixture.storage.appending(path: realVersion).appending(path: "yt-dlp"))
    }

    @Test func dropsInstalledVersionNotNewerThanBundle() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        try await preinstall(fixture)

        let sut = coordinator(fixture, bundledVersion: realVersion)  // 앱 업데이트로 번들이 같아진 경우
        await sut.activateInstalled()
        #expect(!sut.isUsingDownloadedEngine)
        #expect(fixture.updater.installed() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.storage.path).isEmpty)
    }

    @Test func dropsCorruptInstalledVersion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let folder = fixture.storage.appending(path: "2099.01.01")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a zip".utf8).write(to: folder.appending(path: "yt-dlp"))
        try Data("2099.01.01".utf8).write(to: fixture.storage.appending(path: "current"))

        let sut = coordinator(fixture, bundledVersion: "2000.01.01")
        await sut.activateInstalled()
        #expect(!sut.isUsingDownloadedEngine)
        #expect(fixture.updater.installed() == nil)
    }

    @Test func activatesOnlyOncePerLaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let sut = coordinator(fixture, bundledVersion: "2000.01.01")
        await sut.activateInstalled()
        // 첫 활성화 뒤에 설치된 버전(실행 중일 수 있음)은 두 번째 호출이 지우지 않는다.
        try await preinstall(fixture)
        await sut.activateInstalled()
        #expect(fixture.updater.installed()?.version == realVersion)
    }

    // MARK: - 자동 확인

    @Test func installsNewerReleaseAndRecordsCheck() async throws {
        let fixture = try makeFixture(latestTag: realVersion)
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let sut = coordinator(fixture, bundledVersion: "2000.01.01")
        await sut.activateInstalled()

        await sut.performCheck(manual: false)
        #expect(sut.isUsingDownloadedEngine)
        #expect(sut.activeVersion == realVersion)
        #expect(fixture.defaults.object(forKey: EngineUpdateCoordinator.lastCheckKey) != nil)
        #expect(fixture.recorder.messages.isEmpty)  // 자동 확인은 조용히
    }

    @Test func failedCheckIsRetriedLater() async throws {
        let fixture = try makeFixture(failNetwork: true)
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let sut = coordinator(fixture, bundledVersion: "2000.01.01")
        await sut.activateInstalled()

        await sut.performCheck(manual: false)
        #expect(fixture.defaults.object(forKey: EngineUpdateCoordinator.lastCheckKey) == nil)
        #expect(!sut.isUsingDownloadedEngine)
    }

    @Test func upToDateCheckIsRecordedAndReportedWhenManual() async throws {
        let fixture = try makeFixture(latestTag: realVersion)
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let sut = coordinator(fixture, bundledVersion: realVersion)
        await sut.activateInstalled()

        await sut.performCheck(manual: true)
        #expect(!sut.isUsingDownloadedEngine)
        #expect(fixture.recorder.messages == ["추출 엔진이 최신 버전입니다."])
        #expect(fixture.defaults.object(forKey: EngineUpdateCoordinator.lastCheckKey) != nil)
    }

    // MARK: - 되돌리기

    @Test func revertReturnsToBundleAndSkipsThatVersion() async throws {
        let fixture = try makeFixture(latestTag: realVersion)
        defer { try? FileManager.default.removeItem(at: fixture.storage) }
        let sut = coordinator(fixture, bundledVersion: "2000.01.01")
        await sut.activateInstalled()
        await sut.performCheck(manual: false)
        #expect(sut.isUsingDownloadedEngine)

        sut.revertToBundled()
        #expect(!sut.isUsingDownloadedEngine)
        #expect(fixture.defaults.string(forKey: EngineUpdateCoordinator.rejectedVersionKey) == realVersion)
        #expect(fixture.updater.installed() == nil)

        // 같은 버전은 자동으로 다시 설치하지 않는다.
        fixture.defaults.removeObject(forKey: EngineUpdateCoordinator.lastCheckKey)
        await sut.performCheck(manual: false)
        #expect(!sut.isUsingDownloadedEngine)
    }
}

private struct CoordinatorFakeFetcher: HTTPFetching {
    let responses: [URL: Data]

    func data(from url: URL) async throws -> Data {
        guard let data = responses[url] else { throw EngineUpdateError.network }
        return data
    }
}
