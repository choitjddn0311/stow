import Darwin
import Foundation

/// 실행 중인 프로세스에서 나오는 이벤트. `terminated`는 항상 마지막에 한 번 온다.
enum ProcessEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case terminated(ProcessTermination)
}

/// 프로세스 종료 방식.
enum ProcessTermination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    var isSuccess: Bool { self == .exited(0) }

    /// `waitpid` 상태 값을 해석한다(`WIFEXITED`/`WTERMSIG` 매크로는 Swift에서 쓸 수 없다).
    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        self = signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }
}

/// 출력을 모두 모은 실행 결과.
struct ProcessResult: Sendable, Equatable {
    var termination: ProcessTermination
    var stdout: [String]
    var stderr: [String]
}

/// 외부 프로세스를 실행하고 출력을 줄 단위로 전달한다.
///
/// - 인자는 배열로 그대로 전달한다(셸을 거치지 않음).
/// - 프로세스는 새 프로세스 그룹에서 시작한다. 취소하면 그룹 전체(yt-dlp가 띄운 ffmpeg, deno 포함)에
///   SIGTERM을 보내고, `terminationGracePeriod` 뒤에도 남아 있으면 SIGKILL을 보낸다.
/// - stdin은 `/dev/null`이다.
struct ProcessRunner: Sendable {
    var terminationGracePeriod: Duration = .seconds(3)

    /// 프로세스를 시작하고 이벤트 스트림을 돌려준다.
    /// 스트림 소비를 중단하면(작업 취소 포함) 프로세스 그룹을 종료한다.
    /// 시작에 실패하면 스트림이 `EngineError.launchFailed`로 끝난다.
    func events(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let grace = terminationGracePeriod
        return AsyncThrowingStream { continuation in
            let child: SpawnedChild
            do {
                child = try SpawnedChild.spawn(
                    executable: executable.path,
                    arguments: arguments,
                    environment: environment ?? ProcessInfo.processInfo.environment
                )
            } catch {
                continuation.finish(throwing: error)
                return
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    Self.terminateGroup(child.pid, grace: grace)
                }
            }

            let readers = DispatchGroup()
            Self.startReader(fd: child.stdout, group: readers) { continuation.yield(.stdout($0)) }
            Self.startReader(fd: child.stderr, group: readers) { continuation.yield(.stderr($0)) }

            Thread.detachNewThread {
                let termination = Self.waitForExit(child.pid)
                // 출력을 모두 전달한 뒤에 종료를 알린다.
                readers.wait()
                switch termination {
                case .success(let value):
                    continuation.yield(.terminated(value))
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 프로세스를 끝까지 실행하고 출력을 모아 돌려준다. 작업이 취소되면 프로세스를 종료하고
    /// `CancellationError`를 던진다.
    func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        var stdout: [String] = []
        var stderr: [String] = []
        for try await event in events(executable, arguments: arguments, environment: environment) {
            switch event {
            case .stdout(let line): stdout.append(line)
            case .stderr(let line): stderr.append(line)
            case .terminated(let termination):
                return ProcessResult(termination: termination, stdout: stdout, stderr: stderr)
            }
        }
        // 종료 이벤트 없이 스트림이 끝나는 경우는 취소뿐이다.
        throw CancellationError()
    }

    // MARK: - 내부 구현

    private static func terminateGroup(_ pgid: pid_t, grace: Duration) {
        kill(-pgid, SIGTERM)
        let (seconds, attoseconds) = grace.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
            // 이미 모두 종료했다면 ESRCH로 실패하며 아무 일도 일어나지 않는다.
            kill(-pgid, SIGKILL)
        }
    }

    private static func waitForExit(_ pid: pid_t) -> Result<ProcessTermination, POSIXError> {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR {
                return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD))
            }
        }
        return .success(ProcessTermination(waitStatus: status))
    }

    /// 파이프를 블로킹으로 읽어 줄 단위로 전달한다. EOF에서 fd를 닫는다.
    private static func startReader(
        fd: Int32,
        group: DispatchGroup,
        emit: @escaping @Sendable (String) -> Void
    ) {
        group.enter()
        Thread.detachNewThread {
            defer {
                close(fd)
                group.leave()
            }
            var splitter = LineSplitter()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    splitter.append(chunk[0..<count]).forEach(emit)
                } else if count == 0 || errno != EINTR {
                    break
                }
            }
            if let last = splitter.finish() { emit(last) }
        }
    }
}

/// 바이트를 `\n` 기준으로 나눠 줄을 만든다. 줄 끝의 `\r`은 제거하고, UTF-8이 아닌 바이트는 대체 문자로 바꾼다.
struct LineSplitter {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: some Collection<UInt8>) -> [String] {
        pending.append(contentsOf: bytes)
        var lines: [String] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            lines.append(Self.decode(pending[start..<newline]))
            start = newline + 1
        }
        pending.removeSubrange(..<start)
        return lines
    }

    /// 마지막 줄바꿈 뒤에 남은 내용을 돌려준다.
    mutating func finish() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : Self.decode(pending[...])
    }

    private static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        let trimmed = bytes.last == 0x0D ? bytes.dropLast() : bytes
        return String(decoding: trimmed, as: UTF8.self)
    }
}

/// `posix_spawn`으로 시작한 자식 프로세스와 출력 파이프(부모 쪽 읽기 fd).
private struct SpawnedChild: Sendable {
    let pid: pid_t
    let stdout: Int32
    let stderr: Int32

    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws(EngineError) -> SpawnedChild {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw .launchFailed(executable: executable, code: errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            outPipe.forEach { close($0) }
            throw .launchFailed(executable: executable, code: code)
        }
        // 다른 곳에서 동시에 프로세스를 띄울 때 fd가 새지 않게 한다(dup2된 0~2번은 영향 없음).
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETPGROUP(pgid 0): 자식이 새 프로세스 그룹의 리더가 된다 → 취소 시 그룹 단위로 종료.
        // CLOEXEC_DEFAULT: 위에서 지정한 0~2번 외의 fd를 자식에 넘기지 않는다.
        // SETSIGDEF/SETSIGMASK: 앱의 시그널 설정을 물려주지 않는다.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        // 쓰기 쪽은 자식만 가진다. 부모가 닫아야 자식 종료 시 EOF를 받는다.
        close(outPipe[1])
        close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw .launchFailed(executable: executable, code: result)
        }
        return SpawnedChild(pid: pid, stdout: outPipe[0], stderr: errPipe[0])
    }
}
