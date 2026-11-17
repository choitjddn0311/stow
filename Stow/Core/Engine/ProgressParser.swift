import Foundation

/// 내려받는 스트림. 영상은 영상·오디오 스트림을 따로 받은 뒤 합친다.
enum DownloadPart: Sendable, Equatable {
    /// 영상만 있는 스트림
    case video
    /// 오디오만 있는 스트림(오디오 추출도 이것)
    case audio
    /// 영상과 오디오가 함께 든 스트림(합칠 필요 없음) 또는 알 수 없음
    case combined
}

/// 진행률(0...1)을 화면에 보이는 정수 백분율로. 문구·화면 읽기·대기열 갱신 판단이 같은 값을 쓴다.
func displayPercent(_ fraction: Double) -> Int {
    Int((fraction * 100).rounded())
}

/// 추출 진행 상황.
enum ExtractProgress: Sendable, Equatable {
    /// 내려받는 중. `fraction`은 0...1, 전체 크기를 모르면 nil.
    case downloading(fraction: Double?, bytesPerSecond: Double?, secondsRemaining: Int?, part: DownloadPart = .combined)
    /// 선택한 포맷으로 변환하는 중(ffmpeg).
    case converting
    /// 영상과 오디오를 한 파일로 합치는 중(ffmpeg, 다시 인코딩하지 않음).
    case merging
    /// 메타데이터(제목·아티스트·챕터)를 넣는 중.
    case embeddingMetadata
}

/// yt-dlp 출력 한 줄을 해석한다. `YtDlpArguments`가 지정한 템플릿에 맞춘 줄만 인식하고 나머지는 무시한다.
/// yt-dlp의 기본 진행률 문구는 버전에 따라 바뀔 수 있으므로 직접 정한 표식(`[stow:...]`)을 쓴다.
enum ProgressParser {
    enum Event: Sendable, Equatable {
        case progress(ExtractProgress)
        /// 최종 결과 파일 경로(`--print after_move:`).
        case outputFile(String)
    }

    static let downloadMarker = "[stow:download]"
    static let postprocessMarker = "[stow:postprocess]"
    static let fileMarker = "[stow:file]"

    /// 다운로드 진행률 템플릿: 상태, 받은 바이트, 전체 바이트, 추정 전체 바이트, 속도(B/s), 남은 시간(초),
    /// 받는 스트림의 영상·오디오 코덱(없으면 `none`). 값이 없으면 yt-dlp가 `NA`를 출력한다.
    static let downloadTemplate = "download:\(downloadMarker) %(progress.status)s %(progress.downloaded_bytes)s "
        + "%(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s "
        + "%(info.vcodec)s %(info.acodec)s"
    /// 후처리 진행 템플릿: 상태(started/finished), 후처리기 이름.
    static let postprocessTemplate = "postprocess:\(postprocessMarker) %(progress.status)s %(progress.postprocessor)s"
    /// 최종 파일 경로 출력 템플릿.
    static let fileTemplate = "after_move:\(fileMarker) %(filepath)s"

    static func parse(_ line: String) -> Event? {
        if let rest = line.dropPrefix(fileMarker + " ") {
            return rest.isEmpty ? nil : .outputFile(rest)
        }
        if let rest = line.dropPrefix(downloadMarker + " ") {
            return parseDownload(rest).map { .progress($0) }
        }
        if let rest = line.dropPrefix(postprocessMarker + " ") {
            return parsePostprocess(rest).map { .progress($0) }
        }
        return nil
    }

    private static func parseDownload(_ fields: String) -> ExtractProgress? {
        let values = fields.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // 코덱 두 칸은 없어도 읽는다(합친 스트림으로 본다).
        guard values.count == 6 || values.count == 8 else { return nil }
        let status = values[0]
        let downloaded = Double(values[1])
        let total = Double(values[2]) ?? Double(values[3])
        let speed = Double(values[4])
        let eta = Double(values[5]).map { Int($0.rounded()) }

        let fraction: Double?
        if status == "finished" {
            fraction = 1
        } else if let downloaded, let total, total > 0 {
            fraction = min(max(downloaded / total, 0), 1)
        } else {
            fraction = nil
        }
        let part: DownloadPart = switch values.count == 8 ? (values[6], values[7]) : ("", "") {
        case ("none", _): .audio
        case (_, "none"): .video
        default: .combined
        }
        return .downloading(fraction: fraction, bytesPerSecond: speed, secondsRemaining: eta, part: part)
    }

    private static func parsePostprocess(_ fields: String) -> ExtractProgress? {
        let values = fields.split(separator: " ").map(String.init)
        guard values.count == 2, values[0] == "started" else { return nil }
        switch values[1] {
        case "ExtractAudio": return .converting
        case "Merger": return .merging
        case "Metadata": return .embeddingMetadata
        default: return nil
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
