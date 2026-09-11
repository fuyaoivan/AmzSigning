import Foundation
import CryptoKit

public enum Timing {
    public static let renewal: TimeInterval = 6 * 24 * 60 * 60
    public static let retry: TimeInterval = 6 * 60 * 60
    public static let minimumValidity: TimeInterval = renewal + 60 * 60
}

public enum RunMode: String, Codable, CaseIterable {
    case automatic, away
    public var title: String { self == .automatic ? "自动模式" : "离开模式" }
}

public struct Project: Codable, Identifiable, Equatable {
    public var id: String
    public var managementID: String? = UUID().uuidString
    public var name: String
    public var container: String
    public var scheme: String
    public var target: String
    public var configuration: String = "Debug"
    public var bundleID: String
    public var teamID: String
    public var teamName: String = ""
    public var teamSource: String = "Xcode 工程"
    public var automatic: Bool
    public var personalTeam: Bool
    public var enabled: Bool = false
    public var issue: String?
    public var approvedBundleID: String?
    public var approvedTeamID: String?
    public var boundDeviceID: String?
    public var deviceName: String?
    public var lastTransport: String?
    public var localExpiration: Date?
    public var installedExpiration: Date?
    public var profileUUID: String?
    public var lastSuccess: Date?
    public var lastAttempt: Date?
    public var nextRetry: Date?
    public var lastResult: String?

    public init(container: String, scheme: String, target: String, bundleID: String,
                teamID: String, automatic: Bool, personalTeam: Bool) {
        self.container = container; self.scheme = scheme; self.target = target
        self.name = target; self.bundleID = bundleID; self.teamID = teamID
        self.automatic = automatic; self.personalTeam = personalTeam
        self.id = SHA256.hash(data: Data("\(container)\n\(scheme)\n\(target)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public var expiration: Date? { installedExpiration ?? localExpiration }
    public var expirationSource: String { installedExpiration == nil ? "本机描述文件，尚未验证安装" : "最近成功覆盖安装的签名" }
    public var nextDue: Date {
        if let retry = nextRetry { return retry }
        return lastSuccess?.addingTimeInterval(Timing.renewal) ?? .distantPast
    }
    public mutating func approve(_ value: Bool) {
        enabled = value
        if value {
            approvedBundleID = bundleID; approvedTeamID = teamID
            nextRetry = nil
            if issue?.hasPrefix("Bundle ID 或 Team 已改变") == true { issue = nil }
        }
    }
    public mutating func recordFailure(_ message: String, at date: Date) {
        lastResult = message; nextRetry = date.addingTimeInterval(Timing.retry)
    }
    public mutating func recordSuccess(expiration: Date, profile: String, at date: Date,
                                       device: Device) {
        lastSuccess = date; nextRetry = nil; installedExpiration = expiration
        localExpiration = expiration; profileUUID = profile
        boundDeviceID = device.udid; deviceName = device.name; lastTransport = device.transport
        lastResult = "已重新签名并覆盖安装 · \(device.name) · \(device.transportTitle)"
    }
}

public struct RunResult: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var started: Date = Date()
    public var finished: Date?
    public var trigger: String
    public var messages: [String] = []
    public var successCount: Int = 0
    public var failureCount: Int = 0
    public var logPath: String?
    public init(trigger: String) { self.trigger = trigger }
}

public struct State: Codable {
    public private(set) var version = 2
    public var projects: [Project] = []
    public var mode: RunMode = .automatic
    public var lastScan: Date?
    public var pendingScan: ScanRequest?
    public var scanIssues: [String] = []
    public var recentRuns: [RunResult] = []
    public var activity: String?
    public var activityPID: Int32?
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, projects, mode, lastScan, pendingScan, scanIssues, recentRuns, activity, activityPID
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard [1, 2].contains(storedVersion) else { throw AmzError("设置文件版本不兼容，已停止自动操作") }
        projects = try values.decode([Project].self, forKey: .projects)
        for index in projects.indices where projects[index].managementID == nil {
            guard storedVersion == 1 else { throw AmzError("项目管理标识缺失，已停止自动操作") }
            projects[index].managementID = projects[index].id
        }
        guard Set(projects.map(\.id)).count == projects.count,
              projects.allSatisfy({ !($0.managementID ?? "").isEmpty }) else {
            throw AmzError("项目管理记录无效，已停止自动操作")
        }
        let rawMode = try values.decode(String.self, forKey: .mode)
        if storedVersion == 1 {
            guard ["active", "paused", "until", "away"].contains(rawMode) else { throw AmzError("运行模式无效") }
            mode = rawMode == "active" ? .automatic : .away
        } else {
            guard let decoded = RunMode(rawValue: rawMode) else { throw AmzError("运行模式无效") }
            mode = decoded
            pendingScan = try values.decodeIfPresent(ScanRequest.self, forKey: .pendingScan)
        }
        lastScan = try values.decodeIfPresent(Date.self, forKey: .lastScan)
        scanIssues = try values.decodeIfPresent([String].self, forKey: .scanIssues) ?? []
        recentRuns = try values.decodeIfPresent([RunResult].self, forKey: .recentRuns) ?? []
        activity = try values.decodeIfPresent(String.self, forKey: .activity)
        activityPID = try values.decodeIfPresent(Int32.self, forKey: .activityPID)
    }
    public func manages(_ project: Project) -> Bool {
        projects.contains { $0.id == project.id && $0.managementID == project.managementID }
    }
    public func eligible(_ project: Project, at date: Date, force: Bool = false) -> Bool {
        mode == .automatic && project.enabled && manages(project) && (force || date >= project.nextDue)
    }
    public mutating func removeProject(_ project: Project) {
        projects.removeAll { $0.id == project.id && $0.managementID == project.managementID }
    }
}

public struct AmzError: LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public func dateText(_ date: Date?) -> String {
    guard let date else { return "尚未记录" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}
