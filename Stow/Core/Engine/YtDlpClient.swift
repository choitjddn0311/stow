import Darwin
import Foundation

/// yt-dlp로 영상 정보를 조회하고 오디오를 추출한다.
struct YtDlpClient: Sendable {
    let engine: EngineLocator
    var runner = ProcessRunner()
    /// 테스트용 추가 yt-dlp 인자.
    var additionalArguments: [String] = []
    /// 작업 폴더를 만들 위치. nil이면 저장 위치와 같은 볼륨의 시스템 임시 폴더를 쓴다(테스트에서 지정).
    var workDirectoryRoot: URL?
    /// 지금 쓸 엔진(앱 안 엔진 업데이트로 yt-dlp가 바뀜). nil이면 `engine`을 쓴다.
    var engineSource: EngineSource?

    /// 작업마다 시작할 때 한 번 읽는다. 진행 중인 작업은 업데이트가 끝나도 이 엔진으로 끝까지 돈다.
    private var activeEngine: EngineLocator {
        engineSource?.current ?? engine
    }

    private func arguments(for engine: EngineLocator) -> YtDlpArguments {
        YtDlpArguments(engine: engine, additional: additionalArguments)
    }

    /// 주소를 조회한다(`yt-dlp -J --flat-playlist`). 영상이면 정보를, 재생목록이면 영상 목록을 돌려준다.
    /// 진행 중·예정 라이브 방송, 빈 재생목록이면 오류를 던진다.
    func fetchMedia(for url: URL) async throws -> FetchedMedia {
        let engine = activeEngine
        let command = engine.ytDlpCommand(arguments(for: engine).metadata(for: url))
        let result = try await runner.run(command.executable, arguments: command.arguments)
        guard result.termination.isSuccess else {
            throw YtDlpErrorMapper.map(stderr: result.stderr)
        }
        let media: FetchedMedia
        do {
            media = try JSONDecoder().decode(FetchedMedia.self, from: Data(result.stdout.joined(separator: "\n").utf8))
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.metadataUnreadable
        }
        switch media {
        case .video(let metadata) where metadata.liveStatus == "is_live" || metadata.liveStatus == "is_upcoming":
            throw EngineError.liveNotSupported
        case .playlist(let playlist) where playlist.entries.isEmpty:
            throw EngineError.emptyPlaylist
        default:
            return media
        }
    }

    /// 오디오를 추출해 `options.outputDirectory`에 `<fileName>.<확장자>`로 저장하고 최종 경로를 돌려준다.
    ///
    /// - 작업마다 별도의 임시 폴더에서 내려받고 변환한 뒤 결과만 옮긴다. 같은 폴더의 다른 파일과
    ///   중간 파일 이름이 겹치지 않고, 취소·실패 시 남은 파일을 한 번에 지울 수 있다.
    /// - 같은 이름의 파일이 있으면 덮어쓰지 않고 `이름 (2).mp3`처럼 번호를 붙인다.
    /// - 작업이 취소되면 프로세스가 끝날 때까지 기다려 임시 폴더를 지운 뒤 `CancellationError`를 던진다.
    func extract(
        _ url: URL,
        options: ExtractOptions,
        fileName: String,
        progress: @escaping @Sendable (ExtractProgress) -> Void = { _ in }
    ) async throws -> URL {
        let workDirectory = try makeWorkDirectory(near: options.outputDirectory)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let engine = activeEngine
        let command = engine.ytDlpCommand(
            arguments(for: engine).extract(url, format: options.format, workDirectory: workDirectory)
        )
        let state = ExtractState()
        let termination = try await runner.run(command.executable, arguments: command.arguments) { event in
            let line: String
            switch event {
            case .stdout(let text): line = text
            case .stderr(let text):
                line = text
                state.appendError(text)
            case .terminated: return
            }
            switch ProgressParser.parse(line) {
            case .progress(let value): progress(value)
            case .outputFile(let path): state.setOutput(path)
            case nil: break
            }
        }
        guard termination.isSuccess else { throw YtDlpErrorMapper.map(stderr: state.errors) }

        guard let outputPath = state.output else { throw EngineError.outputMissing }
        let produced = URL(filePath: outputPath)
        guard FileManager.default.fileExists(atPath: produced.path) else { throw EngineError.outputMissing }
        return try Self.moveToDestination(
            produced,
            directory: options.outputDirectory,
            baseName: FileNaming.sanitize(fileName),
            fileExtension: options.format.fileExtension
        )
    }

    // MARK: - 내부 구현

    /// 저장 위치와 같은 볼륨의 임시 폴더를 만든다(옮길 때 복사 없이 이름만 바뀌도록).
    /// 그 볼륨에 만들 수 없으면 시스템 임시 폴더를 쓴다.
    private func makeWorkDirectory(near directory: URL) throws -> URL {
        let fileManager = FileManager.default
        if workDirectoryRoot == nil, let url = try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true
        ) {
            return url
        }
        let root = workDirectoryRoot ?? fileManager.temporaryDirectory
        let url = root.appending(path: "stow-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 결과 파일을 저장 위치로 옮긴다. 같은 이름이 있으면 번호를 붙인다.
    /// `renamex_np(RENAME_EXCL)`로 "없을 때만 옮기기"를 한 번에 처리해, 동시에 끝난 다른 작업과도 덮어쓰지 않는다.
    private static func moveToDestination(
        _ source: URL, directory: URL, baseName: String, fileExtension: String
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.outputDirectoryMissing
        }
        for index in 1...1000 {
            let name = index == 1 ? baseName : "\(baseName) (\(index))"
            let destination = directory.appending(path: name).appendingPathExtension(fileExtension)
            if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                return destination
            }
            let code = errno
            switch code {
            case EEXIST:
                continue
            case EXDEV:
                // 다른 볼륨(임시 폴더 대체 경로): 복사한다. copyItem은 대상이 있으면 실패한다.
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    return destination
                } catch CocoaError.fileWriteFileExists {
                    continue
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw engineError(for: error)
                }
            default:
                throw engineError(posix: code)
            }
        }
        throw EngineError.unknown("같은 이름의 파일이 너무 많습니다: \(baseName).\(fileExtension)")
    }

    private static func engineError(posix code: Int32) -> EngineError {
        switch code {
        case ENOSPC, EDQUOT: .diskFull
        case EACCES, EPERM, EROFS: .permissionDenied
        case ENOENT, ENOTDIR: .outputDirectoryMissing
        default: .unknown(String(cString: strerror(code)))
        }
    }

    private static func engineError(for error: any Error) -> EngineError {
        if let engineError = error as? EngineError { return engineError }
        let nsError = error as NSError
        if let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError), posix.domain == NSPOSIXErrorDomain {
            return engineError(posix: Int32(posix.code))
        }
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileWriteOutOfSpace: return .diskFull
        case .fileWriteNoPermission, .fileWriteVolumeReadOnly: return .permissionDenied
        case .fileNoSuchFile: return .outputDirectoryMissing
        default: return .unknown(nsError.localizedDescription)
        }
    }
}

/// 추출 중 여러 스레드에서 오는 출력 상태.
private final class ExtractState: @unchecked Sendable {
    private let lock = NSLock()
    private var stderrLines: [String] = []
    private var outputPath: String?

    func appendError(_ line: String) { lock.withLock { stderrLines.append(line) } }
    func setOutput(_ path: String) { lock.withLock { outputPath = path } }
    var errors: [String] { lock.withLock { stderrLines } }
    var output: String? { lock.withLock { outputPath } }
}

/// 영상 제목으로 파일 이름을 만든다.
enum FileNaming {
    /// UTF-8 기준 최대 길이. macOS 파일 이름 한도(255바이트)에서 ` (999).flac` 여유를 뺐다.
    static let maxBytes = 200

    /// 경로 구분자와 제어 문자를 바꾸고, 앞쪽 점·공백(숨김 파일)과 뒤쪽 공백을 정리하고, 길이를 줄인다.
    /// 결과가 비면 "오디오"를 쓴다.
    static func sanitize(_ title: String) -> String {
        var name = String(title.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "/", ":": "-"
            case _ where scalar.properties.generalCategory == .control: " "
            default: Character(scalar)
            }
        })
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // 문자(그래핌) 단위로 잘라 한글·이모지가 중간에서 끊기지 않게 한다.
        while name.utf8.count > maxBytes { name.removeLast() }
        // 자른 뒤에 정리해야 끝 공백이 남지 않는다. ". .x"처럼 점과 공백이 섞여도 모두 지운다.
        while let first = name.first, first == "." || first == " " { name.removeFirst() }
        while name.last == " " { name.removeLast() }
        return name.isEmpty ? "오디오" : name
    }
}
