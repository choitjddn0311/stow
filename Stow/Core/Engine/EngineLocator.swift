import Foundation

/// 앱 번들에 포함된 엔진 실행 파일의 위치.
///
/// 번들 구조(`Contents/Resources/bin/`, `scripts/embed-engine.sh`가 복사·서명):
/// - `python/bin/python3`: yt-dlp 실행용 Python 런타임
/// - `yt-dlp`: zipimport 형식 yt-dlp(Python으로 실행)
/// - `ffmpeg`, `ffprobe`: LGPL 빌드
/// - `deno`: yt-dlp의 유튜브 JavaScript 처리용 런타임
struct EngineLocator: Sendable, Equatable {
    let python: URL
    let ytDlp: URL
    let ffmpeg: URL
    let ffprobe: URL
    let deno: URL
    /// 번들 yt-dlp 버전(`bin/yt-dlp.version`, `fetch-binaries.sh`가 기록). 없으면 nil.
    let bundledYtDlpVersion: String?

    /// `binDirectory`에서 구성 요소를 찾고, 모두 있는지 확인한다.
    init(binDirectory: URL) throws(EngineError) {
        python = binDirectory.appending(path: "python/bin/python3")
        ytDlp = binDirectory.appending(path: "yt-dlp")
        ffmpeg = binDirectory.appending(path: "ffmpeg")
        ffprobe = binDirectory.appending(path: "ffprobe")
        deno = binDirectory.appending(path: "deno")
        bundledYtDlpVersion = (try? String(contentsOf: binDirectory.appending(path: "yt-dlp.version"), encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { EngineUpdater.isValidVersion($0) ? $0 : nil }

        let fileManager = FileManager.default
        for executable in [python, ffmpeg, ffprobe, deno]
        where !fileManager.isExecutableFile(atPath: executable.path) {
            throw .missingComponent(executable.lastPathComponent)
        }
        // yt-dlp는 Python이 읽는 zip 파일이므로 실행 권한이 필요 없다.
        if !fileManager.isReadableFile(atPath: ytDlp.path) {
            throw .missingComponent(ytDlp.lastPathComponent)
        }
    }

    private init(python: URL, ytDlp: URL, ffmpeg: URL, ffprobe: URL, deno: URL, bundledYtDlpVersion: String?) {
        self.bundledYtDlpVersion = bundledYtDlpVersion
        self.python = python
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.deno = deno
    }

    /// yt-dlp만 다른 파일(앱 안에서 업데이트한 버전)로 바꾼 엔진. 나머지는 번들 것을 쓴다.
    func replacingYtDlp(with url: URL) -> EngineLocator {
        EngineLocator(
            python: python, ytDlp: url, ffmpeg: ffmpeg, ffprobe: ffprobe, deno: deno, bundledYtDlpVersion: bundledYtDlpVersion
        )
    }

    /// 앱 번들(`Contents/Resources/bin`)에 포함된 엔진.
    static func bundled(in bundle: Bundle = .main) throws(EngineError) -> EngineLocator {
        guard let resources = bundle.resourceURL else { throw .missingComponent("bin") }
        return try EngineLocator(binDirectory: resources.appending(path: "bin"))
    }

    /// `--ffmpeg-location`에 넘길 디렉터리(ffmpeg, ffprobe가 있는 곳).
    var ffmpegDirectory: URL { ffmpeg.deletingLastPathComponent() }

    /// yt-dlp를 실행하기 위한 실행 파일과 인자.
    ///
    /// - `-I`: 격리 모드. `PYTHON*` 환경 변수, 사용자 site-packages, 현재 디렉터리를 무시한다.
    /// - `-B`: `.pyc`를 쓰지 않는다. 서명된 번들 안에 파일이 생기면 서명이 깨진다.
    /// - `-X utf8`: 로케일과 관계없이 입출력을 UTF-8로 한다(Finder에서 실행하면 LANG이 없다).
    func ytDlpCommand(_ arguments: [String]) -> (executable: URL, arguments: [String]) {
        (python, ["-I", "-B", "-X", "utf8", ytDlp.path] + arguments)
    }
}
