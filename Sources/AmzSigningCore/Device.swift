import Foundation

public struct Device: Equatable {
    public var id: String
    public var udid: String
    public var name: String
    public var transport: String
    public var paired: Bool
    public var developerMode: Bool
    public var transportTitle: String { transport == "wired" ? "USB" : transport == "localNetwork" || transport == "network" || transport == "wireless" ? "Wi-Fi" : transport }
    public init(id: String, udid: String, name: String, transport: String, paired: Bool = true, developerMode: Bool = true) {
        self.id = id; self.udid = udid; self.name = name; self.transport = transport
        self.paired = paired; self.developerMode = developerMode
    }
}

public struct InstalledApp: Equatable {
    public var bundleID: String
    public var version: String
    public var build: String
    public var url: String
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
            let hardware = row["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = row["connectionProperties"] as? [String: Any] ?? [:]
            let properties = row["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["deviceType"] as? String == "iPhone", hardware["reality"] as? String == "physical",
                  let id = row["identifier"] as? String, let udid = hardware["udid"] as? String else { return nil }
            return Device(id: id, udid: udid, name: (properties["name"] as? String ?? "iPhone").trimmingCharacters(in: .whitespaces),
                transport: connection["transportType"] as? String ?? "未知连接",
                paired: connection["pairingState"] as? String == "paired",
                developerMode: properties["developerModeStatus"] as? String == "enabled")
        }
    }
    public func list() throws -> [Device] { Self.parseDevices(try command(["list", "devices"])) }
    public func prepareWireless(_ device: Device) throws {
        guard device.paired, device.transport == "wired" else { return }
        // Apple-supported setup for an already trusted device and this Mac only.
        try runner.checked("/usr/bin/xcrun", ["xcdevice", "enable", "--timeout=15", device.udid], timeout: 18)
    }
    public func app(bundleID: String, device: Device) throws -> InstalledApp? {
        let result = try command(["device", "info", "apps", "--device", device.id, "--bundle-id", bundleID])
        return (result["apps"] as? [[String: Any]] ?? []).first(where: { $0["bundleIdentifier"] as? String == bundleID }).map {
            InstalledApp(bundleID: bundleID, version: $0["version"] as? String ?? "", build: $0["bundleVersion"] as? String ?? "", url: $0["url"] as? String ?? "")
        }
    }
    public func select(project: Project) throws -> (Device, InstalledApp) {
        let devices = try list().filter { $0.paired }
        if let bound = project.boundDeviceID {
            guard let device = devices.first(where: { $0.udid == bound }) else { throw AmzError("已绑定 iPhone 不在线；6 小时后重试") }
            guard device.developerMode else { throw AmzError("iPhone 开发者模式不可用") }
            guard let app = try app(bundleID: project.bundleID, device: device) else { throw AmzError("iPhone 上不存在此 App；仅允许覆盖安装，已停止") }
            return (device, app)
        }
        guard !devices.isEmpty else { throw AmzError("未发现已配对的 iPhone，请检查同一 Wi-Fi 或首次设备信任") }
        var matches: [(Device, InstalledApp)] = []
        var failures: [String] = []
        for device in devices {
            do {
                guard device.developerMode else { failures.append("\(device.name)：开发者模式不可用"); continue }
                if let app = try app(bundleID: project.bundleID, device: device) { matches.append((device, app)) }
            } catch { failures.append("\(device.name)：\(error.localizedDescription)") }
        }
        guard failures.isEmpty else { throw AmzError(failures.joined(separator: "\n")) }
        guard matches.count == 1 else {
            throw AmzError(matches.isEmpty ? "已配对 iPhone 上未找到此 App；仅允许覆盖安装" : "多台 iPhone 装有此 App；首次续签时请只连接目标 iPhone")
        }
        return matches[0]
    }
    public func install(appURL: URL, bundleID: String, device: Device) throws {
        // Recheck immediately before installation. There is deliberately no uninstall API.
        guard try app(bundleID: bundleID, device: device) != nil else { throw AmzError("安装前检查发现原 App 不存在，已停止") }
        let result = try command(["device", "install", "app", "--device", device.id, appURL.path], timeout: 120)
        let apps = result["installedApplications"] as? [[String: Any]] ?? []
        guard apps.contains(where: { $0["bundleID"] as? String == bundleID || $0["bundleIdentifier"] as? String == bundleID }) else {
            throw AmzError("安装结果缺少目标 Bundle ID，未记为成功")
        }
        guard try app(bundleID: bundleID, device: device) != nil else { throw AmzError("安装后未能核实 App，未记为成功") }
    }
}
