import Foundation
import AmzSigningCore
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "tick"
let permitted = ["tick", "scan", "renew", "status", "install-agent"]
guard permitted.contains(command) else {
    print("用法：AmzSigningAgent [tick|scan [directory ...]|renew [project-id]|status|install-agent]")
    exit(64)
}

do {
    let paths = try Paths.local()
    let store = try StateStore(paths: paths)
    if command == "status" {
        print(String(decoding: try JSONEncoder.amz.encode(store.read()), as: UTF8.self)); exit(0)
    }
    try store.bootstrap()
    if command == "install-agent" {
        try Scheduler.install(worker: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path, paths: paths)
        print("按需调度已安装"); exit(0)
    }
    // Persist explicit requests before acquiring the worker lock, so a busy task cannot lose them.
    if command == "scan", arguments.count > 1 { try store.update { $0.requestScan(roots: Array(arguments.dropFirst())) } }
    let lock: FileLock
    do { lock = try FileLock(url: paths.base.appendingPathComponent("worker.lock"), nonblocking: true) }
    catch { print(error.localizedDescription); exit(0) }
    try withExtendedLifetime(lock) {
        let runner = CommandRunner(paths: paths)
        let profiles = ProfileManager(runner: runner, paths: paths)
        // Recover journalled profile moves even when the next task is not due.
        try profiles.recover()
        // Local resource retention is independent of discovery and renewal eligibility.
        try Maintenance.clean(paths: paths)
        var state = try store.read()
        let now = Date()
        let hasScanRequest = state.pendingScan != nil
        let renewDue = command == "renew" || state.projects.contains { state.eligible($0, at: now) }
        if !hasScanRequest && !renewDue && state.activity == nil { return }
        try store.activity(nil)
        defer { try? Maintenance.clean(paths: paths); try? store.activity(nil) }
        if hasScanRequest {
            try store.activity("正在扫描 iPhone 项目")
            let scanner = XcodeScanner(runner: runner, profiles: profiles)
            try ProjectDiscovery(store: store, scanner: scanner).runPending()
            try store.activity(nil)
        }
        if command == "scan" { print("扫描完成"); return }
        state = try store.read()
        if state.mode == .away { return }
        let log = paths.logs.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).log")
        runner.logURL = log
        let engine = RenewalEngine(store: store, renewer: XcodeRenewer(runner: runner, paths: paths))
        let result = try engine.execute(force: command == "renew", projectID: arguments.count > 1 ? arguments[1] : nil, logPath: log.path)
        if let result { print(result.messages.joined(separator: "\n")) }
    }
} catch {
    fputs("AmzSigning：\(error.localizedDescription)\n", stderr)
    // Never reset a malformed state file or mark an unverified install successful.
    if let store = try? StateStore() {
        _ = try? store.update {
            $0.activity = nil; $0.activityPID = nil
            var result = RunResult(trigger: "执行异常")
            result.finished = Date(); result.failureCount = 1; result.messages = [error.localizedDescription]
            $0.recentRuns.insert(result, at: 0); $0.recentRuns = Array($0.recentRuns.prefix(20))
        }
    }
    exit(1)
}
