import Foundation
import Darwin

public struct CommandOutput {
    public let status: Int32
    public let data: Data
    public var text: String { String(decoding: data, as: UTF8.self) }
}

public protocol CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput
}

/// Each subprocess owns a process group. A timeout terminates the entire group,
/// including compiler and signing children, rather than leaving an orphan build.
public final class CommandRunner: CommandRunning {
    public var logURL: URL?
    private let paths: Paths
    public init(paths: Paths, logURL: URL? = nil) { self.paths = paths; self.logURL = logURL }
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        let outputURL = paths.temporary.appendingPathComponent("amzsigning-\(UUID().uuidString).output")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, outputURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TMPDIR"] = paths.temporary.path + "/"
        environment["NSUnbufferedIO"] = "YES"
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argp in
            env.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argp.baseAddress!, envp.baseAddress!)
            }
        }
        guard result == 0 else { throw AmzError("无法启动 \(executable)：\(String(cString: strerror(result)))") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0
        var timedOut = false
        var excessiveOutput = false
        var nextSizeCheck = ProcessInfo.processInfo.systemUptime + 2
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 && errno != EINTR { throw AmzError("无法读取子进程状态") }
            if ProcessInfo.processInfo.systemUptime >= nextSizeCheck {
                excessiveOutput = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.intValue ?? 0 > 32 * 1024 * 1024
                nextSizeCheck = ProcessInfo.processInfo.systemUptime + 2
            }
            if ProcessInfo.processInfo.systemUptime >= deadline || excessiveOutput {
                timedOut = true; kill(-pid, SIGTERM)
                usleep(500_000); kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                break
            }
            usleep(50_000)
        }
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        appendLog("$ \(executable) " + arguments.map { $0.contains(" ") ? "[\($0)]" : $0 }.joined(separator: " ") + "\n")
        appendLog(String(decoding: data.suffix(96_000), as: UTF8.self) + "\n")
        if excessiveOutput { throw AmzError("命令输出超过 32 MB，已结束本次执行并清理临时输出") }
        if timedOut { throw AmzError("执行超时（\(Int(timeout)) 秒），已结束本次进程。\n" + String(decoding: data.suffix(2_000), as: UTF8.self)) }
        return CommandOutput(status: (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f), data: data)
    }
    public func appendLog(_ text: String) {
        guard let url = logURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8))
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue > Maintenance.singleLogBudget,
           let data = try? Data(contentsOf: url) {
            try? (Data("[较早日志已按容量限制回收]\n".utf8) + data.suffix(Maintenance.singleLogBudget - 100)).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

extension CommandRunning {
    @discardableResult public func checked(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> CommandOutput {
        let output = try run(executable, arguments, timeout: timeout)
        guard output.status == 0 else {
            throw AmzError("\(URL(fileURLWithPath: executable).lastPathComponent) 执行失败（\(output.status)）\n" + String(output.text.suffix(4000)))
        }
        return output
    }
    public func json(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> Any {
        let result = try checked(executable, arguments, timeout: timeout)
        // xcodebuild can print informational lines before its JSON payload.
        let bytes = Array(result.data)
        for index in bytes.indices where bytes[index] == 0x7b || bytes[index] == 0x5b {
            if let value = try? JSONSerialization.jsonObject(with: Data(bytes[index...])) { return value }
        }
        throw AmzError("\(executable) 未返回有效 JSON")
    }
}
