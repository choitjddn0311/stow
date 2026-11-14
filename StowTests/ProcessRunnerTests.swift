import Darwin
import Foundation
import Testing
@testable import Stow

struct ProcessRunnerTests {
    private let shell = URL(filePath: "/bin/sh")

    @Test func collectsStdoutStderrAndExitCode() async throws {
        let result = try await ProcessRunner().run(
            shell,
            arguments: ["-c", "echo one; echo err 1>&2; printf 'two\\r\\nlast'; exit 3"]
        )
        #expect(result.stdout == ["one", "two", "last"])
        #expect(result.stderr == ["err"])
        #expect(result.termination == .exited(3))
        #expect(!result.termination.isSuccess)
    }

    /// 인자는 셸 해석 없이 그대로 전달된다.
    @Test func passesArgumentsVerbatim() async throws {
        let tricky = "$(echo injected); `id` 'quoted' \"double\" *"
        let result = try await ProcessRunner().run(URL(filePath: "/bin/echo"), arguments: [tricky])
        #expect(result.stdout == [tricky])
        #expect(result.termination.isSuccess)
    }

    @Test func passesEnvironment() async throws {
        let result = try await ProcessRunner().run(
            shell, arguments: ["-c", "echo \"$STOW_TEST\""], environment: ["STOW_TEST": "값"]
        )
        #expect(result.stdout == ["값"])
    }

    @Test func reportsSignalTermination() async throws {
        let result = try await ProcessRunner().run(shell, arguments: ["-c", "kill -TERM $$"])
        #expect(result.termination == .signaled(SIGTERM))
    }

    @Test func throwsWhenExecutableIsMissing() async {
        let missing = URL(filePath: "/nonexistent/stow-test-binary")
        await #expect(throws: EngineError.launchFailed(executable: missing.path, code: ENOENT)) {
            try await ProcessRunner().run(missing)
        }
    }

    @Test func splitsLinesAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.append(Array("ab".utf8)) == [])
        #expect(splitter.append(Array("c\nd\r\n\ne".utf8)) == ["abc", "d", ""])
        #expect(splitter.finish() == "e")
        #expect(splitter.finish() == nil)
    }

    /// 취소하면 자식과 그 자식(손자)까지 모두 종료된다.
    @Test func cancellationTerminatesProcessGroup() async throws {
        let pids = try await runAndCancel(script: "sleep 600 & echo $!; echo $$; wait", grace: .seconds(3))
        #expect(await allExited(pids))
    }

    /// SIGTERM을 무시하는 프로세스도 유예 시간 뒤 SIGKILL로 종료된다.
    @Test func cancellationEscalatesToKill() async throws {
        let pids = try await runAndCancel(
            script: "trap '' TERM; sleep 600 & echo $!; echo $$; wait", grace: .milliseconds(300)
        )
        #expect(await allExited(pids))
    }

    // MARK: - 도우미

    /// 스크립트가 출력한 pid 두 개를 받은 뒤 작업을 취소하고 pid를 돌려준다.
    private func runAndCancel(script: String, grace: Duration) async throws -> [pid_t] {
        let runner = ProcessRunner(terminationGracePeriod: grace)
        let (pidStream, pidContinuation) = AsyncStream<pid_t>.makeStream()
        let task = Task {
            defer { pidContinuation.finish() }
            for try await event in runner.events(shell, arguments: ["-c", script]) {
                if case .stdout(let line) = event, let pid = pid_t(line) {
                    pidContinuation.yield(pid)
                }
            }
        }
        var pids: [pid_t] = []
        for await pid in pidStream {
            pids.append(pid)
            if pids.count == 2 { break }
        }
        #expect(pids.count == 2)
        #expect(pids.allSatisfy(isAlive))
        task.cancel()
        _ = await task.result
        return pids
    }

    private func allExited(_ pids: [pid_t], timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !pids.contains(where: isAlive) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
