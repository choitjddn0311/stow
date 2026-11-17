import Foundation

/// MP3 비트레이트(kbps, 고정 비트레이트).
enum MP3Bitrate: Int, Sendable, CaseIterable {
    case kbps128 = 128
    case kbps192 = 192
    case kbps320 = 320
}

/// 받을 영상 포맷. 두 가지 모두 다시 인코딩하지 않고 유튜브의 영상·오디오 스트림을 합치기만 한다.
enum VideoFormat: String, Sendable, CaseIterable {
    /// 편집 프로그램에서 바로 열리는 H.264 + AAC MP4. 유튜브가 H.264를 1080p까지만 제공한다.
    case mp4
    /// 가장 높은 화질(4K 이상은 VP9·AV1). 파일 형식(MP4·WebM·MKV)은 받은 스트림에 따라 yt-dlp가 정한다.
    case best

    /// 고를 수 있는 해상도. MP4는 1080p가 상한이라 그 위는 두지 않는다.
    var resolutions: [VideoResolution] {
        switch self {
        case .mp4: [.p1080, .p720, .p480]
        case .best: VideoResolution.allCases
        }
    }

    /// 이 포맷이 가진 해상도로 맞춘다: 그대로 있으면 그대로, 없으면 그보다 낮은 것 중 가장 높은 것
    /// (예: MP4에서 2160p·최고 → 1080p), 그것도 없으면 기본값.
    func supportedResolution(near resolution: VideoResolution) -> VideoResolution {
        if resolutions.contains(resolution) { return resolution }
        let limit = resolution == .best ? Int.max : resolution.rawValue
        return resolutions.filter { $0 != .best && $0.rawValue <= limit }.max { $0.rawValue < $1.rawValue }
            ?? defaultResolution
    }

    /// 처음 쓸 때의 해상도.
    var defaultResolution: VideoResolution {
        switch self {
        case .mp4: .p1080
        case .best: .best
        }
    }
}

/// 영상 해상도(세로 픽셀). 고른 해상도가 없으면 그보다 낮은 것 중 가장 높은 해상도를 받는다
/// (그보다 낮은 것도 없으면 가장 낮은 해상도). `best`는 제한 없이 가장 높은 해상도.
enum VideoResolution: Int, Sendable, CaseIterable {
    case best = 0
    case p2160 = 2160
    case p1440 = 1440
    case p1080 = 1080
    case p720 = 720
    case p480 = 480
}

/// 결과 포맷: 오디오 추출 또는 영상 다운로드.
enum OutputFormat: Sendable, Equatable, Hashable {
    case mp3(MP3Bitrate)
    case wav
    case flac
    case video(VideoFormat, VideoResolution)

    var isVideo: Bool {
        if case .video = self { true } else { false }
    }

    /// 결과 파일 확장자. 오디오는 yt-dlp `--audio-format` 값과 같다.
    /// 최고 화질 영상은 받은 스트림에 따라 정해지므로 nil(결과 파일의 확장자를 쓴다).
    var fileExtension: String? {
        switch self {
        case .mp3: "mp3"
        case .wav: "wav"
        case .flac: "flac"
        case .video(.mp4, _): "mp4"
        case .video(.best, _): nil
        }
    }
}

/// 추출 옵션.
struct ExtractOptions: Sendable, Equatable {
    var format: OutputFormat
    /// 결과 파일을 저장할 폴더.
    var outputDirectory: URL
}
