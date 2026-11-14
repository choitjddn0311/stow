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

    /// 영상 정보 조회(`-J`): 한 줄 JSON을 stdout에 출력한다.
    func metadata(for url: URL) -> [String] {
        common + ["--dump-single-json", "--", url.absoluteString]
    }

    /// 오디오 추출. 작업 폴더에 `<영상 ID>.<확장자>`로 저장한다(최종 이름은 호출한 쪽에서 정한다).
    func extract(_ url: URL, format: AudioFormat, workDirectory: URL) -> [String] {
        var arguments = common + [
            "--format", "bestaudio/best",
            "--extract-audio",
            "--audio-format", format.fileExtension,
        ]
        if case .mp3(let bitrate) = format {
            arguments += ["--audio-quality", "\(bitrate.rawValue)K"]
        }
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
}
