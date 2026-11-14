import AVFoundation
import Foundation
import Testing
@testable import Stow

/// 로컬 WAV 파일을 `file://` URL로 넘겨 추출 전체 흐름(내려받기 → 변환 → 메타데이터 → 이동)을
/// 네트워크 없이 확인한다.
struct YtDlpClientOfflineTests {
    private let engine = try! EngineLocator.bundled()

    @Test(arguments: [AudioFormat.mp3(.kbps320), .mp3(.kbps128), .wav, .flac])
    func extractsLocalFile(_ format: AudioFormat) async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let client = YtDlpClient(engine: engine, additionalArguments: ["--enable-file-urls"])
        let progress = ProgressRecorder()

        let output = try await client.extract(
            fixture.sourceURL,
            options: ExtractOptions(format: format, outputDirectory: fixture.outputDirectory),
            fileName: "결과: 테스트",
            progress: { progress.append($0) }
        )

        #expect(output == fixture.outputDirectory.appending(path: "결과- 테스트.\(format.fileExtension)"))
        let info = try await AudioProbe.inspect(output, engine: engine)
        switch format {
        case .mp3(let bitrate):
            #expect(info.codec == "mp3")
            #expect(abs(info.bitRate - bitrate.rawValue * 1000) <= 16_000, "bit_rate: \(info.bitRate)")
        case .wav:
            #expect(info.codec == "pcm_s16le")
        case .flac:
            #expect(info.codec == "flac")
        }
        #expect(info.title == "tone source")  // --embed-metadata
        #expect(abs(info.duration - 3) < 0.2)
        try AudioProbe.decodeWithCoreAudio(output)

        let events = progress.events
        #expect(events.contains { if case .downloading(fraction: 1, _, _) = $0 { true } else { false } })
        #expect(events.contains(.converting))
        #expect(events.contains(.embeddingMetadata))
        // 작업 폴더는 남지 않고, 저장 위치에는 결과 파일만 있다.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outputDirectory.path) == [output.lastPathComponent])
    }

    @Test func doesNotOverwriteExistingFile() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let existing = fixture.outputDirectory.appending(path: "곡.mp3")
        try Data("old".utf8).write(to: existing)
        let client = YtDlpClient(engine: engine, additionalArguments: ["--enable-file-urls"])
        let options = ExtractOptions(format: .mp3(.kbps128), outputDirectory: fixture.outputDirectory)

        let second = try await client.extract(fixture.sourceURL, options: options, fileName: "곡")
        let third = try await client.extract(fixture.sourceURL, options: options, fileName: "곡")

        #expect(second.lastPathComponent == "곡 (2).mp3")
        #expect(third.lastPathComponent == "곡 (3).mp3")
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
    }

    @Test func fetchesMetadataOfLocalFile() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let client = YtDlpClient(engine: engine, additionalArguments: ["--enable-file-urls"])
        let metadata = try await client.fetchMetadata(for: fixture.sourceURL)
        #expect(metadata.title == "tone source")
    }

    @Test func mapsYtDlpFailureToEngineError() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        let client = YtDlpClient(engine: engine, additionalArguments: ["--enable-file-urls"])
        let missing = fixture.sourceURL.deletingLastPathComponent().appending(path: "없는 파일.wav")
        // 로컬 파일이 없으면 yt-dlp는 "Unable to download webpage: [Errno 2] ..."를 낸다.
        await #expect(throws: EngineError.network) {
            try await client.extract(
                missing, options: ExtractOptions(format: .wav, outputDirectory: fixture.outputDirectory), fileName: "x"
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outputDirectory.path).isEmpty)
    }

    /// 변환 중에 취소하면 프로세스가 끝난 뒤 작업 폴더를 지우고, 저장 위치에는 아무것도 남기지 않는다.
    @Test func cancellationCleansUpWorkDirectory() async throws {
        let fixture = try TestFixture(seconds: 600)  // 10분: 변환이 취소 전에 끝나지 않을 만큼 길게
        defer { fixture.cleanUp() }
        var client = YtDlpClient(engine: engine, additionalArguments: ["--enable-file-urls"])
        client.workDirectoryRoot = fixture.workRoot
        let (converting, convertingContinuation) = AsyncStream<Void>.makeStream()

        let task = Task {
            try await client.extract(
                fixture.sourceURL,
                options: ExtractOptions(format: .flac, outputDirectory: fixture.outputDirectory),
                fileName: "취소",
                progress: { if $0 == .converting { convertingContinuation.yield() } }
            )
        }
        for await _ in converting { break }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.workRoot.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outputDirectory.path).isEmpty)
    }

    @Test func missingOutputDirectoryIsReported() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanUp() }
        var client = YtDlpClient(engine: engine, additionalArguments: ["--enable-file-urls"])
        client.workDirectoryRoot = fixture.workRoot
        let gone = fixture.root.appending(path: "삭제된 폴더")
        await #expect(throws: EngineError.outputDirectoryMissing) {
            try await client.extract(
                fixture.sourceURL, options: ExtractOptions(format: .wav, outputDirectory: gone), fileName: "x"
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.workRoot.path).isEmpty)
    }
}

/// 실제 유튜브 영상으로 확인한다. 네트워크가 필요하므로 URL을 줄 때만 실행한다.
///   TEST_RUNNER_STOW_NETWORK_TEST_URL=<url> xcodebuild ... test
/// 결과 파일은 STOW_NETWORK_TEST_OUTPUT(기본: 임시 폴더)에 남겨 직접 들어 볼 수 있게 한다.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STOW_NETWORK_TEST_URL"] != nil))
struct YtDlpClientNetworkTests {
    private let engine = try! EngineLocator.bundled()

    @Test func extractsRealVideoInAllFormats() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try YouTubeURL.parse(try #require(environment["STOW_NETWORK_TEST_URL"]))
        let outputDirectory = URL(filePath: environment["STOW_NETWORK_TEST_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appending(path: "stow-network-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let client = YtDlpClient(engine: engine)

        let metadata = try await client.fetchMetadata(for: url)
        let duration = try #require(metadata.duration)
        print("[network test] \(metadata.title) (\(duration)s) → \(outputDirectory.path)")

        for format in [AudioFormat.mp3(.kbps320), .wav, .flac] {
            let progress = ProgressRecorder()
            let output = try await client.extract(
                url, options: ExtractOptions(format: format, outputDirectory: outputDirectory),
                fileName: metadata.title, progress: { progress.append($0) }
            )
            let info = try await AudioProbe.inspect(output, engine: engine)
            print("[network test] \(output.lastPathComponent): \(info)")
            #expect(abs(info.duration - duration) < 2, "duration: \(info.duration)")
            #expect(info.title == metadata.title)
            switch format {
            case .mp3: #expect(info.codec == "mp3" && abs(info.bitRate - 320_000) <= 16_000)
            case .wav: #expect(info.codec.hasPrefix("pcm_"))
            case .flac: #expect(info.codec == "flac")
            }
            try AudioProbe.decodeWithCoreAudio(output)
            #expect(progress.events.contains { if case .downloading = $0 { true } else { false } })
        }
    }
}

// MARK: - 도우미

/// 스테레오 WAV(`tone source.wav`, 기본 3초)와 빈 저장 폴더(`out`), 작업 폴더 위치(`work`)를 만든다.
private struct TestFixture {
    let root: URL
    let sourceURL: URL
    let outputDirectory: URL
    let workRoot: URL

    init(seconds: Int = 3) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "stow-test-\(UUID().uuidString)")
        outputDirectory = root.appending(path: "out")
        workRoot = root.appending(path: "work")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        sourceURL = root.appending(path: "tone source.wav")
        try Self.makeWAV(seconds: seconds).write(to: sourceURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeWAV(seconds: Int, sampleRate: Int = 44100) -> Data {
        // 440Hz는 44100 프레임에 정수 주기로 맞으므로 1초 분량을 반복해도 이어진다.
        var second = Data(capacity: sampleRate * 4)
        for i in 0..<sampleRate {
            let value = Int16(8000 * sin(Double(i) * 2 * .pi * 440 / Double(sampleRate)))
            withUnsafeBytes(of: value.littleEndian) { bytes in second.append(contentsOf: Array(bytes) + Array(bytes)) }
        }
        var samples = Data(capacity: second.count * seconds)
        for _ in 0..<seconds { samples.append(second) }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 4)); append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count))
        data.append(samples)
        return data
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExtractProgress] = []

    func append(_ event: ExtractProgress) {
        lock.withLock { storage.append(event) }
    }

    var events: [ExtractProgress] { lock.withLock { storage } }
}

private enum AudioProbe {
    struct Info: CustomStringConvertible {
        var codec: String
        var bitRate: Int
        var duration: Double
        var title: String?
        var description: String { "\(codec), \(bitRate) bps, \(duration)s, title=\(title ?? "-")" }
    }

    /// ffprobe로 첫 오디오 스트림 코덱, 비트레이트, 길이, 제목 태그를 읽는다.
    static func inspect(_ file: URL, engine: EngineLocator) async throws -> Info {
        let result = try await ProcessRunner().run(engine.ffprobe, arguments: [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name:format=bit_rate,duration:format_tags=title",
            "-of", "default=noprint_wrappers=1", file.path,
        ])
        #expect(result.termination.isSuccess, "ffprobe: \(result.stderr)")
        var values: [String: String] = [:]
        for line in result.stdout {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0].lowercased()] = parts[1] }
        }
        return Info(
            codec: values["codec_name"] ?? "",
            bitRate: Int(values["bit_rate"] ?? "") ?? 0,
            duration: Double(values["duration"] ?? "") ?? 0,
            title: values["tag:title"]
        )
    }

    /// macOS 오디오 프레임워크로 끝까지 디코딩해 재생 가능한 파일인지 확인한다.
    static func decodeWithCoreAudio(_ file: URL) throws {
        let audioFile = try AVAudioFile(forReading: file)
        #expect(audioFile.length > 0)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 65_536))
        var total: AVAudioFramePosition = 0
        while audioFile.framePosition < audioFile.length {
            try audioFile.read(into: buffer)
            if buffer.frameLength == 0 { break }
            total += AVAudioFramePosition(buffer.frameLength)
        }
        #expect(total > 0)
        #expect(abs(total - audioFile.length) <= 4096, "decoded \(total) of \(audioFile.length)")
    }
}
