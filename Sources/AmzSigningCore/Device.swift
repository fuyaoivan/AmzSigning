import Foundation

public struct Device: Codable, Equatable, Identifiable {
    public var id: String
    public var udid: String
    public var name: String
    public var transport: String
    public var paired: Bool
    public var developerMode: Bool?
    public var physical: Bool?
    public var transportTitle: String { transport == "wired" ? "USB" : transport == "localNetwork" || transport == "network" || transport == "wireless" ? "Wi-Fi" : transport }
    public init(id: String, udid: String, name: String, transport: String, paired: Bool = true, developerMode: Bool? = true, physical: Bool? = true) {
        self.id = id; self.udid = udid; self.name = name; self.transport = transport
        self.paired = paired; self.developerMode = developerMode; self.physical = physical
    }
}

public enum InstallationPolicy { case overwriteExisting, allowFirstInstall }

public struct InstalledApp: Equatable {
    public var bundleID: String
    public var version: String
    public var build: String
    public var url: String
    public func validateReplacement(version: String, build: String) throws {
        if !version.isEmpty, !self.version.isEmpty, version.compare(self.version, options: .numeric) == .orderedAscending {
            throw AmzError("源码版本低于 iPhone 上的版本，已停止覆盖，避免数据格式回退")
        }
        if version == self.version, !build.isEmpty, !self.build.isEmpty,
           build.compare(self.build, options: .numeric) == .orderedAscending {
            throw AmzError("源码构建号低于 iPhone 上的构建号，已停止覆盖")
        }
    }

}

public final class DeviceManager {
    let runner: CommandRunning
    let paths: Paths
    public init(runner: CommandRunning, paths: Paths) { self.runner = runner; self.paths = paths }
    public func command(_ args: [String], timeout: TimeInterval = 20) throws -> [String: Any] {
        let file = paths.temporary.appendingPathComponent("amzsigning-device-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try runner.checked("/usr/bin/xcrun", ["devicectl"] + args + ["--timeout", String(Int(timeout)), "--json-output", file.path], timeout: timeout + 3)
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              let info = json["info"] as? [String: Any], info["outcome"] as? String == "success",
              let result = json["result"] as? [String: Any] else { throw AmzError("设备命令没有返回成功结果") }
        return result
    }
    public static func parseDevices(_ result: [String: Any]) -> [Device] {
        (result["devices"] as? [[String: Any]] ?? []).compactMap { row in
            let modern = row["properties"] as? [String: Any] ?? [:]
            func properties(_ key: String, legacy: String) -> [String: Any] {
                (row[legacy] as? [String: Any] ?? [:]).merging(modern[key] as? [String: Any] ?? [:]) { _, current in current }
            }
            let hardware = properties("hardware", legacy: "hardwareProperties")
            let connection = properties("connection", legacy: "connectionProperties")
            let state = properties("state", legacy: "deviceProperties")
            let reality = hardware["reality"] as? String
            let transport = connection["transportType"] as? String ?? "未知连接"
            guard hardware["deviceType"] as? String == "iPhone", reality != "simulated", transport != "sameMachine",
                  let id = row["identifier"] as? String, let udid = hardware["udid"] as? String else { return nil }
            let mode: Bool?
            if let value = state["developerModeStatus"] as? String {
                mode = value == "enabled" ? true : value == "disabled" ? false : nil
            } else if let value = state["developerModeStatus"] as? [String: Any] {
                mode = value["enabled"] != nil ? true : value["disabled"] != nil ? false : nil
            } else { mode = nil }
            return Device(id: id, udid: udid, name: (state["name"] as? String ?? "iPhone").trimmingCharacters(in: .whitespaces),
                transport: transport, paired: connection["pairingState"] as? String == "paired", developerMode: mode,
                physical: reality == "physical" ? true : nil)
        }
    }
    /// Newer device lists are intentionally partial. Unknown values must be resolved
    /// from details before treating a device as physical and ready for installation.
    public func confirmed(_ candidate: Device) throws -> Device {
        var device = candidate
        if candidate.physical == nil || candidate.developerMode == nil {
            let details = try command(["device", "info", "details", "--device", candidate.id])
            guard let full = Self.parseDevices(["devices": [details]]).first,
                  full.id == candidate.id, full.udid == candidate.udid else {
                throw AmzError("设备详情与目标 iPhone 不一致，已停止安装")
            }
            device = full
        }
        guard device.physical == true else { throw AmzError("尚未确认目标为真实 iPhone，已停止安装") }
        guard device.paired else { throw SetupRequired(.deviceTrust) }
        guard let enabled = device.developerMode else { throw AmzError("尚未获取完整的 iPhone 开发状态，请检查设备连接") }
        guard enabled else { throw SetupRequired(.developerMode) }
        return device
    }
    public func list() throws -> [Device] { Self.parseDevices(try command(["list", "devices"])) }
    public func app(bundleID: String, device: Device) throws -> InstalledApp? {
        let result = try command(["device", "info", "apps", "--device", device.id, "--bundle-id", bundleID])
        return (result["apps"] as? [[String: Any]] ?? []).first(where: { $0["bundleIdentifier"] as? String == bundleID }).map {
            InstalledApp(bundleID: bundleID, version: $0["version"] as? String ?? "", build: $0["bundleVersion"] as? String ?? "", url: $0["url"] as? String ?? "")
        }
    }
    public func selected(udid: String) throws -> Device {
        let matches = try list().filter { $0.udid == udid }
        guard matches.count == 1, let candidate = matches.first else {
            throw AmzError("所选 iPhone 不在线，请连接并解锁；不会改用其他设备")
        }
        return try confirmed(candidate)
    }
    public func select(project: Project) throws -> (Device, InstalledApp) {
        let discovered = try list()
        let devices = discovered.filter { $0.paired }
        if let bound = project.boundDeviceID {
            guard let candidate = discovered.first(where: { $0.udid == bound }) else { throw AmzError("已绑定 iPhone 不在线；6 小时后重试") }
            let device = try confirmed(candidate)
            guard let app = try app(bundleID: project.bundleID, device: device) else { throw AmzError("iPhone 上不存在此 App；仅允许覆盖安装，已停止") }
            return (device, app)
        }
        if devices.isEmpty, !discovered.isEmpty { throw SetupRequired(.deviceTrust) }
        guard !devices.isEmpty else { throw AmzError("未发现已配对的 iPhone，请检查同一 Wi-Fi 或首次设备信任") }
        var matches: [(Device, InstalledApp)] = []
        var failures: [String] = []
        var setupIssue: SetupIssue?
        for device in devices {
            do {
                let device = try confirmed(device)
                if let app = try app(bundleID: project.bundleID, device: device) { matches.append((device, app)) }
            } catch {
                if let required = error as? SetupRequired { setupIssue = required.issue }
                failures.append("\(device.name)：\(error.localizedDescription)")
            }
        }
        if let setupIssue { throw SetupRequired(setupIssue) }
        guard failures.isEmpty else { throw AmzError(failures.joined(separator: "\n")) }
        guard matches.count == 1 else {
            throw AmzError(matches.isEmpty ? "已配对 iPhone 上未找到此 App；仅允许覆盖安装" : "多台 iPhone 装有此 App；首次续签时请只连接目标 iPhone")
        }
        return matches[0]
    }
    public func install(appURL: URL, bundleID: String, device: Device, policy: InstallationPolicy = .overwriteExisting, version: String = "", build: String = "") throws {
        guard device.physical == true, device.developerMode == true, device.paired else { throw AmzError("设备状态未验证，已停止安装") }
        // Recheck immediately before installation. There is deliberately no uninstall API.
        let existing = try app(bundleID: bundleID, device: device)
        guard policy == .allowFirstInstall || existing != nil else { throw AmzError("安装前检查发现原 App 不存在，已停止") }
        try existing?.validateReplacement(version: version, build: build)
        let result = try command(["device", "install", "app", "--device", device.id, appURL.path], timeout: 120)
        let apps = result["installedApplications"] as? [[String: Any]] ?? []
        guard apps.contains(where: { $0["bundleID"] as? String == bundleID || $0["bundleIdentifier"] as? String == bundleID }) else {
            throw AmzError("安装结果缺少目标 Bundle ID，未记为成功")
        }
        guard try app(bundleID: bundleID, device: device) != nil else { throw AmzError("安装后未能核实 App，未记为成功") }
    }
}
