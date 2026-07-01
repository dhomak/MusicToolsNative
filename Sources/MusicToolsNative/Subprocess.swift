import Foundation

/// Thread-safe output accumulator that can also stream complete lines.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all = ""
    private var lineBuf = ""
    private let onLine: (@Sendable (String) -> Void)?
    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func feed(_ s: String) {
        lock.lock()
        all += s; lineBuf += s
        let parts = lineBuf.components(separatedBy: "\n")
        lineBuf = parts.last ?? ""
        let complete = Array(parts.dropLast())
        lock.unlock()
        if let onLine { for l in complete where !l.isEmpty { onLine(l) } }
    }
    func flushRemaining() {
        lock.lock(); let rest = lineBuf; lineBuf = ""; lock.unlock()
        if let onLine, !rest.isEmpty { onLine(rest) }
    }
    func text() -> String { lock.lock(); let s = all; lock.unlock(); return s }
}

/// Owns one child process + its read pipe. @unchecked Sendable so its methods can
/// run from @Sendable callbacks (readability/termination handlers, cancel handler)
/// without capturing the non-Sendable Process/FileHandle directly.
private final class Runner: @unchecked Sendable {
    let proc: Process
    let fh: FileHandle
    let collector: OutputCollector
    private let lock = NSLock()
    private var resumed = false
    var cont: CheckedContinuation<(code: Int32, output: String), Never>?

    init(_ proc: Process, _ fh: FileHandle, _ collector: OutputCollector) {
        self.proc = proc; self.fh = fh; self.collector = collector
    }

    /// Data arrived (or EOF). Empty data == EOF == completion.
    func onData() {
        let d = fh.availableData
        if d.isEmpty { finish() }
        else { collector.feed(String(decoding: d, as: UTF8.self)) }
    }

    /// Resume exactly once: drain anything left, reap the process, return status.
    func finish() {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let c = cont; cont = nil
        lock.unlock()

        fh.readabilityHandler = nil
        if let rest = (try? fh.readToEnd()), !rest.isEmpty {
            collector.feed(String(decoding: rest, as: UTF8.self))
        }
        collector.flushRemaining()
        proc.waitUntilExit()
        let code = proc.terminationStatus
        try? fh.close()
        c?.resume(returning: (code, collector.text()))
    }

    func failSpawn(_ msg: String) {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let c = cont; cont = nil
        lock.unlock()
        c?.resume(returning: (127, msg))
    }

    /// Stop: SIGTERM, then SIGKILL if it's still alive a moment later.
    func terminateHard() {
        guard proc.isRunning else { return }
        proc.terminate()
        let p = proc
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}

enum Subprocess {
    /// Run a command to completion, streaming complete lines via `onLine`.
    /// Direct exec (no shell), stdin=/dev/null, stdout+stderr merged.
    ///
    /// Completion is driven by the pipe reaching EOF (event-driven, no blocked
    /// thread). A termination handler is a safety net: if the process dies but
    /// EOF is somehow delayed, it forces completion after a short grace so a job
    /// can never hang forever. Cancellable: the surrounding Task being cancelled
    /// terminates the process (SIGTERM, then SIGKILL).
    static func run(_ exe: URL, _ args: [String], env: [String: String],
                    onLine: (@Sendable (String) -> Void)? = nil) async -> (code: Int32, output: String) {
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = args
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let runner = Runner(proc, pipe.fileHandleForReading, OutputCollector(onLine: onLine))

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<(code: Int32, output: String), Never>) in
                runner.cont = cont
                runner.fh.readabilityHandler = { _ in runner.onData() }
                proc.terminationHandler = { _ in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { runner.finish() }
                }
                do {
                    try proc.run()
                    // Close the parent's write end so the reader can see EOF once
                    // the child exits (the child keeps its own dup of the fd).
                    try? pipe.fileHandleForWriting.close()
                } catch {
                    runner.failSpawn("spawn error: \(error.localizedDescription)")
                }
            }
        } onCancel: {
            runner.terminateHard()
        }
    }
}
