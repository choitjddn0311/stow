import Foundation

/// MP3 비트레이트(kbps, 고정 비트레이트).
enum MP3Bitrate: Int, Sendable, CaseIterable {
    case kbps128 = 128
    case kbps192 = 192
    case kbps320 = 320
}

/// 추출할 오디오 포맷. WAV·FLAC은 원본 샘플레이트를 유지한다(옵션은 미정, PROJECT.md 8장).
enum AudioFormat: Sendable, Equatable, Hashable {
    case mp3(MP3Bitrate)
    case wav
    case flac

    /// 결과 파일 확장자. yt-dlp `--audio-format` 값과 같다.
    var fileExtension: String {
        switch self {
        case .mp3: "mp3"
        case .wav: "wav"
        case .flac: "flac"
        }
    }
}

/// 추출 옵션.
struct ExtractOptions: Sendable, Equatable {
    var format: AudioFormat
    /// 결과 파일을 저장할 폴더.
    var outputDirectory: URL
}
