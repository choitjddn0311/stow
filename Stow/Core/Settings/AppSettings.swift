import Foundation
import Observation

/// 받을 종류: 오디오 추출 또는 영상 다운로드.
enum MediaKind: String, CaseIterable, Sendable {
    case audio, video

    var displayName: String {
        switch self {
        case .audio: "오디오"
        case .video: "영상"
        }
    }
}

/// 오디오 포맷 종류(화면의 포맷 선택에 쓴다). MP3 음질은 따로 기억한다.
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
        static let mediaKind = "mediaKind"
        static let videoFormat = "videoFormat"
        static let mp4Resolution = "mp4Resolution"
        static let bestResolution = "bestResolution"
        static let acceptedNoticeVersion = "acceptedNoticeVersion"
        static let recentOutputDirectories = "recentOutputDirectories"
    }

    /// 최근 저장 폴더를 몇 개까지 기억하는지(빠른 추출 패널의 폴더 메뉴)
    static let maxRecentOutputDirectories = 5

    @ObservationIgnored private let defaults: UserDefaults

    /// 결과 파일을 저장할 폴더. 기본값은 "다운로드" 폴더.
    var outputDirectory: URL {
        didSet {
            // 같은 폴더를 다시 고르면 저장·목록 갱신을 하지 않는다(화면을 다시 그리지 않게).
            guard !Self.isSameDirectory(oldValue, outputDirectory) else { return }
            defaults.set(outputDirectory.path, forKey: Keys.outputDirectory)
            outputFolderName = Self.folderName(for: outputDirectory)
            recentOutputDirectories = Self.recents(adding: outputDirectory, to: recentOutputDirectories)
            defaults.set(recentOutputDirectories.map(\.path), forKey: Keys.recentOutputDirectories)
        }
    }

    /// 최근에 고른 저장 폴더(지금 폴더가 맨 앞, 최대 `maxRecentOutputDirectories`개)
    private(set) var recentOutputDirectories: [URL]

    /// 메뉴에 보일 최근 폴더: 지금 폴더와, 아직 있는 폴더만(지워졌거나 연결이 끊긴 볼륨은 뺀다).
    var availableRecentOutputDirectories: [URL] {
        recentOutputDirectories.filter { url in
            Self.isSameDirectory(url, outputDirectory) || Self.directoryExists(url)
        }
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Finder에 보이는 저장 폴더 이름(예: "다운로드"). 화면을 그릴 때마다 파일 시스템을 조회하지 않도록
    /// 저장 위치가 바뀔 때만 계산해 둔다.
    private(set) var outputFolderName: String

    /// 오디오와 영상 중 무엇을 받을지. 오디오 포맷과 영상 포맷은 각각 따로 기억한다.
    var mediaKind: MediaKind {
        didSet { defaults.set(mediaKind.rawValue, forKey: Keys.mediaKind) }
    }

    /// 오디오 포맷(MP3·WAV·FLAC). 영상을 고른 동안에도 유지한다.
    var formatKind: AudioFormatKind {
        didSet { defaults.set(formatKind.rawValue, forKey: Keys.formatKind) }
    }

    /// MP3를 고를 때 쓸 음질. WAV·FLAC을 골랐다가 MP3로 돌아와도 유지한다.
    var mp3Bitrate: MP3Bitrate {
        didSet { defaults.set(mp3Bitrate.rawValue, forKey: Keys.mp3Bitrate) }
    }

    var videoFormat: VideoFormat {
        didSet { defaults.set(videoFormat.rawValue, forKey: Keys.videoFormat) }
    }

    /// 영상 포맷마다 따로 기억하는 해상도(MP4는 1080p가 상한이라 둘을 나눈다).
    private(set) var mp4Resolution: VideoResolution {
        didSet { defaults.set(mp4Resolution.rawValue, forKey: Keys.mp4Resolution) }
    }

    private(set) var bestResolution: VideoResolution {
        didSet { defaults.set(bestResolution.rawValue, forKey: Keys.bestResolution) }
    }

    /// 지금 고른 영상 포맷의 해상도.
    var videoResolution: VideoResolution {
        get {
            switch videoFormat {
            case .mp4: mp4Resolution
            case .best: bestResolution
            }
        }
        set {
            // 그 포맷에 없는 해상도(예: MP4 2160p)는 그 포맷이 가진 가장 가까운 아래 해상도로 맞춘다.
            let value = videoFormat.supportedResolution(near: newValue)
            switch videoFormat {
            case .mp4: mp4Resolution = value
            case .best: bestResolution = value
            }
        }
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
        let storedRecents = (defaults.stringArray(forKey: Keys.recentOutputDirectories) ?? [])
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
        recentOutputDirectories = Self.recents(adding: directory, to: storedRecents)
        formatKind = defaults.string(forKey: Keys.formatKind).flatMap(AudioFormatKind.init(rawValue:)) ?? .mp3
        mp3Bitrate = MP3Bitrate(rawValue: defaults.integer(forKey: Keys.mp3Bitrate)) ?? .kbps320
        // 영상 기능 전의 설정에는 값이 없으므로 오디오로 시작한다.
        mediaKind = defaults.string(forKey: Keys.mediaKind).flatMap(MediaKind.init(rawValue:)) ?? .audio
        videoFormat = defaults.string(forKey: Keys.videoFormat).flatMap(VideoFormat.init(rawValue:)) ?? .mp4
        mp4Resolution = Self.storedResolution(defaults, key: Keys.mp4Resolution, for: .mp4)
        bestResolution = Self.storedResolution(defaults, key: Keys.bestResolution, for: .best)
        acceptedNoticeVersion = defaults.integer(forKey: Keys.acceptedNoticeVersion)
    }

    private static func storedResolution(_ defaults: UserDefaults, key: String, for format: VideoFormat) -> VideoResolution {
        // 값이 없으면 integer(forKey:)가 0(= best)을 돌려주므로 키가 있을 때만 읽는다.
        guard defaults.object(forKey: key) != nil,
              let value = VideoResolution(rawValue: defaults.integer(forKey: key)),
              format.resolutions.contains(value)
        else { return format.defaultResolution }
        return value
    }

    /// 선택한 포맷.
    var format: OutputFormat {
        switch mediaKind {
        case .audio: audioFormat
        case .video: .video(videoFormat, videoResolution)
        }
    }

    /// 종류와 관계없이 지금 고른 오디오 포맷.
    var audioFormat: OutputFormat {
        switch formatKind {
        case .mp3: .mp3(mp3Bitrate)
        case .wav: .wav
        case .flac: .flac
        }
    }

    /// 포맷을 한 번에 고른다(종류·MP3 음질·영상 해상도도 함께 바뀐다).
    func select(_ format: OutputFormat) {
        switch format {
        case .mp3(let bitrate):
            mp3Bitrate = bitrate
            formatKind = .mp3
        case .wav:
            formatKind = .wav
        case .flac:
            formatKind = .flac
        case .video(let video, let resolution):
            videoFormat = video
            videoResolution = resolution
        }
        mediaKind = format.isVideo ? .video : .audio
    }

    /// 두 폴더가 같은 위치인지(끝의 `/`, 심볼릭 링크 등 표기 차이는 무시. 예: /tmp와 /private/tmp)
    static func isSameDirectory(_ a: URL, _ b: URL) -> Bool {
        canonicalPath(a) == canonicalPath(b)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).trimmingSuffix("/")
    }

    /// `directory`를 맨 앞에 두고 같은 폴더는 한 번만, 최대 개수까지 남긴다.
    private static func recents(adding directory: URL, to list: [URL]) -> [URL] {
        var result = [directory]
        for url in list where !result.contains(where: { isSameDirectory($0, url) }) {
            result.append(url)
        }
        return Array(result.prefix(maxRecentOutputDirectories))
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

private extension String {
    /// 끝의 `suffix`를 뗀다(루트 "/"는 그대로).
    func trimmingSuffix(_ suffix: String) -> String {
        guard count > suffix.count, hasSuffix(suffix) else { return self }
        return String(dropLast(suffix.count))
    }
}
