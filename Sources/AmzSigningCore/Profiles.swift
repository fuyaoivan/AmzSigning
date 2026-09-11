import Foundation

public struct SigningProfile {
    public let url: URL
    public let uuid: String
    public let teamID: String
    public let teamName: String
    public let applicationIdentifier: String
    public let creation: Date
    public let expiration: Date
    public let personal: Bool
    public let devices: [String]
    public let development: Bool
    public var bundleID: String {
        applicationIdentifier.split(separator: ".", maxSplits: 1).dropFirst().joined(separator: ".")
    }
    public init(url: URL, dictionary: [String: Any]) throws {
        let entitlements = dictionary["Entitlements"] as? [String: Any] ?? [:]
        guard let uuid = dictionary["UUID"] as? String,
              let team = (dictionary["TeamIdentifier"] as? [String])?.first,
              let identifier = entitlements["application-identifier"] as? String,
              let expiration = dictionary["ExpirationDate"] as? Date,
              let creation = dictionary["CreationDate"] as? Date else { throw AmzError("描述文件缺少必要字段") }
        self.url = url; self.uuid = uuid; self.teamID = team
        self.teamName = dictionary["TeamName"] as? String ?? team
        self.applicationIdentifier = identifier; self.expiration = expiration; self.creation = creation
        self.personal = dictionary["LocalProvision"] as? Bool == true
        self.devices = dictionary["ProvisionedDevices"] as? [String] ?? []
        self.development = entitlements["get-task-allow"] as? Bool == true
    }
    public func matches(bundleID: String, team: String) -> Bool {
        self.bundleID == bundleID && teamID == team
    }
    public func validate(project: Project, device: Device, now: Date) throws {
        guard matches(bundleID: project.bundleID, team: project.teamID), personal, development else {
            throw AmzError("新签名的 Bundle ID、Personal Team 或开发签名不匹配，已停止安装")
        }
        guard devices.contains(device.udid) else { throw AmzError("新描述文件不包含目标 iPhone，已停止安装") }
        guard expiration.timeIntervalSince(now) > Timing.minimumValidity else {
            throw AmzError("Apple 未签发足够长的新签名（到期 \(dateText(expiration))），未安装；6 小时后重试")
        }
    }
}

public final class ProfileManager {
    let runner: CommandRunning
    let paths: Paths
    public let caches: [URL]
    public init(runner: CommandRunning, paths: Paths, caches: [URL]? = nil) {
        self.runner = runner; self.paths = paths
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.caches = caches ?? ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }
    public func decode(_ url: URL) throws -> SigningProfile {
        let output = try runner.checked("/usr/bin/security", ["cms", "-D", "-i", url.path], timeout: 10)
        guard let dictionary = try PropertyListSerialization.propertyList(from: output.data, format: nil) as? [String: Any] else {
            throw AmzError("无法读取描述文件")
        }
        return try SigningProfile(url: url, dictionary: dictionary)
    }
    public func all() -> [SigningProfile] {
        caches.flatMap { cache -> [SigningProfile] in
            ((try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "mobileprovision" }.compactMap { try? decode($0) }
        }
    }
    public func personalTeams() -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let id = dictionary["teamID"] as? String,
                   dictionary["isFreeProvisioningTeam"] as? Bool == true || dictionary["teamType"] as? String == "Personal Team" {
                    result[id] = dictionary["teamName"] as? String ?? "Personal Team"
                }
                dictionary.values.forEach(visit)
            } else if let array = value as? [Any] { array.forEach(visit) }
        }
        if let value = UserDefaults(suiteName: "com.apple.dt.Xcode")?.object(forKey: "IDEProvisioningTeamByIdentifier") { visit(value) }
        return result
    }

    private struct Backup: Codable { var original: String; var file: String }
    /// Only matching local Personal Team profiles are temporarily moved. Xcode
    /// remains responsible for issuing profiles and signing. No account revocation.
    public func quarantine(bundleIDs: Set<String>, teamID: String) throws -> URL? {
        let profiles = all().filter { $0.personal && $0.teamID == teamID && bundleIDs.contains($0.bundleID) }
        guard !profiles.isEmpty else { return nil }
        let directory = paths.backups.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entries = profiles.enumerated().map { Backup(original: $0.element.url.path, file: "\($0.offset).mobileprovision") }
        // Write the recovery journal before the first move; recoverable even after SIGKILL.
        try JSONEncoder.amz.encode(entries).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        do {
            for entry in entries { try FileManager.default.moveItem(atPath: entry.original, toPath: directory.appendingPathComponent(entry.file).path) }
        } catch { try? restore(directory); throw error }
        return directory
    }
    public func restore(_ directory: URL) throws {
        let manifest = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        let entries = try JSONDecoder.amz.decode([Backup].self, from: Data(contentsOf: manifest))
        for entry in entries {
            let original = URL(fileURLWithPath: entry.original)
            guard caches.contains(where: { $0.resolvingSymlinksInPath().path == original.deletingLastPathComponent().resolvingSymlinksInPath().path }),
                  original.pathExtension == "mobileprovision", !entry.file.contains("/") else {
                throw AmzError("描述文件恢复记录路径无效，已停止")
            }
            let backup = directory.appendingPathComponent(entry.file)
            if FileManager.default.fileExists(atPath: backup.path), !FileManager.default.fileExists(atPath: original.path) {
                try FileManager.default.moveItem(at: backup, to: original)
            }
        }
        try FileManager.default.removeItem(at: directory)
    }
    public func recover() throws {
        for directory in (try? FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)) ?? [] {
            try restore(directory)
        }
    }
}
