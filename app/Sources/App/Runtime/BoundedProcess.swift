import Darwin
import Foundation

struct BoundedProcessResult {
    enum Outcome: Equatable {
        case exit(Int32)
        case timeout
        case capped
    }

    let outcome: Outcome
    let stdout: Data
    let stderr: Data
}

enum BoundedProcess {
    static let streamLimit = 1_048_576

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        deadline: TimeInterval = 2
    ) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()

        let outputDrain = BoundedPipeDrain(stdout.fileHandleForReading)
        let errorDrain = BoundedPipeDrain(stderr.fileHandleForReading)
        outputDrain.start()
        errorDrain.start()

        let reaped = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            reaped.signal()
        }

        let finished = reaped.wait(timeout: .now() + max(0, deadline)) == .success
        if !finished {
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
            if reaped.wait(timeout: .now() + 0.2) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = reaped.wait(timeout: .now() + 0.2)
            }
        }
        outputDrain.stop()
        errorDrain.stop()
        let output = outputDrain.finish()
        let error = errorDrain.finish()
        let outcome: BoundedProcessResult.Outcome
        if !finished {
            outcome = .timeout
        } else if output.capped || error.capped {
            outcome = .capped
        } else {
            outcome = .exit(process.terminationStatus)
        }
        return BoundedProcessResult(outcome: outcome, stdout: output.data, stderr: error.data)
    }
}

private final class BoundedPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()
    private var capped = false
    private var stopping = false

    init(_ handle: FileHandle) { self.handle = handle }

    func start() {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { done.signal() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    lock.lock()
                    let remaining = max(0, BoundedProcess.streamLimit - data.count)
                    data.append(contentsOf: buffer.prefix(min(count, remaining)))
                    if count > remaining { capped = true }
                    let shouldStop = stopping && capped
                    lock.unlock()
                    if shouldStop { return }
                    continue
                }
                if count == 0 { return }
                if errno != EAGAIN && errno != EINTR { return }
                lock.lock()
                let shouldStop = stopping
                lock.unlock()
                if shouldStop { return }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    func finish() -> (data: Data, capped: Bool) {
        _ = done.wait(timeout: .now() + 0.2)
        lock.lock()
        let result = (data, capped)
        lock.unlock()
        handle.closeFile()
        return result
    }
}
