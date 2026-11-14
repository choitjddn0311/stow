import Foundation
import Testing
@testable import Stow

/// 앱 번들에 포함된 엔진이 앱 안에서 실행되는지 확인한다(네트워크 사용 없음).
struct EngineBundleTests {
    private let runner = ProcessRunner()

    @Test func locatesAllComponentsInAppBundle() throws {
        let engine = try EngineLocator.bundled()
        #expect(engine.ffmpegDirectory == engine.ffprobe.deletingLastPathComponent())
    }

    @Test func missingComponentIsReported() {
        let empty = FileManager.default.temporaryDirectory.appending(path: "stow-empty-\(UUID())")
        #expect(throws: EngineError.missingComponent("python3")) {
            try EngineLocator(binDirectory: empty)
        }
    }

    @Test func ytDlpRunsWithBundledPython() async throws {
        let engine = try EngineLocator.bundled()
        let command = engine.ytDlpCommand(["--version"])
        let result = try await runner.run(command.executable, arguments: command.arguments)
        #expect(result.termination.isSuccess, "stderr: \(result.stderr)")
        let version = try #require(result.stdout.first)
        #expect(version.wholeMatch(of: /\d{4}\.\d{2}\.\d{2}(\.\d+)?/) != nil, "version: \(version)")
    }

    @Test func ffmpegRuns() async throws {
        let engine = try EngineLocator.bundled()
        let result = try await runner.run(engine.ffmpeg, arguments: ["-version"])
        #expect(result.termination.isSuccess)
        #expect(result.stdout.first?.hasPrefix("ffmpeg version") == true)
    }

    @Test func ffprobeRuns() async throws {
        let engine = try EngineLocator.bundled()
        let result = try await runner.run(engine.ffprobe, arguments: ["-version"])
        #expect(result.termination.isSuccess)
        #expect(result.stdout.first?.hasPrefix("ffprobe version") == true)
    }

    /// ffmpeg가 LGPL 구성이고 필요한 인코더를 갖췄는지 확인한다.
    @Test func ffmpegIsLGPLWithRequiredEncoders() async throws {
        let engine = try EngineLocator.bundled()
        let buildconf = try await runner.run(engine.ffmpeg, arguments: ["-hide_banner", "-buildconf"])
        let configuration = (buildconf.stdout + buildconf.stderr).joined(separator: "\n")
        #expect(configuration.contains("--disable-everything"))
        for flag in ["--enable-gpl", "--enable-nonfree", "--enable-version3"] {
            #expect(!configuration.contains(flag), "\(flag) 포함됨")
        }

        let license = try await runner.run(engine.ffmpeg, arguments: ["-hide_banner", "-L"])
        // 문구가 여러 줄에 걸쳐 있으므로 공백으로 이어 붙여 확인한다.
        #expect((license.stdout + license.stderr).joined(separator: " ").contains("GNU Lesser General Public License"))

        let encoders = try await runner.run(engine.ffmpeg, arguments: ["-hide_banner", "-encoders"])
        let encoderNames = Set(encoders.stdout.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) })
        for encoder in ["libmp3lame", "flac", "pcm_s16le", "pcm_s24le"] {
            #expect(encoderNames.contains(encoder), "\(encoder) 없음")
        }
    }

    /// deno가 Hardened Runtime(JIT 엔타이틀먼트)에서 JavaScript를 실행하는지 확인한다.
    @Test func denoExecutesJavaScript() async throws {
        let engine = try EngineLocator.bundled()
        let result = try await runner.run(engine.deno, arguments: ["eval", "console.log(6 * 7)"])
        #expect(result.termination.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout == ["42"])
    }

    /// Python 확장 모듈(.so)이 서명 환경에서 로드되는지 확인한다(yt-dlp가 쓰는 ssl, ctypes 등).
    @Test func pythonLoadsExtensionModules() async throws {
        let engine = try EngineLocator.bundled()
        let result = try await runner.run(
            engine.python,
            arguments: ["-I", "-B", "-c", "import ssl, ctypes, sqlite3, lzma, bz2, hashlib, json; print('ok')"]
        )
        #expect(result.termination.isSuccess, "stderr: \(result.stderr)")
        #expect(result.stdout == ["ok"])
    }
}
