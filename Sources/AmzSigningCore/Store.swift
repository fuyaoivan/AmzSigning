import Foundation
import Darwin

public struct Paths {
    public let base: URL
    public init(base: URL) { self.base = base }
    public static func projectDirectory(executable: URL) throws -> URL {
        var directory = executable.standardizedFileURL.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" { return directory.deletingLastPathComponent() }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) { return directory }
            directory.deleteLastPathComponent()
        }
        throw AmzError("无法定位 AmzSigning 目录，请从安装后的应用启动")
    }
    public static func local() throws -> Paths {
        Paths(base: try projectDirectory(executable: URL(fileURLWithPath: CommandLine.arguments[0]))
            .appendingPathComponent("Data", isDirectory: true))
    }
    public var temporary: URL { base.appendingPathComponent("Temp", isDirectory: true) }
    public var scheduler: URL { base.appendingPathComponent("AmzSigningAgent.plist") }
    public var state: URL { base.appendingPathComponent("state.json") }
    public var logs: URL { base.appendingPathComponent("Logs", isDirectory: true) }
    public var builds: URL { base.appendingPathComponent("Builds", isDirectory: true) }
    public var backups: URL { base.appendingPathComponent("ProfileBackups", isDirectory: true) }
    public func prepare() throws {
        for url in [base, logs, builds, backups, temporary] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
    }
}

public final class FileLock {
    private var descriptor: Int32
    public init(url: URL, nonblocking: Bool = false) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AmzError("无法创建锁：\(url.lastPathComponent)") }
        if flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) != 0 {
            close(descriptor); descriptor = -1
            throw AmzError("另一项 AmzSigning 任务正在执行")
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}

public final class StateStore {
    public let paths: Paths
    public init(paths: Paths? = nil) throws { self.paths = try paths ?? Paths.local(); try self.paths.prepare() }
    private func readUnlocked() throws -> State {
        guard FileManager.default.fileExists(atPath: paths.state.path) else { return State() }
        let state = try JSONDecoder.amz.decode(State.self, from: Data(contentsOf: paths.state))
        return state
    }
    public func read() throws -> State {
        let lock = try FileLock(url: paths.base.appendingPathComponent("state.lock"))
        return try withExtendedLifetime(lock) { try readUnlocked() }
    }
    @discardableResult public func update(_ mutate: (inout State) throws -> Void) throws -> State {
        let lock = try FileLock(url: paths.base.appendingPathComponent("state.lock"))
        return try withExtendedLifetime(lock) {
            var state = try readUnlocked()
            try mutate(&state)
            try JSONEncoder.amz.encode(state).write(to: paths.state, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.state.path)
            return state
        }
    }
    public func updateProject(_ id: String, managementID: String? = nil, _ mutate: (inout Project) throws -> Void) throws {
        try update { state in
            guard let index = state.projects.firstIndex(where: { $0.id == id && (managementID == nil || $0.managementID == managementID) }) else { return }
            try mutate(&state.projects[index])
        }
    }
    public func activity(_ text: String?) throws {
        try update { $0.activity = text; $0.activityPID = text == nil ? nil : getpid() }
    }
    public func bootstrap() throws {
        if !FileManager.default.fileExists(atPath: paths.state.path) {
            try update { _ in }
        } else {
            let data = try Data(contentsOf: paths.state)
            let version = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int
            if version == 1 { try update { _ in } }
        }
    }
}

extension JSONEncoder {
    public static var amz: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
extension JSONDecoder {
    public static var amz: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
