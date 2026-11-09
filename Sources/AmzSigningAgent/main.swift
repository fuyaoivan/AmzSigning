import Foundation
import AmzSigningCore
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "tick"
let permitted = ["tick", "check", "scan", "renew", "retry", "status", "install-agent", "devices", "install-device"]
guard permitted.contains(command) else {
    print("用法：AmzSigningAgent [tick|check|scan [directory ...]|renew [project-id]|retry|status|install-agent|devices|install-device <request-json>]")
    exit(64)
}

func deliverNotice(store: StateStore, runner: CommandRunning) throws {
    let application = store.paths.base.deletingLastPathComponent().appendingPathComponent("AmzSigning.app/Contents/MacOS/AmzSigning")
    try NoticeDelivery(store: store).dispatch(runner: runner, application: application)
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
    catch { fputs(error.localizedDescription + "\n", stderr); exit(command == "devices" || command == "install-device" ? 75 : 0) }
    try withExtendedLifetime(lock) {
        let runner = CommandRunner(paths: paths)
        let profiles = ProfileManager(runner: runner, paths: paths)
        try profiles.recover()
        try Maintenance.clean(paths: paths)
        defer { try? Maintenance.clean(paths: paths) }
        var state = try store.read()
        if state.activity != nil { try store.activity(nil) }
        guard state.needsToolchain || ["check", "devices", "install-device"].contains(command) else { return }
        let renewDue = state.projects.contains { state.eligible($0, at: Date()) }
        let checker = XcodeToolchain(runner: runner) { runner.developerDirectory = $0 }
        let force = command == "devices" || command == "install-device" || command == "check" || command == "renew" || command == "retry" || command == "scan" || ((state.pendingScan != nil || renewDue) && state.toolchain?.issue == nil)
        let ready = try ToolchainMonitor(store: store, checker: checker).prepare(force: force)
        try deliverNotice(store: store, runner: runner)
        guard ready else {
            if command == "devices" || command == "install-device" { throw SetupRequired(try store.read().toolchain?.issue ?? .toolsUnavailable) }
            return
        }
        if command == "devices" {
            let devices = try DeviceManager(runner: runner, paths: paths).list()
            print(String(decoding: try JSONEncoder.amz.encode(devices), as: UTF8.self)); return
        }
        if command == "install-device" {
            guard arguments.count == 2 else { throw AmzError("缺少安装请求") }
            let request = try JSONDecoder.amz.decode(InstallationRequest.self, from: Data(arguments[1].utf8))
            let log = paths.logs.appendingPathComponent("install-\(UUID().uuidString).log")
            runner.logURL = log
            let result = try InstallationEngine(store: store, installer: XcodeRenewer(runner: runner, paths: paths)).execute(request, logPath: log.path)
            print(result.messages.joined(separator: "\n")); return
        }
        state = try store.read()
        guard state.pendingScan != nil || command == "renew" || command == "retry" || state.projects.contains(where: { state.eligible($0, at: Date()) }) else { return }
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
        let result = try engine.execute(force: command == "renew" || command == "retry", projectID: command == "renew" && arguments.count > 1 ? arguments[1] : nil, logPath: log.path, failedOnly: command == "retry")
        try deliverNotice(store: store, runner: runner)
        if let result { print(result.messages.joined(separator: "\n")) }
    }
} catch {
    fputs("AmzSigning：\(error.localizedDescription)\n", stderr)
    if command != "devices", let store = try? StateStore() {
        _ = try? store.update {
            $0.activity = nil; $0.activityPID = nil
            var result = RunResult(trigger: "执行异常")
            result.finished = Date(); result.failureCount = 1; result.messages = [error.localizedDescription]
            $0.recentRuns.insert(result, at: 0); $0.recentRuns = Array($0.recentRuns.prefix(Maintenance.logCount))
        }
    }
    exit(1)
}
