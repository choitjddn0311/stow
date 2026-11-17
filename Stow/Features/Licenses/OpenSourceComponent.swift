import Foundation

/// 앱에 함께 넣어 배포하는 오픈소스 구성 요소와 라이선스 원문 위치. "오픈소스 라이선스" 창에 보여 준다.
struct OpenSourceComponent: Identifiable, Hashable, Sendable {
    /// 라이선스 원문 파일 하나(앱 번들 Resources 기준 경로)
    struct LicenseFile: Hashable, Sendable {
        let title: String
        let resourcePath: String
    }

    let id: String
    let name: String
    let purpose: String
    let license: String
    let homepage: URL
    let licenseFiles: [LicenseFile]
    /// LGPL처럼 바이너리와 함께 소스를 제공해야 하는 구성 요소. 이 버전의 GitHub 릴리스에 원본 소스를 올린다(release.sh).
    let providesSource: Bool

    /// 앱에 들어 있는 구성 요소 전체(README "오픈소스 구성 요소"와 같은 목록)
    static let all: [OpenSourceComponent] = [
        OpenSourceComponent(
            id: "yt-dlp", name: "yt-dlp", purpose: "영상 정보 조회, 다운로드",
            license: "Unlicense (일부 MIT·ISC)", homepage: URL(string: "https://github.com/yt-dlp/yt-dlp")!,
            licenseFiles: [
                LicenseFile(title: "라이선스", resourcePath: "bin/licenses/yt-dlp-LICENSE.txt"),
                LicenseFile(title: "포함된 코드", resourcePath: "bin/licenses/yt-dlp-THIRD_PARTY_LICENSES.txt"),
            ],
            providesSource: false
        ),
        OpenSourceComponent(
            id: "python", name: "Python", purpose: "yt-dlp 실행",
            license: "PSF 라이선스 등", homepage: URL(string: "https://www.python.org")!,
            licenseFiles: [LicenseFile(title: "라이선스", resourcePath: "bin/licenses/python-LICENSE.txt")],
            providesSource: false
        ),
        OpenSourceComponent(
            id: "deno", name: "deno", purpose: "유튜브 JavaScript 처리",
            license: "MIT", homepage: URL(string: "https://deno.com")!,
            licenseFiles: [LicenseFile(title: "라이선스", resourcePath: "bin/licenses/deno-LICENSE.md")],
            providesSource: false
        ),
        OpenSourceComponent(
            id: "ffmpeg", name: "FFmpeg", purpose: "오디오 변환",
            license: "LGPL 2.1 이상", homepage: URL(string: "https://ffmpeg.org")!,
            licenseFiles: [
                LicenseFile(title: "안내", resourcePath: "bin/licenses/ffmpeg-LICENSE.md"),
                LicenseFile(title: "LGPL 2.1", resourcePath: "bin/licenses/ffmpeg-COPYING.LGPLv2.1.txt"),
            ],
            providesSource: true
        ),
        OpenSourceComponent(
            id: "lame", name: "LAME", purpose: "MP3 인코딩",
            license: "LGPL", homepage: URL(string: "https://lame.sourceforge.io")!,
            licenseFiles: [LicenseFile(title: "라이선스", resourcePath: "bin/licenses/lame-COPYING.txt")],
            providesSource: true
        ),
        OpenSourceComponent(
            id: "sparkle", name: "Sparkle", purpose: "앱 자동 업데이트",
            license: "MIT (일부 BSD·zlib)", homepage: URL(string: "https://sparkle-project.org")!,
            licenseFiles: [LicenseFile(title: "라이선스", resourcePath: "Sparkle-LICENSE.txt")],
            providesSource: false
        ),
        OpenSourceComponent(
            id: "keyboardshortcuts", name: "KeyboardShortcuts", purpose: "빠른 추출 전역 단축키",
            license: "MIT", homepage: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!,
            licenseFiles: [LicenseFile(title: "라이선스", resourcePath: "KeyboardShortcuts-LICENSE.txt")],
            providesSource: false
        ),
    ]

    /// 홈페이지 주소를 "github.com/yt-dlp/yt-dlp"처럼 스킴 없이 보여 준다(호스트가 같은 항목끼리 구분되게).
    var homepageLabel: String {
        let host = homepage.host() ?? homepage.absoluteString
        let path = homepage.path()
        return path.isEmpty || path == "/" ? host : host + path
    }

    /// 이 버전 앱의 GitHub 릴리스 페이지. LGPL 구성 요소의 원본 소스를 DMG와 같은 곳에 올린다.
    /// 버전을 모르면(또는 형식이 다르면) 릴리스 목록으로 보낸다. 아직 공개하지 않은 버전(개발 빌드)은 페이지가 없다.
    static func sourceReleaseURL(version: String?) -> URL {
        let releases = AppLinks.releases.absoluteString
        guard let version, version.wholeMatch(of: /\d+(\.\d+)*/) != nil else { return AppLinks.releases }
        return URL(string: "\(releases)/tag/v\(version)")!
    }
}

extension OpenSourceComponent.LicenseFile {
    func url(in bundle: Bundle) -> URL? {
        bundle.resourceURL?.appending(path: resourcePath)
    }
}
