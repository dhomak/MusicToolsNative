import Foundation
import Darwin

/// Special exit codes shared by the tools and the status badge.
/// Real process exits are 0…255 (130 = cancelled), so negatives are safe sentinels.
enum ToolExit {
    static let empty: Int32 = -2   // finished cleanly, but there was nothing to do
}

/// Tracks running process-group leaders so the app can kill them all on quit.
/// Lives outside the @MainActor class so it's reachable from any thread.
enum JobRegistry {
    private static let lock = NSLock()
    private static var pgids = Set<pid_t>()

    static func add(_ p: pid_t)    { lock.lock(); pgids.insert(p); lock.unlock() }
    static func remove(_ p: pid_t) { lock.lock(); pgids.remove(p); lock.unlock() }
    static func killAll() {
        lock.lock(); let snapshot = pgids; lock.unlock()
        for p in snapshot { kill(-p, SIGTERM) }
    }
}

/// Thread-safe text accumulator: appended off the main actor by the pipe
/// reader, drained on the main actor by the flush timer.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    func drain() -> String { lock.lock(); let s = text; text = ""; lock.unlock(); return s }
}

/// Thread-safe latest-progress holder (0...1), set off-actor, read on main.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func set(_ v: Double) { lock.lock(); value = v; lock.unlock() }
    func take() -> Double? { lock.lock(); let v = value; value = nil; lock.unlock(); return v }
}

/// Runs one script as a subprocess and streams its output. Each job runs in its
/// OWN process group, so cancelling kills the script *and* its children (e.g. a
/// running ffmpeg) instead of orphaning them. Console updates are coalesced on a
/// timer to keep the UI smooth under chatty output.
@MainActor
final class ToolRunner: ObservableObject {
    @Published var lines: [String] = []
    @Published var isRunning = false
    @Published var exitCode: Int32?
    @Published var progress: Double?        // 0...1 when a tool emits __PROGRESS__

    private var pid: pid_t = -1
    private var readFH: FileHandle?
    private var flushTimer: Timer?
    private var nativeTask: Task<Void, Never>?

    private let buffer = LineBuffer()        // raw pipe bytes, thread-safe
    private let progressBox = ProgressBox()  // latest native-job progress
    private var lineBuf = ""                 // partial-line assembly (main only)
    private let maxLines = 5000

    func run(_ cmd: Cmd, onFinish: (() -> Void)? = nil) {
        guard !isRunning else { return }
        lines.removeAll(); _ = buffer.drain(); lineBuf = ""
        exitCode = nil; progress = nil; isRunning = true

        let argv = [cmd.exe.path] + cmd.args
        let result: (pid_t, FileHandle)
        do {
            result = try Self.spawn(path: cmd.exe.path, argv: argv, env: cmd.env)
        } catch {
            appendLines(["[ERROR] \(error.localizedDescription)"])
            isRunning = false
            return
        }
        pid = result.0
        readFH = result.1
        JobRegistry.add(pid)

        readFH?.readabilityHandler = { [buffer] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            buffer.append(String(decoding: d, as: UTF8.self))
        }

        startFlushTimer()

        let childPid = pid
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(childPid, &status, 0)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            JobRegistry.remove(childPid)
            Task { [weak self] in await self?.finish(code: code, onFinish: onFinish) }
        }
    }

    /// Run a native in-process job (no subprocess). `op` streams log lines via
    /// `emit` and 0...1 progress via `progress`, returning an exit code.
    func runNative(_ op: @escaping @Sendable (_ emit: @escaping @Sendable (String) -> Void,
                                              _ progress: @escaping @Sendable (Double) -> Void) async -> Int32) {
        guard !isRunning else { return }
        lines.removeAll(); _ = buffer.drain(); _ = progressBox.take(); lineBuf = ""
        exitCode = nil; progress = nil; isRunning = true
        startFlushTimer()

        let emit: @Sendable (String) -> Void = { [buffer] s in buffer.append(s + "\n") }
        let prog: @Sendable (Double) -> Void = { [progressBox] p in progressBox.set(p) }

        nativeTask = Task.detached { [weak self] in
            let code = await op(emit, prog)
            await self?.finishNative(code: code)
        }
    }

    func cancel() {
        nativeTask?.cancel()
        guard pid > 0 else { return }
        let group = pid
        kill(-group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(-group, SIGKILL) }
    }

    func clear() { lines.removeAll(); exitCode = nil; progress = nil }

    // MARK: - private

    private func startFlushTimer() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.flush() }
        }
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
    }

    private func finishNative(code: Int32) {
        flush()
        flushTimer?.invalidate(); flushTimer = nil
        nativeTask = nil
        isRunning = false
        exitCode = code
        if progress != nil, code == 0 { progress = 1.0 }
    }

    private func finish(code: Int32, onFinish: (() -> Void)?) {
        flush()
        flushTimer?.invalidate(); flushTimer = nil
        readFH?.readabilityHandler = nil
        try? readFH?.close(); readFH = nil
        pid = -1
        isRunning = false
        exitCode = code
        if progress != nil { progress = code == 0 ? 1.0 : progress }
        onFinish?()
    }

    private func flush() {
        if let p = progressBox.take() { progress = min(max(p, 0), 1) }
        let chunk = buffer.drain()
        guard !chunk.isEmpty else { return }
        lineBuf += chunk
        let parts = lineBuf.components(separatedBy: "\n")
        lineBuf = parts.last ?? ""
        var out: [String] = []
        for raw in parts.dropLast() {
            if let pct = Self.parseProgress(raw) { progress = pct; continue }
            out.append(Self.stripANSI(raw))
        }
        if !out.isEmpty { appendLines(out) }
    }

    private func appendLines(_ ls: [String]) {
        lines.append(contentsOf: ls)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    private static func parseProgress(_ s: String) -> Double? {
        guard s.hasPrefix("__PROGRESS__") else { return nil }
        let parts = s.split(separator: " ")
        guard parts.count >= 2, let v = Double(parts[1]) else { return nil }
        return min(max(v / 100.0, 0), 1)
    }

    private static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]",
                               with: "", options: .regularExpression)
    }

    /// posix_spawn in a NEW process group, stdin=/dev/null, stdout+stderr -> one pipe.
    private static func spawn(path: String, argv: [String], env: [String: String]) throws -> (pid_t, FileHandle) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw err("pipe failed") }
        let readFD = fds[0], writeFD = fds[1]
        let devnull = open("/dev/null", O_RDONLY)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, devnull, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawn_file_actions_addclose(&actions, devnull)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)              // new group; pgid = child pid

        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        let cPath = strdup(path)

        var newPid: pid_t = 0
        let rc = posix_spawn(&newPid, cPath, &actions, &attr, cArgs, cEnv)

        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        free(cPath)
        for p in cArgs where p != nil { free(p) }
        for p in cEnv where p != nil { free(p) }
        close(writeFD)
        close(devnull)

        if rc != 0 {
            close(readFD)
            throw err("posix_spawn: \(String(cString: strerror(rc)))")
        }
        return (newPid, FileHandle(fileDescriptor: readFD, closeOnDealloc: true))
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "ToolRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
