import CryptoKit
import Foundation

/// yt-dlp stable 릴리스 하나.
struct YtDlpRelease: Sendable, Equatable {
    /// 예: "2026.10.26" (태그와 `yt-dlp --version` 출력이 같다)
    var version: String
    /// zipimport 형식 yt-dlp 파일(`yt-dlp`)
    var binaryURL: URL
    /// 공식 SHA-256 목록(`SHA2-256SUMS`)
    var checksumsURL: URL
}

/// 엔진 업데이트 오류. `errorDescription`은 사용자에게 보여 줄 문구다.
enum EngineUpdateError: Error, Equatable, Sendable {
    case network
    case invalidRelease
    case checksumMismatch
    case validationFailed(String)
    case installFailed(String)
}

extension EngineUpdateError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .network: "업데이트 정보를 받지 못했습니다. 인터넷 연결을 확인해 주세요."
        case .invalidRelease: "업데이트 정보를 해석하지 못했습니다."
        case .checksumMismatch: "받은 엔진 파일이 공식 체크섬과 달라 설치하지 않았습니다."
        case .validationFailed: "받은 엔진을 실행해 보지 못해 설치하지 않았습니다."
        case .installFailed: "엔진을 설치하지 못했습니다."
        }
    }
}

/// HTTP GET. 테스트에서는 가짜 응답을 쓴다.
protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionFetcher: HTTPFetching {
    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        // GitHub API는 User-Agent가 필요하다. 사용자 정보는 넣지 않는다.
        request.setValue("Stow", forHTTPHeaderField: "User-Agent")
        // API 응답 형식 지정은 API 요청에만. 릴리스 파일(리다이렉트되는 CDN) 요청에는 붙이지 않는다.
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineUpdateError.network
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EngineUpdateError.network }
        return data
    }
}

/// 앱 안에서 yt-dlp를 업데이트한다(PROJECT.md MVP 이후 1번).
///
/// - 받은 yt-dlp는 앱 번들 밖 `storage/<버전>/yt-dlp`에 둔다. Python이 읽는 zip 파일이라 서명·Gatekeeper와 무관하다.
/// - 공식 `SHA2-256SUMS`와 대조하고, 번들 Python으로 `--version`을 실행해 태그와 같을 때만 설치한다.
/// - 지금 쓰는 버전은 `storage/current`(버전 문자열)에 기록한다.
struct EngineUpdater: Sendable {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    /// 받은 yt-dlp를 두는 폴더
    let storage: URL
    /// yt-dlp를 실행할 번들 Python
    let python: URL
    var fetcher: any HTTPFetching = URLSessionFetcher()
    var runner = ProcessRunner()

    /// `~/Library/Application Support/<번들 ID>/engine/yt-dlp`
    static func defaultStorage(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "Stow") -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: bundleIdentifier).appending(path: "engine/yt-dlp")
    }

    private var currentFile: URL { storage.appending(path: "current") }

    /// 받아서 설치한 yt-dlp. 없으면 nil.
    func installed() -> (version: String, url: URL)? {
        guard
            let raw = try? String(contentsOf: currentFile, encoding: .utf8),
            case let version = raw.trimmingCharacters(in: .whitespacesAndNewlines),
            Self.isValidVersion(version)
        else { return nil }
        let url = binaryURL(for: version)
        return FileManager.default.isReadableFile(atPath: url.path) ? (version, url) : nil
    }

    /// GitHub에서 최신 stable 릴리스를 확인한다.
    func latestRelease() async throws -> YtDlpRelease {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadURL: URL
                enum CodingKeys: String, CodingKey {
                    case name
                    case browserDownloadURL = "browser_download_url"
                }
            }
            let tagName: String
            let assets: [Asset]
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case assets
            }
        }
        let data = try await fetcher.data(from: Self.latestReleaseAPI)
        guard
            let release = try? JSONDecoder().decode(Release.self, from: data),
            Self.isValidVersion(release.tagName),
            let binary = release.assets.first(where: { $0.name == "yt-dlp" }),
            let sums = release.assets.first(where: { $0.name == "SHA2-256SUMS" })
        else { throw EngineUpdateError.invalidRelease }
        return YtDlpRelease(version: release.tagName, binaryURL: binary.browserDownloadURL, checksumsURL: sums.browserDownloadURL)
    }

    /// yt-dlp 파일을 번들 Python으로 실행해 버전을 읽는다.
    func version(of ytDlp: URL) async throws -> String {
        let result = try await runner.run(python, arguments: ["-I", "-B", "-X", "utf8", ytDlp.path, "--version"])
        guard result.termination.isSuccess, let line = result.stdout.first?.trimmingCharacters(in: .whitespaces),
              Self.isValidVersion(line)
        else { throw EngineUpdateError.validationFailed(result.stderr.joined(separator: "\n")) }
        return line
    }

    /// 릴리스를 받아 검증하고 설치한 뒤, 설치한 파일 경로를 돌려준다.
    func install(_ release: YtDlpRelease) async throws -> URL {
        let binary = try await fetcher.data(from: release.binaryURL)
        let sums = try await fetcher.data(from: release.checksumsURL)
        guard let expected = Self.checksum(named: "yt-dlp", in: sums),
              Self.sha256(of: binary) == expected
        else { throw EngineUpdateError.checksumMismatch }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: storage, withIntermediateDirectories: true)
        } catch {
            throw EngineUpdateError.installFailed(error.localizedDescription)
        }
        // 준비 폴더에 쓰고 검증한 뒤 버전 폴더로 옮긴다(검증 전 파일이 쓰이지 않게).
        let staging = storage.appending(path: ".staging-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        let stagedFile = staging.appending(path: "yt-dlp")
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try binary.write(to: stagedFile)
        } catch {
            throw EngineUpdateError.installFailed(error.localizedDescription)
        }

        let actual = try await version(of: stagedFile)
        guard actual == release.version else {
            throw EngineUpdateError.validationFailed("버전 불일치: \(actual) ≠ \(release.version)")
        }

        let destination = binaryURL(for: release.version)
        do {
            let folder = destination.deletingLastPathComponent()
            if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.moveItem(at: stagedFile, to: destination)
            try Data(release.version.utf8).write(to: currentFile, options: .atomic)
        } catch {
            throw EngineUpdateError.installFailed(error.localizedDescription)
        }
        return destination
    }

    /// `keep` 버전 폴더만 남기고 지운다(nil이면 받은 버전을 모두 지운다).
    /// 실행 중인 yt-dlp가 파일을 읽을 수 있으므로 앱 시작 직후, 추출 전에만 부른다.
    func removeVersions(except keep: String?) {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != "current" && item.lastPathComponent != keep {
            try? fileManager.removeItem(at: item)
        }
        if keep == nil { try? fileManager.removeItem(at: currentFile) }
    }

    /// 받아 둔 버전을 쓰지 않도록 기록(`current`)만 지운다. 실행 중일 수 있는 파일은 다음 앱 시작 때 지운다.
    func clearCurrent() {
        try? FileManager.default.removeItem(at: currentFile)
    }

    private func binaryURL(for version: String) -> URL {
        storage.appending(path: version).appending(path: "yt-dlp")
    }

    // MARK: - 버전·체크섬

    /// yt-dlp 버전 형식: YYYY.MM.DD 또는 YYYY.MM.DD.N (숫자와 점만)
    static func isValidVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (3...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    /// `a`가 `b`보다 새 버전이면 true. 숫자 단위로 비교한다(2026.10.26 < 2026.10.26.1 < 2026.11.2).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = a.split(separator: ".").compactMap { Int($0) }
        let rhs = b.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// `SHA2-256SUMS` 형식("<hex>  <파일명>")에서 파일 하나의 체크섬을 찾는다.
    static func checksum(named name: String, in sums: Data) -> String? {
        let text = String(decoding: sums, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count == 2, fields[1] == name || fields[1] == "*" + name {
                return fields[0].lowercased()
            }
        }
        return nil
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
