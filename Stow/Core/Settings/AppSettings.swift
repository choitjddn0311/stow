import Foundation
import Observation

/// 포맷 종류(화면의 포맷 선택에 쓴다). MP3 음질은 따로 기억한다.
enum AudioFormatKind: String, CaseIterable, Sendable {
    case mp3, wav, flac

    var displayName: String {
        switch self {
        case .mp3: "MP3"
        case .wav: "WAV"
        case .flac: "FLAC"
        }
    }
}

/// 사용자 설정. `UserDefaults`에 저장해 앱을 다시 실행해도 유지한다.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let outputDirectory = "outputDirectory"
        static let formatKind = "formatKind"
        static let mp3Bitrate = "mp3Bitrate"
        static let acceptedNoticeVersion = "acceptedNoticeVersion"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// 결과 파일을 저장할 폴더. 기본값은 "다운로드" 폴더.
    var outputDirectory: URL {
        didSet { defaults.set(outputDirectory.path, forKey: Keys.outputDirectory) }
    }

    var formatKind: AudioFormatKind {
        didSet { defaults.set(formatKind.rawValue, forKey: Keys.formatKind) }
    }

    /// MP3를 고를 때 쓸 음질. WAV·FLAC을 골랐다가 MP3로 돌아와도 유지한다.
    var mp3Bitrate: MP3Bitrate {
        didSet { defaults.set(mp3Bitrate.rawValue, forKey: Keys.mp3Bitrate) }
    }

    /// 동의한 이용 고지 버전. 0이면 아직 동의하지 않았다.
    var acceptedNoticeVersion: Int {
        didSet { defaults.set(acceptedNoticeVersion, forKey: Keys.acceptedNoticeVersion) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputDirectory = defaults.string(forKey: Keys.outputDirectory).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? Self.defaultOutputDirectory
        formatKind = defaults.string(forKey: Keys.formatKind).flatMap(AudioFormatKind.init(rawValue:)) ?? .mp3
        mp3Bitrate = MP3Bitrate(rawValue: defaults.integer(forKey: Keys.mp3Bitrate)) ?? .kbps320
        acceptedNoticeVersion = defaults.integer(forKey: Keys.acceptedNoticeVersion)
    }

    /// 선택한 포맷.
    var format: AudioFormat {
        switch formatKind {
        case .mp3: .mp3(mp3Bitrate)
        case .wav: .wav
        case .flac: .flac
        }
    }

    var extractOptions: ExtractOptions {
        ExtractOptions(format: format, outputDirectory: outputDirectory)
    }

    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
