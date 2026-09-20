import Foundation
import AmzSigningCore
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "tick"
let permitted = ["tick", "check", "scan", "renew", "status", "install-agent"]
guard permitted.contains(command) else {
    print("用法：AmzSigningAgent [tick|check|scan [directory ...]|renew [project-id]|status|install-agent]")
    exit(64)
}

func deliverNotice(store: StateStore, runner: CommandRunning) throws {
    guard let notice = try store.read().notice, !notice.attempted else { return }
    let application = store.paths.base.deletingLastPathComponent().appendingPathComponent("AmzSigning.app/Contents/MacOS/AmzSigning")
    guard FileManager.default.isExecutableFile(atPath: application.path) else { return }
    // Claim before launching so a killed process cannot create a notification loop.
    try store.update { if $0.notice?.id == notice.id { $0.notice?.attempted = true } }
    _ = try? runner.run(application.path, ["--notify", notice.id], timeout: 15)
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
    // Persist requests before acquiring the worker lock so contention cannot lose them.
    if command == "scan", arguments.count > 1 { try store.update { $0.requestScan(roots: Array(arguments.dropFirst())) } }
    let lock: FileLock
    do { lock = try FileLock(url: paths.base.appendingPathComponent("worker.lock"), nonblocking: true) }
    catch { print(error.localizedDescription); exit(0) }
    try withExtendedLifetime(lock) {
        let runner = CommandRunner(paths: paths)
        let profiles = ProfileManager(runner: runner, paths: paths)
        try profiles.recover()
        try Maintenance.clean(paths: paths)
        defer { try? Maintenance.clean(paths: paths) }
        var state = try store.read()
        if state.activity != nil { try store.activity(nil) }
        guard state.needsToolchain || command == "check" else { return }
        let renewDue = state.projects.contains { state.eligible($0, at: Date()) }
        let checker = XcodeToolchain(runner: runner) { runner.developerDirectory = $0 }
        let force = command == "check" || command == "renew" || command == "scan" || ((state.pendingScan != nil || renewDue) && state.toolchain?.issue == nil)
        let ready = try ToolchainMonitor(store: store, checker: checker).prepare(force: force)
        try deliverNotice(store: store, runner: runner)
        guard ready else { return }
        state = try store.read()
        guard state.pendingScan != nil || command == "renew" || state.projects.contains(where: { state.eligible($0, at: Date()) }) else { return }
        defer { try? store.activity(nil) }
        if state.pendingScan != nil {
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
        let result = try engine.execute(force: command == "renew", projectID: command == "renew" && arguments.count > 1 ? arguments[1] : nil, logPath: log.path)
        try deliverNotice(store: store, runner: runner)
        if let result { print(result.messages.joined(separator: "\n")) }
    }
} catch {
    fputs("AmzSigning：\(error.localizedDescription)\n", stderr)
    if let store = try? StateStore() {
        _ = try? store.update {
            $0.activity = nil; $0.activityPID = nil
            var result = RunResult(trigger: "执行异常")
            result.finished = Date(); result.failureCount = 1; result.messages = [error.localizedDescription]
            $0.recentRuns.insert(result, at: 0); $0.recentRuns = Array($0.recentRuns.prefix(Maintenance.logCount))
        }
    }
    exit(1)
}
