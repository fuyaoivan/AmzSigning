import Foundation
import Darwin

public protocol Renewing {
    func renew(_ project: Project, store: StateStore) throws -> RenewalReceipt
}
public struct RenewalReceipt {
    public var expiration: Date
    public var profileUUID: String
    public var device: Device
    public init(expiration: Date, profileUUID: String, device: Device) {
        self.expiration = expiration; self.profileUUID = profileUUID; self.device = device
    }
}

public final class XcodeRenewer: Renewing {
    let runner: CommandRunning
    let profiles: ProfileManager
    let scanner: XcodeScanner
    let devices: DeviceManager
    let paths: Paths
    public init(runner: CommandRunning, paths: Paths) {
        self.runner = runner; self.paths = paths
        profiles = ProfileManager(runner: runner, paths: paths)
        scanner = XcodeScanner(runner: runner, profiles: profiles)
        devices = DeviceManager(runner: runner, paths: paths)
    }
    public static func validateIdentity(_ project: Project) throws {
        guard project.automatic, project.personalTeam, !project.teamID.isEmpty else {
            throw AmzError("仅支持项目现有的 Automatic Signing 和 Personal Team")
        }
        guard project.approvedBundleID == project.bundleID, project.approvedTeamID == project.teamID else {
            throw AmzError("Bundle ID 或签名 Team 与启用时不一致，已停止；关闭后重新开启可确认新配置")
        }
        if let issue = project.issue { throw AmzError(issue) }
    }
    private func checkEnabled(_ project: Project, store: StateStore) throws {
        let state = try store.read()
        guard let current = state.projects.first(where: { $0.id == project.id }),
              current.managementID == project.managementID, state.eligible(current, at: Date(), force: true), current.bundleID == project.bundleID,
              current.teamID == project.teamID else { throw AmzError("设置已改变或续签已暂停，已停止后续安装") }
    }
    public func renew(_ project: Project, store: StateStore) throws -> RenewalReceipt {
        guard FileManager.default.isReadableFile(atPath: project.container) else { throw AmzError("项目文件无法读取，请检查项目路径") }
        try Self.validateIdentity(project)
        try checkEnabled(project, store: store)
        try store.activity("\(project.name)：检查 iPhone 连接与已有 App")
        let (device, installed) = try devices.select(project: project)
        if project.boundDeviceID == nil { try devices.prepareWireless(device) }
        // Bind before building, so a failure never silently redirects a retry to another phone.
        try store.updateProject(project.id, managementID: project.managementID) { $0.boundDeviceID = device.udid; $0.deviceName = device.name }
        let directory = paths.builds.appendingPathComponent("renew-\(project.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let free = try FileManager.default.attributesOfFileSystem(forPath: paths.base.path)[.systemFreeSize] as? NSNumber
        guard (free?.int64Value ?? 0) > 2 * 1024 * 1024 * 1024 else { throw AmzError("可用磁盘空间不足 2 GB，已推迟构建") }
        try store.activity("\(project.name)：检查现有签名配置")
        let rows = try scanner.settings(container: project.container, scheme: project.scheme,
                                        configuration: project.configuration, derivedData: directory.path)
        guard let settings = rows.compactMap({ $0["buildSettings"] as? [String: Any] })
            .first(where: { $0["TARGET_NAME"] as? String == project.target && XcodeScanner.isIPhoneApp($0) }) else {
            throw AmzError("Scheme 中未找到原 iPhone App Target")
        }
        guard settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == project.bundleID,
              settings["CODE_SIGN_STYLE"] as? String == "Automatic" else { throw AmzError("实时构建设置已改变，已停止安装") }
        let configuredTeam = settings["DEVELOPMENT_TEAM"] as? String ?? ""
        guard configuredTeam.isEmpty || configuredTeam == project.teamID else { throw AmzError("项目实时 Team 已改变，已停止安装") }
        let version = settings["MARKETING_VERSION"] as? String ?? ""
        let build = settings["CURRENT_PROJECT_VERSION"] as? String ?? ""
        if !version.isEmpty, !installed.version.isEmpty, version.compare(installed.version, options: .numeric) == .orderedAscending {
            throw AmzError("源码版本低于 iPhone 上的版本，已停止覆盖，避免数据格式回退")
        }
        if version == installed.version, !build.isEmpty, !installed.build.isEmpty,
           build.compare(installed.build, options: .numeric) == .orderedAscending {
            throw AmzError("源码构建号低于 iPhone 上的构建号，已停止覆盖")
        }
        var ids = Set([project.bundleID])
        for b in rows.compactMap({ $0["buildSettings"] as? [String: Any] }) {
            if let product = b["PRODUCT_TYPE"] as? String, product.contains("extension"), let id = b["PRODUCT_BUNDLE_IDENTIFIER"] as? String {
                guard b["CODE_SIGN_STYLE"] as? String == "Automatic",
                      (b["DEVELOPMENT_TEAM"] as? String ?? project.teamID) == project.teamID else {
                    throw AmzError("App 扩展未使用同一 Team 的 Automatic Signing")
                }
                ids.insert(id)
            }
        }
        try checkEnabled(project, store: store)
        try store.activity("\(project.name)：后台重新签名")
        let backup = try profiles.quarantine(bundleIDs: ids, teamID: project.teamID)
        defer { if let backup { try? profiles.restore(backup) } }
        var args = XcodeScanner.arguments(container: project.container) + ["-scheme", project.scheme,
            "-configuration", project.configuration, "-sdk", "iphoneos", "-destination", "id=\(device.udid)",
            "-destination-timeout", "20", "-derivedDataPath", directory.path,
            "-allowProvisioningUpdates", "-disableAutomaticPackageResolution", "-skipPackageUpdates", "build"]
        // A project with an omitted team can reuse its exact existing profile team.
        if configuredTeam.isEmpty { args.append("DEVELOPMENT_TEAM=\(project.teamID)") }
        try runner.checked("/usr/bin/xcodebuild", args, timeout: 600)
        guard let outputDirectory = settings["TARGET_BUILD_DIR"] as? String, let product = settings["FULL_PRODUCT_NAME"] as? String else {
            throw AmzError("无法定位构建产物")
        }
        let appURL = URL(fileURLWithPath: outputDirectory).appendingPathComponent(product).resolvingSymlinksInPath()
        guard appURL.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"), appURL.pathExtension == "app" else {
            throw AmzError("构建产物不在本工具临时目录中，已停止安装")
        }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: appURL.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == project.bundleID else { throw AmzError("产物 Bundle ID 不匹配") }
        try runner.checked("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        let profile = try profiles.decode(appURL.appendingPathComponent("embedded.mobileprovision"))
        try profile.validate(project: project, device: device, now: Date())
        var expiration = profile.expiration
        // The earliest embedded extension profile bounds the whole installation's validity.
        if let enumerator = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "embedded.mobileprovision" && url.deletingLastPathComponent() != appURL {
                let child = try profiles.decode(url)
                var extensionProject = project; extensionProject.bundleID = child.bundleID
                guard ids.contains(child.bundleID) else { throw AmzError("存在未识别的嵌套 App 签名，已停止安装") }
                try child.validate(project: extensionProject, device: device, now: Date())
                expiration = min(expiration, child.expiration)
            }
        }
        try checkEnabled(project, store: store)
        try store.activity("\(project.name)：通过 \(device.transportTitle) 覆盖安装")
        try devices.install(appURL: appURL, bundleID: project.bundleID, device: device)
        return RenewalReceipt(expiration: expiration, profileUUID: profile.uuid, device: device)
    }
}

public final class RenewalEngine {
    public let store: StateStore
    public let renewer: Renewing
    public init(store: StateStore, renewer: Renewing) { self.store = store; self.renewer = renewer }
    /// The caller owns the worker lock. Every state write merges the latest UI settings.
    public func execute(force: Bool, projectID: String? = nil, logPath: String? = nil, now: () -> Date = Date.init) throws -> RunResult? {
        let state = try store.read()
        guard state.mode == .automatic else { return nil }
        let projects = state.projects.filter { (projectID == nil || $0.id == projectID) && state.eligible($0, at: now(), force: force) }
        guard !projects.isEmpty else { return nil }
        var result = RunResult(trigger: force ? "立即续签" : "自动续签")
        result.logPath = logPath
        defer { try? store.activity(nil) }
        for original in projects {
            let latest = try store.read()
            guard let project = latest.projects.first(where: { $0.id == original.id && $0.managementID == original.managementID }), latest.eligible(project, at: now(), force: force) else { continue }
            let attempt = now()
            // Persist a retry deadline BEFORE side effects, including crash/interruption cases.
            try store.updateProject(project.id, managementID: project.managementID) {
                $0.lastAttempt = attempt; $0.nextRetry = attempt.addingTimeInterval(Timing.retry)
                $0.lastResult = "本次执行未完成；若意外中断，将在 6 小时后重试"
            }
            do {
                let receipt = try renewer.renew(project, store: store)
                let completed = now()
                try store.updateProject(project.id, managementID: project.managementID) {
                    $0.recordSuccess(expiration: receipt.expiration, profile: receipt.profileUUID, at: completed, device: receipt.device)
                }
                result.successCount += 1; result.messages.append("\(project.name)：覆盖安装成功，到期 \(dateText(receipt.expiration))")
            } catch {
                let message = String(error.localizedDescription.prefix(5000))
                try store.updateProject(project.id, managementID: project.managementID) { $0.recordFailure(message, at: now()) }
                result.failureCount += 1; result.messages.append("\(project.name)：\(message)")
            }
            // Keep completed per-project results even if a later project crashes.
            result.finished = now()
            try store.update {
                $0.recentRuns.removeAll { $0.id == result.id }; $0.recentRuns.insert(result, at: 0)
                $0.recentRuns = Array($0.recentRuns.prefix(Maintenance.logCount))
            }
        }
        return result
    }
}
