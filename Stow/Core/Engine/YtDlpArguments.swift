import Foundation

/// yt-dlp 인자 생성. 인자는 배열로만 만들고 셸 문자열을 조합하지 않는다.
struct YtDlpArguments: Sendable {
    let engine: EngineLocator
    /// 테스트에서 추가 옵션(예: 로컬 파일용 `--enable-file-urls`)을 넣을 때 쓴다.
    var additional: [String] = []

    /// 모든 실행에 공통으로 넣는 인자.
    var common: [String] {
        [
            // 사용자의 yt-dlp 설정 파일(~/.config/yt-dlp 등)을 읽지 않는다.
            "--ignore-config",
            "--no-playlist",
            "--color", "never",
            "--ffmpeg-location", engine.ffmpegDirectory.path,
            "--js-runtimes", "deno:" + engine.deno.path,
        ] + additional
    }

    /// 영상·재생목록 조회(`-J`): 한 줄 JSON을 stdout에 출력한다. `FetchedMedia`가 `_type`으로 구분한다.
    /// - 영상 주소(`watch?v=…&list=…` 포함): 공통 인자의 `--no-playlist` 때문에 영상 하나로 조회된다.
    /// - 재생목록 주소(`/playlist?list=…`): `--no-playlist`와 관계없이 재생목록으로 조회된다.
    ///   `--flat-playlist`로 각 영상을 조회하지 않고 목록만 읽고, `--playlist-end`로 처음 `Playlist.maxEntries`개까지만 읽는다.
    func metadata(for url: URL) -> [String] {
        common + [
            "--dump-single-json", "--flat-playlist", "--playlist-end", String(Playlist.maxEntries),
            "--", url.absoluteString,
        ]
    }

    /// 오디오 추출 또는 영상 다운로드. 작업 폴더에 `<영상 ID>.<확장자>`로 저장한다(최종 이름은 호출한 쪽에서 정한다).
    func extract(_ url: URL, format: OutputFormat, workDirectory: URL) -> [String] {
        var arguments = common + Self.formatArguments(for: format)
        arguments += [
            "--embed-metadata",
            // 중간 파일과 결과 파일을 모두 작업 폴더에 둔다. "home:"을 붙여 경로의 ":"가 형식 구분자로 해석되지 않게 한다.
            "--paths", "home:" + workDirectory.path,
            "--paths", "temp:" + workDirectory.path,
            "--output", "%(id)s.%(ext)s",
            "--newline",
            // --print는 --quiet를 함께 켜므로 진행률 출력을 다시 켠다.
            "--progress",
            "--progress-template", ProgressParser.downloadTemplate,
            "--progress-template", ProgressParser.postprocessTemplate,
            "--print", ProgressParser.fileTemplate,
            "--",
            url.absoluteString,
        ]
        return arguments
    }

    /// 포맷별 선택·변환 인자.
    static func formatArguments(for format: OutputFormat) -> [String] {
        switch format {
        case .mp3(let bitrate):
            ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "mp3",
             "--audio-quality", "\(bitrate.rawValue)K"]
        case .wav:
            ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "wav"]
        case .flac:
            ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "flac"]
        case .video(.mp4, let resolution):
            // H.264 영상 + AAC(m4a) 오디오만 고른다. 둘로 나뉜 스트림이 없으면 처음부터 합쳐진 MP4.
            // 다시 인코딩하지 않고 MP4로 합친다.
            ["--format", "bv*[vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4]"]
                + sortArguments(resolution)
                + ["--merge-output-format", "mp4"]
        case .video(.best, let resolution):
            // 코덱과 관계없이 가장 좋은 영상 + 오디오. 담을 수 있는 형식 중 MP4를 먼저, 안 되면 WebM, 그다음 MKV.
            ["--format", "bv*+ba/b"]
                + sortArguments(resolution)
                + ["--merge-output-format", "mp4/webm/mkv"]
        }
    }

    /// `-S res:N`: N 이하 중 가장 높은 해상도를 고르고, 그런 것이 없으면 N보다 높은 것 중 가장 낮은 것.
    private static func sortArguments(_ resolution: VideoResolution) -> [String] {
        resolution == .best ? [] : ["--format-sort", "res:\(resolution.rawValue)"]
    }
}
