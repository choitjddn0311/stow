import Foundation
import Testing
@testable import Stow

struct EngineUpdaterVersionTests {
    @Test(arguments: [
        ("2026.11.02", "2026.10.26", true),
        ("2026.10.26.1", "2026.10.26", true),
        ("2026.10.26", "2026.10.26", false),
        ("2026.10.26", "2026.11.02", false),
        ("2027.01.01", "2026.12.31", true),
        ("2026.10.3", "2026.10.26", false),
    ])
    func comparesVersions(_ a: String, _ b: String, _ newer: Bool) {
        #expect(EngineUpdater.isNewer(a, than: b) == newer)
    }

    @Test func validatesVersionFormat() {
        #expect(EngineUpdater.isValidVersion("2026.10.26"))
        #expect(EngineUpdater.isValidVersion("2026.10.26.1"))
        #expect(!EngineUpdater.isValidVersion("2026.10"))
        #expect(!EngineUpdater.isValidVersion("v2026.10.26"))
        #expect(!EngineUpdater.isValidVersion("../2026.10.26"))
        #expect(!EngineUpdater.isValidVersion("2026..26"))
        #expect(!EngineUpdater.isValidVersion("+2026.1.1"))
        #expect(!EngineUpdater.isValidVersion("2026.-1.1"))
    }

    @Test func findsChecksumInSumsFile() {
        let sums = Data("aaa  yt-dlp.tar.gz\nBBB  yt-dlp\nccc  yt-dlp_macos\n".utf8)
        #expect(EngineUpdater.checksum(named: "yt-dlp", in: sums) == "bbb")
        #expect(EngineUpdater.checksum(named: "missing", in: sums) == nil)
    }
}

/// 실제 번들 yt-dlp를 "받은 파일"로 써서 설치 흐름 전체를 네트워크 없이 확인한다.
struct EngineUpdaterInstallTests {
    private let engine = try! EngineLocator.bundled()

    private func makeUpdater(responses: [URL: Data]) throws -> (EngineUpdater, URL) {
        let storage = FileManager.default.temporaryDirectory.appending(path: "stow-engine-\(UUID().uuidString)")
        var updater = EngineUpdater(storage: storage, python: engine.python)
        updater.fetcher = FakeFetcher(responses: responses)
        return (updater, storage)
    }

    private func releaseJSON(tag: String) -> Data {
        Data("""
        {"tag_name": "\(tag)", "assets": [
          {"name": "yt-dlp", "browser_download_url": "https://example.test/yt-dlp"},
          {"name": "SHA2-256SUMS", "browser_download_url": "https://example.test/SHA2-256SUMS"},
          {"name": "yt-dlp_macos", "browser_download_url": "https://example.test/yt-dlp_macos"}
        ]}
        """.utf8)
    }

    private var bundledBinary: Data { try! Data(contentsOf: engine.ytDlp) }

    @Test func installsVerifiedRelease() async throws {
        let binary = bundledBinary
        let bundledVersion = try await EngineUpdater(storage: URL(filePath: "/tmp"), python: engine.python)
            .version(of: engine.ytDlp)
        let (updater, storage) = try makeUpdater(responses: [
            EngineUpdater.latestReleaseAPI: releaseJSON(tag: bundledVersion),
            URL(string: "https://example.test/yt-dlp")!: binary,
            URL(string: "https://example.test/SHA2-256SUMS")!: Data("\(EngineUpdater.sha256(of: binary))  yt-dlp\n".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: storage) }

        #expect(updater.installed() == nil)
        let release = try await updater.latestRelease()
        #expect(release.version == bundledVersion)
        let installed = try await updater.install(release)

        #expect(installed == storage.appending(path: bundledVersion).appending(path: "yt-dlp"))
        #expect(updater.installed()?.version == bundledVersion)
        #expect(try await updater.version(of: installed) == bundledVersion)
        // 준비 폴더는 남지 않는다.
        let items = try FileManager.default.contentsOfDirectory(atPath: storage.path).sorted()
        #expect(items == [bundledVersion, "current"].sorted())
    }

    @Test func rejectsChecksumMismatch() async throws {
        let (updater, storage) = try makeUpdater(responses: [
            EngineUpdater.latestReleaseAPI: releaseJSON(tag: "2099.01.01"),
            URL(string: "https://example.test/yt-dlp")!: bundledBinary,
            URL(string: "https://example.test/SHA2-256SUMS")!: Data("\(String(repeating: "0", count: 64))  yt-dlp\n".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: storage) }
        let release = try await updater.latestRelease()
        await #expect(throws: EngineUpdateError.checksumMismatch) { try await updater.install(release) }
        #expect(updater.installed() == nil)
    }

    /// 체크섬은 맞아도 실행해 본 버전이 태그와 다르면 설치하지 않는다.
    @Test func rejectsVersionMismatch() async throws {
        let binary = bundledBinary
        let (updater, storage) = try makeUpdater(responses: [
            EngineUpdater.latestReleaseAPI: releaseJSON(tag: "2099.01.01"),
            URL(string: "https://example.test/yt-dlp")!: binary,
            URL(string: "https://example.test/SHA2-256SUMS")!: Data("\(EngineUpdater.sha256(of: binary))  yt-dlp\n".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: storage) }
        let release = try await updater.latestRelease()
        await #expect(throws: EngineUpdateError.self) { try await updater.install(release) }
        #expect(updater.installed() == nil)
        #expect(!FileManager.default.fileExists(atPath: storage.appending(path: "2099.01.01").path))
    }

    @Test func rejectsMalformedRelease() async throws {
        let (updater, storage) = try makeUpdater(responses: [
            EngineUpdater.latestReleaseAPI: Data(#"{"tag_name": "../evil", "assets": []}"#.utf8),
        ])
        defer { try? FileManager.default.removeItem(at: storage) }
        await #expect(throws: EngineUpdateError.invalidRelease) { try await updater.latestRelease() }
    }

    @Test func removesUnusedVersions() async throws {
        let (updater, storage) = try makeUpdater(responses: [:])
        defer { try? FileManager.default.removeItem(at: storage) }
        let fileManager = FileManager.default
        for version in ["2026.01.01", "2026.02.02"] {
            let folder = storage.appending(path: version)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: "yt-dlp"))
        }
        try fileManager.createDirectory(at: storage.appending(path: ".staging-old"), withIntermediateDirectories: true)
        try Data("2026.02.02".utf8).write(to: storage.appending(path: "current"))

        #expect(updater.installed()?.version == "2026.02.02")
        updater.removeVersions(except: "2026.02.02")
        #expect(try fileManager.contentsOfDirectory(atPath: storage.path).sorted() == ["2026.02.02", "current"])

        updater.removeVersions(except: nil)
        #expect(try fileManager.contentsOfDirectory(atPath: storage.path).isEmpty)
        #expect(updater.installed() == nil)
    }

    /// EngineSource를 바꾸면 그다음 작업부터 새 yt-dlp를 쓴다.
    @Test func clientUsesUpdatedEngineSource() async throws {
        let source = EngineSource(engine)
        var client = YtDlpClient(engine: engine)
        client.engineSource = source
        let missing = URL(filePath: "/nonexistent/yt-dlp")
        source.update(engine.replacingYtDlp(with: missing))
        // 존재하지 않는 yt-dlp를 가리키면 조회가 실패한다 = 바뀐 엔진을 쓰고 있다.
        await #expect(throws: EngineError.self) {
            try await client.fetchMetadata(for: URL(string: "https://youtu.be/abc")!)
        }
    }
}

/// 실제 GitHub API로 최신 릴리스 정보를 읽는다(설치는 하지 않음). 네트워크 테스트를 켤 때만 실행한다.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STOW_NETWORK_TEST_URL"] != nil))
struct EngineUpdaterNetworkTests {
    @Test func readsLatestStableRelease() async throws {
        let engine = try EngineLocator.bundled()
        let updater = EngineUpdater(storage: FileManager.default.temporaryDirectory, python: engine.python)
        let release = try await updater.latestRelease()
        print("[network test] yt-dlp latest stable: \(release.version)")
        #expect(EngineUpdater.isValidVersion(release.version))
        #expect(release.binaryURL.lastPathComponent == "yt-dlp")
    }

    /// 실제 릴리스 파일과 SHA2-256SUMS를 받아 임시 폴더에 설치해 본다(앱 저장소는 건드리지 않음).
    @Test func installsLatestStableIntoTemporaryFolder() async throws {
        let engine = try EngineLocator.bundled()
        let storage = FileManager.default.temporaryDirectory.appending(path: "stow-engine-net-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }
        let updater = EngineUpdater(storage: storage, python: engine.python)
        let release = try await updater.latestRelease()
        let installed = try await updater.install(release)
        print("[network test] installed yt-dlp \(release.version) → \(installed.lastPathComponent)")
        #expect(try await updater.version(of: installed) == release.version)
        #expect(updater.installed()?.version == release.version)
    }
}

private struct FakeFetcher: HTTPFetching {
    let responses: [URL: Data]

    func data(from url: URL) async throws -> Data {
        guard let data = responses[url] else { throw EngineUpdateError.network }
        return data
    }
}
