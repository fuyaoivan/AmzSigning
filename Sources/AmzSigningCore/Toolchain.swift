import Foundation
import CryptoKit

public enum SetupIssue: String, Codable, Equatable {
    case xcodeMissing, license, firstLaunch, sdkMissing, toolsUnavailable
    case account, deviceTrust, developerMode, deviceSupport, deviceLocked

    public var title: String {
        switch self {
        case .xcodeMissing: return "未找到完整 Xcode"
        case .license: return "Xcode 许可协议待确认"
        case .firstLaunch: return "Xcode 初始化未完成"
        case .sdkMissing: return "缺少 iPhone 构建组件"
        case .toolsUnavailable: return "Xcode 工具暂不可用"
        case .account: return "Apple 账号需要重新登录"
        case .deviceTrust: return "iPhone 需要重新信任或配对"
        case .developerMode: return "iPhone 开发者模式未启用"
        case .deviceSupport: return "Xcode 需要更新设备支持组件"
        case .deviceLocked: return "iPhone 需要解锁"
        }
    }
    public var guidance: String {
        switch self {
        case .xcodeMissing: return "安装完整 Xcode 并完成首次启动。"
        case .license: return "打开 Xcode，阅读并确认更新后的许可协议。"
        case .firstLaunch: return "打开 Xcode，完成组件初始化及系统授权。"
        case .sdkMissing: return "在 Xcode 设置的组件页面安装 iOS 平台支持。"
        case .toolsUnavailable: return "检查 Xcode 是否仍在更新；完成后会自动重新检查。"
        case .account: return "在 Xcode 设置的 Apple 账号页面重新登录。"
        case .deviceTrust: return "连接并解锁目标 iPhone，完成设备信任与配对。"
        case .developerMode: return "在 iPhone 的隐私与安全性设置中启用开发者模式，并完成系统确认。"
        case .deviceSupport: return "使用支持当前 iOS 的 Xcode，并完成设备支持组件初始化。"
        case .deviceLocked: return "解锁目标 iPhone，完成更新后的首次设备准备。"
        }
    }
    public var isToolchain: Bool {
        switch self {
        case .xcodeMissing, .license, .firstLaunch, .sdkMissing, .toolsUnavailable: return true
        default: return false
        }
    }
    public static func classify(_ message: String) -> SetupIssue? {
        let text = CommandDiagnostics.failureText(message).lowercased()
        if text.contains("license") && (text.contains("not agreed") || text.contains("requires acceptance") || text.contains("agree to")) { return .license }
        if text.contains("runfirstlaunch") || text.contains("first launch tasks") { return .firstLaunch }
        if text.contains("invalid active developer path") || text.contains("requires xcode") { return .xcodeMissing }
        if text.contains("sdk") && text.contains("iphoneos") && (text.contains("cannot be located") || text.contains("not found")) { return .sdkMissing }
        if text.contains("developer mode") && (text.contains("disabled") || text.contains("not enabled")) { return .developerMode }
        if text.contains("not paired") || text.contains("pairing is required") || text.contains("not trusted") { return .deviceTrust }
        if text.contains("device is currently locked") || text.contains("device was still locked") || text.contains("unlock the device") { return .deviceLocked }
        if text.contains("failed to prepare device for development") || text.contains("could not locate device support files") || text.contains("developer disk image could not be mounted") { return .deviceSupport }
        if text.contains("no accounts:") || text.contains("no accounts available") { return .account }
        // Login service transport failures do not prove that credentials are invalid.
        if CommandDiagnostics.isNetworkFailure(text) { return nil }
        if text.contains("authentication credentials are missing or invalid") || text.contains("session has expired") ||
            text.contains("incorrect password") ||
            text.contains("authentication failed") { return .account }
        return nil
    }
}

public struct SetupRequired: LocalizedError {
    public let issue: SetupIssue
    public var errorDescription: String? { issue.title + "。" + issue.guidance }
    public init(_ issue: SetupIssue) { self.issue = issue }
}

public struct ToolchainSelection: Codable, Equatable {
    public var fingerprint: String
    public var developerDirectory: String?
    public var version: String?
    public init(fingerprint: String, developerDirectory: String?, version: String? = nil) {
        self.fingerprint = fingerprint; self.developerDirectory = developerDirectory; self.version = version
    }
}

public struct ToolchainHealth: Codable, Equatable {
    public var selection: ToolchainSelection
    public var checkedAt: Date
    public var issue: SetupIssue?
    public var nextCheck: Date { checkedAt.addingTimeInterval(issue == nil ? Timing.retry : 5 * 60) }
}

public protocol ToolchainChecking {
    func selection() throws -> ToolchainSelection
    func configure(_ selection: ToolchainSelection)
    func inspect(_ selection: ToolchainSelection) throws -> SetupIssue?
}

public final class XcodeToolchain: ToolchainChecking {
    private let runner: CommandRunning
    private let configureEnvironment: (String?) -> Void
    private let applications: [URL]
    public init(runner: CommandRunning, applications: [URL]? = nil, configureEnvironment: @escaping (String?) -> Void) {
        self.runner = runner; self.configureEnvironment = configureEnvironment
        self.applications = applications ?? [URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }
    public func selection() throws -> ToolchainSelection {
        let selected = try runner.run("/usr/bin/xcode-select", ["-p"], timeout: 5)
        let active = selected.status == 0 ? selected.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var candidates = active.isEmpty ? [] : [URL(fileURLWithPath: active)]
        for directory in applications {
            candidates.append(directory.appendingPathComponent("Xcode.app/Contents/Developer"))
        }
        // Searching installed developer tools never scans the user's project directories.
        if !candidates.contains(where: Self.isFullXcode) {
            for directory in applications {
                for app in ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) where app.pathExtension == "app" {
                    candidates.append(app.appendingPathComponent("Contents/Developer"))
                }
            }
        }
        let developer = candidates.first(where: Self.isFullXcode)?.resolvingSymlinksInPath()
        let contents = developer?.deletingLastPathComponent()
        let info = contents.flatMap { Self.plist($0.appendingPathComponent("Info.plist")) } ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let files = [contents?.appendingPathComponent("Info.plist"), contents?.appendingPathComponent("version.plist"),
                     URL(fileURLWithPath: "/Library/Preferences/com.apple.dt.Xcode.plist")].compactMap { $0 }
        var identity = [active, developer?.path ?? "missing", ProcessInfo.processInfo.operatingSystemVersionString]
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            identity.append("\(file.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)")
        }
        let hash = SHA256.hash(data: Data(identity.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolchainSelection(fingerprint: hash, developerDirectory: developer?.path, version: version)
    }
    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
    private static func isFullXcode(_ developer: URL) -> Bool {
        let info = plist(developer.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        return info?["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode" &&
            FileManager.default.isExecutableFile(atPath: developer.appendingPathComponent("usr/bin/xcodebuild").path)
    }
    public func configure(_ selection: ToolchainSelection) { configureEnvironment(selection.developerDirectory) }
    public func inspect(_ selection: ToolchainSelection) throws -> SetupIssue? {
        guard selection.developerDirectory != nil else { return .xcodeMissing }
        let version = try runner.run("/usr/bin/xcodebuild", ["-version"], timeout: 15)
        guard version.status == 0 else { return SetupIssue.classify(version.text) ?? .toolsUnavailable }
        let setup = try runner.run("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"], timeout: 15)
        guard setup.status == 0 else { return SetupIssue.classify(setup.text) ?? .firstLaunch }
        let sdk = try runner.run("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"], timeout: 15)
        guard sdk.status == 0, !sdk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SetupIssue.classify(sdk.text) ?? .sdkMissing
        }
        let device = try runner.run("/usr/bin/xcrun", ["--find", "devicectl"], timeout: 15)
        return device.status == 0 ? nil : SetupIssue.classify(device.text) ?? .toolsUnavailable
    }
}

public final class ToolchainMonitor {
    private let store: StateStore
    private let checker: ToolchainChecking
    public init(store: StateStore, checker: ToolchainChecking) { self.store = store; self.checker = checker }
    /// Caller holds the worker lock. Readiness checks never build or contact a device.
    public func prepare(force: Bool = false, now: Date = Date()) throws -> Bool {
        let selection = try checker.selection()
        checker.configure(selection)
        let previous = try store.read().toolchain
        if !force, let previous, previous.selection == selection, now < previous.nextCheck {
            return previous.issue == nil
        }
        let issue: SetupIssue?
        do { issue = try checker.inspect(selection) }
        catch { issue = SetupIssue.classify(error.localizedDescription) ?? .toolsUnavailable }
        try store.update { state in
            state.toolchain = ToolchainHealth(selection: selection, checkedAt: now, issue: issue)
            if let issue {
                if state.notice?.issue != issue || (previous != nil && previous?.selection != selection) { state.notice = UserNotice(issue: issue) }
            } else {
                // Older releases stored raw Xcode failures. Normalize only known environment
                // failures; offline/build retries keep their original six-hour deadlines.
                for index in state.projects.indices {
                    let project = state.projects[index]
                    let cause = project.retryIssue ?? SetupIssue.classify(project.lastResult ?? "")
                    if project.nextRetry != nil, cause?.isToolchain == true {
                        state.projects[index].nextRetry = nil
                        state.projects[index].retryIssue = nil
                        state.projects[index].lastResult = "Xcode 环境已恢复，等待自动续签"
                    }
                }
                if state.notice?.issue.isToolchain == true { state.notice = nil }
            }
        }
        return issue == nil
    }
}
