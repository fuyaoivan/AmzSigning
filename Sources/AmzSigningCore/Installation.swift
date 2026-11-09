import Foundation

/// A one-shot authorization snapshot. It is never persisted as an automatic retry.
public struct InstallationTarget: Codable, Equatable {
    public let id: String
    public let managementID: String?
    public let bundleID: String
    public let teamID: String
    public let previousDeviceID: String?
    public init(_ project: Project) {
        id = project.id; managementID = project.managementID
        bundleID = project.bundleID; teamID = project.teamID; previousDeviceID = project.boundDeviceID
    }
    public func matches(_ project: Project) -> Bool {
        project.id == id && project.managementID == managementID && project.bundleID == bundleID &&
            project.teamID == teamID && project.boundDeviceID == previousDeviceID
    }
    public func resolve(in state: State) throws -> Project {
        guard state.mode == .automatic, let project = state.projects.first(where: matches), project.enabled else {
            throw AmzError("项目或设备设置已改变，请重新选择安装项目")
        }
        try XcodeRenewer.validateIdentity(project)
        return project
    }
}

public struct InstallationRequest: Codable {
    public let deviceUDID: String
    public let targets: [InstallationTarget]
    public init(deviceUDID: String, projects: [Project]) {
        self.deviceUDID = deviceUDID; targets = projects.map(InstallationTarget.init)
    }
    public func validate(in state: State) throws {
        guard !deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !targets.isEmpty,
              Set(targets.map(\.id)).count == targets.count else { throw AmzError("请选择 iPhone 和安装项目") }
        for target in targets { _ = try target.resolve(in: state) }
    }
}

public protocol DeviceInstalling {
    func install(_ project: Project, on deviceUDID: String, store: StateStore) throws -> RenewalReceipt
}

public final class InstallationEngine {
    private let store: StateStore
    private let installer: DeviceInstalling
    public init(store: StateStore, installer: DeviceInstalling) { self.store = store; self.installer = installer }
    /// Caller owns the worker lock. Failure leaves the original binding and renewal
    /// deadlines intact. Only a verified receipt can switch the managed device.
    public func execute(_ request: InstallationRequest, logPath: String? = nil, now: () -> Date = Date.init) throws -> RunResult {
        try request.validate(in: store.read())
        var result = RunResult(trigger: "安装到 iPhone"); result.logPath = logPath
        defer { try? store.activity(nil) }
        for target in request.targets {
            var name = "项目"
            do {
                let project = try target.resolve(in: store.read()); name = project.name
                let attempt = now()
                let receipt = try installer.install(project, on: request.deviceUDID, store: store)
                guard receipt.device.udid == request.deviceUDID else { throw AmzError("安装回执的设备不匹配，未改变绑定") }
                try store.update { state in
                    guard let index = state.projects.firstIndex(where: target.matches), state.projects[index].enabled else {
                        throw AmzError("安装已完成，但项目设置已改变；未更新设备绑定")
                    }
                    state.projects[index].lastAttempt = attempt
                    state.projects[index].recordSuccess(expiration: receipt.expiration, profile: receipt.profileUUID, at: now(), device: receipt.device)
                    state.projects[index].lastResult = "已安装并绑定 · \(receipt.device.name) · \(receipt.device.transportTitle)"
                }
                result.successCount += 1
                result.messages.append("\(name)：已安装到 \(receipt.device.name)，后续在此设备续签，到期 \(dateText(receipt.expiration))")
            } catch {
                result.failureCount += 1
                result.messages.append("\(name)：\(error.localizedDescription)；原设备绑定未改变，请处理后重新发起安装")
            }
            result.finished = now()
            try store.recordRun(result)
        }
        return result
    }
}
