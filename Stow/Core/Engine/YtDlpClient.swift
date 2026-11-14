import Foundation

/// yt-dlp로 영상 정보를 조회하고 오디오를 추출한다.
struct YtDlpClient: Sendable {
    let engine: EngineLocator
    var runner = ProcessRunner()
    /// 테스트용 추가 yt-dlp 인자.
    var additionalArguments: [String] = []

    private var arguments: YtDlpArguments {
        YtDlpArguments(engine: engine, additional: additionalArguments)
    }

    /// 영상 정보를 조회한다(`yt-dlp -J`).
    func fetchMetadata(for url: URL) async throws -> VideoMetadata {
        let command = engine.ytDlpCommand(arguments.metadata(for: url))
        let result = try await runner.run(command.executable, arguments: command.arguments)
        guard result.termination.isSuccess else {
            throw YtDlpErrorMapper.map(stderr: result.stderr)
        }
        let json = Data(result.stdout.joined(separator: "\n").utf8)
        if let type = try? JSONDecoder().decode(EntryType.self, from: json).type, type != "video" {
            throw EngineError.playlistNotSupported
        }
        let metadata: VideoMetadata
        do {
            metadata = try JSONDecoder().decode(VideoMetadata.self, from: json)
        } catch {
            throw EngineError.metadataUnreadable
        }
        if metadata.liveStatus == "is_live" || metadata.liveStatus == "is_upcoming" {
            throw EngineError.liveNotSupported
        }
        return metadata
    }

    /// 오디오를 추출해 `options.outputDirectory`에 `<fileName>.<확장자>`로 저장하고 최종 경로를 돌려준다.
    ///
    /// - 작업마다 별도의 임시 폴더에서 내려받고 변환한 뒤 결과만 옮긴다. 같은 폴더의 다른 파일과
    ///   중간 파일 이름이 겹치지 않고, 취소·실패 시 남은 파일을 한 번에 지울 수 있다.
    /// - 같은 이름의 파일이 있으면 덮어쓰지 않고 `이름 (2).mp3`처럼 번호를 붙인다.
    /// - 작업이 취소되면 프로세스를 종료하고 `CancellationError`를 던진다.
    func extract(
        _ url: URL,
        options: ExtractOptions,
        fileName: String,
        progress: @escaping @Sendable (ExtractProgress) -> Void = { _ in }
    ) async throws -> URL {
        let workDirectory = try Self.makeWorkDirectory(near: options.outputDirectory)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let command = engine.ytDlpCommand(
            arguments.extract(url, format: options.format, workDirectory: workDirectory)
        )
        var stderr: [String] = []
        var outputPath: String?
        var termination: ProcessTermination?
        for try await event in runner.events(command.executable, arguments: command.arguments) {
            let line: String
            switch event {
            case .stdout(let text):
                line = text
            case .stderr(let text):
                line = text
                stderr.append(text)
            case .terminated(let value):
                termination = value
                continue
            }
            switch ProgressParser.parse(line) {
            case .progress(let value): progress(value)
            case .outputFile(let path): outputPath = path
            case nil: break
            }
        }
        // 종료 이벤트 없이 끝나는 경우는 취소뿐이다.
        guard let termination else { throw CancellationError() }
        guard termination.isSuccess else { throw YtDlpErrorMapper.map(stderr: stderr) }

        guard let outputPath else { throw EngineError.outputMissing }
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

    private struct EntryType: Decodable {
        let type: String?
        enum CodingKeys: String, CodingKey { case type = "_type" }
    }

    /// 저장 위치와 같은 볼륨의 임시 폴더를 만든다(옮길 때 복사 없이 이름만 바뀌도록).
    /// 그 볼륨에 만들 수 없으면 시스템 임시 폴더를 쓴다.
    private static func makeWorkDirectory(near directory: URL) throws -> URL {
        let fileManager = FileManager.default
        if let url = try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true
        ) {
            return url
        }
        let url = fileManager.temporaryDirectory.appending(path: "stow-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func moveToDestination(
        _ source: URL, directory: URL, baseName: String, fileExtension: String
    ) throws -> URL {
        let fileManager = FileManager.default
        for index in 1...1000 {
            let name = index == 1 ? baseName : "\(baseName) (\(index))"
            let destination = directory.appending(path: name).appendingPathExtension(fileExtension)
            do {
                try fileManager.moveItem(at: source, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch let error as CocoaError {
                throw Self.engineError(for: error)
            }
        }
        throw EngineError.permissionDenied
    }

    private static func engineError(for error: CocoaError) -> EngineError {
        switch error.code {
        case .fileWriteOutOfSpace: .diskFull
        case .fileWriteNoPermission, .fileWriteVolumeReadOnly: .permissionDenied
        default:
            if let posix = error.underlying as? POSIXError, posix.code == .ENOSPC { .diskFull } else { .permissionDenied }
        }
    }
}

/// 영상 제목으로 파일 이름을 만든다.
enum FileNaming {
    /// UTF-8 기준 최대 길이. macOS 파일 이름 한도(255바이트)에서 ` (999).flac` 여유를 뺐다.
    static let maxBytes = 200

    /// 경로 구분자와 제어 문자를 바꾸고, 앞뒤 공백·점을 정리하고, 길이를 줄인다.
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
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        // 문자(그래핌) 단위로 잘라 한글·이모지가 중간에서 끊기지 않게 한다.
        while name.utf8.count > maxBytes { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "오디오" : name
    }
}
