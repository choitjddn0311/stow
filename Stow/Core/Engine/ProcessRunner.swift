import Darwin
import Foundation
import os

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
/// - 프로세스가 끝난 뒤에도 출력 파이프를 쥔 프로세스가 남아 있으면 `terminationGracePeriod` 뒤
///   그룹에 SIGKILL을 보내고 종료를 알린다(종료 이벤트가 한없이 늦어지지 않게).
/// - stdin은 `/dev/null`이다.
struct ProcessRunner: Sendable {
    var terminationGracePeriod: Duration = .seconds(3)

    /// 프로세스를 시작하고 이벤트 스트림을 돌려준다.
    /// 스트림 소비를 중단하면(작업 취소 포함) 프로세스 그룹을 종료한다(종료를 기다리지는 않는다).
    /// 시작에 실패하면 스트림이 `EngineError.launchFailed`로 끝난다.
    func events(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) -> AsyncThrowingStream<ProcessEvent, any Error> {
        start(executable, arguments: arguments, environment: environment).stream
    }

    /// 프로세스를 끝까지 실행하며 출력 이벤트를 `onEvent`로 전달하고 종료 방식을 돌려준다.
    /// 작업이 취소되면 프로세스 그룹을 종료하고, **프로세스가 실제로 끝난 뒤에** `CancellationError`를 던진다.
    /// 그래서 호출한 쪽은 취소 뒤 바로 작업 파일을 정리해도 자식이 아직 쓰고 있을 걱정이 없다.
    func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        onEvent: @escaping @Sendable (ProcessEvent) -> Void
    ) async throws -> ProcessTermination {
        let (stream, terminate) = start(executable, arguments: arguments, environment: environment)
        // 별도 작업에서 소비해, 호출한 작업이 취소되어도 프로세스가 끝날 때까지 읽는다.
        let consumer = Task {
            var termination: ProcessTermination?
            for try await event in stream {
                if case .terminated(let value) = event {
                    termination = value
                } else {
                    onEvent(event)
                }
            }
            return termination
        }
        let termination = try await withTaskCancellationHandler {
            try await consumer.value
        } onCancel: {
            terminate()
        }
        try Task.checkCancellation()
        guard let termination else { throw CancellationError() }
        return termination
    }

    private func start(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]?
    ) -> (stream: AsyncThrowingStream<ProcessEvent, any Error>, terminate: @Sendable () -> Void) {
        let grace = terminationGracePeriod
        // AsyncThrowingStream의 build 클로저는 init 안에서 바로 실행된다.
        var spawnedGroup: ProcessGroup?
        let stream = AsyncThrowingStream<ProcessEvent, any Error> { continuation in
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

            let group = ProcessGroup(pgid: child.pid)
            spawnedGroup = group
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    group.terminate(grace: grace)
                }
            }

            let readers = DispatchGroup()
            Self.startReader(fd: child.stdout, group: readers) { continuation.yield(.stdout($0)) }
            Self.startReader(fd: child.stderr, group: readers) { continuation.yield(.stderr($0)) }
            readers.notify(queue: .global()) { group.markOutputClosed() }

            Thread.detachNewThread {
                let termination = group.waitForLeaderExit()
                // 출력을 모두 전달한 뒤에 종료를 알린다. 파이프를 쥔 프로세스(남은 손자 등)가 있으면
                // 유예 시간 뒤 그룹을 종료하고, 그래도 닫히지 않으면(그룹 밖 프로세스) 더 기다리지 않는다.
                if readers.wait(timeout: .now() + grace.dispatchInterval) == .timedOut {
                    group.signal(SIGKILL)
                    _ = readers.wait(timeout: .now() + .seconds(1))
                }
                switch termination {
                case .success(let value):
                    continuation.yield(.terminated(value))
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
        let group = spawnedGroup
        return (stream, { group?.terminate(grace: grace) })
    }

    /// 프로세스를 끝까지 실행하고 출력을 모아 돌려준다. 작업이 취소되면 프로세스를 종료하고,
    /// 끝난 뒤 `CancellationError`를 던진다.
    func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        let output = OutputCollector()
        let termination = try await run(
            executable, arguments: arguments, environment: environment, onEvent: { output.append($0) }
        )
        return output.result(termination)
    }

    // MARK: - 내부 구현

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

/// 바이트를 줄로 나눈다. `\n`, `\r`, `\r\n`을 모두 줄 끝으로 본다(`\r`로 같은 줄을 다시 그리는
/// 진행률 출력 대응). UTF-8이 아닌 바이트는 대체 문자로 바꾼다.
struct LineSplitter {
    private var pending: [UInt8] = []
    /// 직전 바이트가 `\r`이었는지. `\r\n`이 청크 경계에서 나뉘어도 한 번의 줄 끝으로 처리한다.
    private var afterCarriageReturn = false

    mutating func append(_ bytes: some Collection<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            switch byte {
            case 0x0A where afterCarriageReturn:
                afterCarriageReturn = false
            case 0x0A:
                lines.append(takeLine())
            case 0x0D:
                lines.append(takeLine())
                afterCarriageReturn = true
            default:
                afterCarriageReturn = false
                pending.append(byte)
            }
        }
        return lines
    }

    /// 마지막 줄 끝 뒤에 남은 내용을 돌려준다.
    mutating func finish() -> String? {
        afterCarriageReturn = false
        return pending.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// 자식 프로세스 그룹. 리더(직접 띄운 자식)를 회수한 뒤에는 pid가 재사용될 수 있으므로,
/// 리더가 회수되었고 출력 파이프도 모두 닫혔다면 그룹에 시그널을 보내지 않는다.
/// (그룹에 프로세스가 하나라도 남아 있는 동안에는 pgid가 재사용되지 않는다.)
private final class ProcessGroup: Sendable {
    private struct State {
        var leaderReaped = false
        var outputClosed = false
    }

    let pgid: pid_t
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(pgid: pid_t) {
        self.pgid = pgid
    }

    func signal(_ signal: Int32) {
        state.withLock { state in
            if !state.leaderReaped || !state.outputClosed {
                kill(-pgid, signal)
            }
        }
    }

    /// SIGTERM을 보내고, 유예 시간 뒤 SIGKILL을 보낸다.
    func terminate(grace: Duration) {
        signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace.dispatchInterval) { [self] in
            signal(SIGKILL)
        }
    }

    func markOutputClosed() {
        state.withLock { $0.outputClosed = true }
    }

    /// 리더가 끝날 때까지 기다렸다가 회수한다. 종료를 먼저 확인(WNOWAIT)하고 잠금 안에서 회수해,
    /// 회수 직후 재사용된 pid에 시그널을 보내는 경쟁을 막는다.
    func waitForLeaderExit() -> Result<ProcessTermination, POSIXError> {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pgid), &info, WEXITED | WNOWAIT) == -1 {
            if errno != EINTR { return .failure(Self.currentError()) }
        }
        return state.withLock { state in
            var status: Int32 = 0
            while waitpid(pgid, &status, 0) == -1 {
                if errno != EINTR { return .failure(Self.currentError()) }
            }
            state.leaderReaped = true
            return .success(ProcessTermination(waitStatus: status))
        }
    }

    private static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
    }
}

/// 여러 스레드에서 오는 출력을 모은다.
private final class OutputCollector: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: (stdout: [String](), stderr: [String]()))

    func append(_ event: ProcessEvent) {
        lines.withLock { lines in
            switch event {
            case .stdout(let line): lines.stdout.append(line)
            case .stderr(let line): lines.stderr.append(line)
            case .terminated: break
            }
        }
    }

    func result(_ termination: ProcessTermination) -> ProcessResult {
        lines.withLock { ProcessResult(termination: termination, stdout: $0.stdout, stderr: $0.stderr) }
    }
}

private extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
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
