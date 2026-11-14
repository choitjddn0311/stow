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
        didSet {
            defaults.set(outputDirectory.path, forKey: Keys.outputDirectory)
            outputFolderName = Self.folderName(for: outputDirectory)
        }
    }

    /// Finder에 보이는 저장 폴더 이름(예: "다운로드"). 화면을 그릴 때마다 파일 시스템을 조회하지 않도록
    /// 저장 위치가 바뀔 때만 계산해 둔다.
    private(set) var outputFolderName: String

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
        let directory = defaults.string(forKey: Keys.outputDirectory).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? Self.defaultOutputDirectory
        outputDirectory = directory
        outputFolderName = Self.folderName(for: directory)
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

    private static func folderName(for url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
