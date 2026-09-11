import Foundation

public struct ScanResult {
    public var projects: [Project] = []
    public var issues: [String] = []
}

public final class XcodeScanner: ProjectScanning {
    let runner: CommandRunning
    let profiles: ProfileManager
    public init(runner: CommandRunning, profiles: ProfileManager) { self.runner = runner; self.profiles = profiles }
    public static let excluded: Set<String> = ["Library", "node_modules", "Pods", "Carthage", "DerivedData", "build", "Build", "dist", "vendor", ".build", ".git"]

    public static func containers(in roots: [String]) -> (urls: [URL], issues: [String]) {
        let manager = FileManager.default
        var containers = Set<URL>()
        var issues: [String] = []
        for root in roots {
            let url = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            guard manager.isReadableFile(atPath: root) else { issues.append("目录不可读取：\(root)"); continue }
            if ["xcodeproj", "xcworkspace"].contains(url.pathExtension) { containers.insert(url); continue }
            guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles], errorHandler: { path, error in
                    issues.append("无法扫描 \(path.path)：\(error.localizedDescription)"); return true
                }) else { continue }
            for case let entry as URL in enumerator {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true else { continue }
                let privateHomeFolder = url == manager.homeDirectoryForCurrentUser && entry.deletingLastPathComponent() == url &&
                    ["Applications", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"].contains(entry.lastPathComponent)
                if privateHomeFolder || values?.isSymbolicLink == true || excluded.contains(entry.lastPathComponent) || entry.pathExtension == "app" {
                    enumerator.skipDescendants(); continue
                }
                if ["xcodeproj", "xcworkspace"].contains(entry.pathExtension) {
                    containers.insert(entry.resolvingSymlinksInPath()); enumerator.skipDescendants()
                }
            }
        }
        return (containers.sorted { $0.path < $1.path }, issues)
    }

    public static func arguments(container: String) -> [String] {
        [container.hasSuffix(".xcworkspace") ? "-workspace" : "-project", container]
    }
    public func settings(container: String, scheme: String, configuration: String, derivedData: String? = nil) throws -> [[String: Any]] {
        let scratch = profiles.paths.builds.appendingPathComponent("scan-\(UUID().uuidString)")
        defer { if derivedData == nil { try? FileManager.default.removeItem(at: scratch) } }
        var args = Self.arguments(container: container) + ["-scheme", scheme, "-configuration", configuration,
            "-sdk", "iphoneos", "-destination", "generic/platform=iOS", "-showBuildSettings", "-json",
            "-disableAutomaticPackageResolution", "-skipPackageUpdates"]
        args += ["-derivedDataPath", derivedData ?? scratch.path]
        guard let rows = try runner.json("/usr/bin/xcodebuild", args, timeout: 90) as? [[String: Any]] else { throw AmzError("无法读取构建设置") }
        return rows
    }
    public func scan(roots: [String]) -> ScanResult {
        let found = Self.containers(in: roots)
        var result = ScanResult(issues: found.issues)
        let localProfiles = profiles.all()
        let teams = profiles.personalTeams()
        var seen = Set<String>()
        // Prefer a workspace's resolved app targets over its constituent project.
        let containers = found.urls.sorted { a, b in
            if a.pathExtension != b.pathExtension { return a.pathExtension == "xcworkspace" }
            return a.path < b.path
        }
        for container in containers {
            do {
                let list = try runner.json("/usr/bin/xcodebuild", Self.arguments(container: container.path) +
                    ["-list", "-json", "-disableAutomaticPackageResolution", "-skipPackageUpdates"], timeout: 60) as? [String: Any] ?? [:]
                let info = (list["project"] ?? list["workspace"]) as? [String: Any] ?? [:]
                let schemes = (info["schemes"] as? [String] ?? []).sorted()
                let configurations = info["configurations"] as? [String] ?? ["Debug"]
                if schemes.isEmpty { result.issues.append("未发现 Scheme：\(container.path)") }
                for scheme in schemes {
                    do {
                        let config = configurations.contains("Debug") ? "Debug" : configurations.first ?? "Debug"
                        let rows = try settings(container: container.path, scheme: scheme, configuration: config)
                        for row in rows {
                            guard let b = row["buildSettings"] as? [String: Any], Self.isIPhoneApp(b),
                                  let target = b["TARGET_NAME"] as? String,
                                  let bundleID = b["PRODUCT_BUNDLE_IDENTIFIER"] as? String, !bundleID.isEmpty else { continue }
                            let actualProject = b["PROJECT_FILE_PATH"] as? String ?? container.path
                            let key = "\(actualProject)\n\(target)\n\(bundleID)"
                            guard !seen.contains(key) else { continue }
                            let matching = localProfiles.filter { $0.bundleID == bundleID && $0.personal }
                            var teamID = b["DEVELOPMENT_TEAM"] as? String ?? ""
                            var source = "Xcode 工程"
                            if teamID.isEmpty, Set(matching.map(\.teamID)).count == 1 {
                                teamID = matching[0].teamID; source = "现有 Personal Team 描述文件"
                            }
                            let profile = matching.filter { $0.teamID == teamID }.max { $0.expiration < $1.expiration }
                            var p = Project(container: container.path, scheme: scheme, target: target, bundleID: bundleID, teamID: teamID,
                                            automatic: b["CODE_SIGN_STYLE"] as? String == "Automatic",
                                            personalTeam: teams[teamID] != nil || profile?.personal == true)
                            p.configuration = config; p.teamName = teams[teamID] ?? profile?.teamName ?? teamID
                            p.teamSource = source; p.localExpiration = profile?.expiration
                            if !p.automatic { p.issue = "项目未使用 Automatic Signing" }
                            else if !p.personalTeam || teamID.isEmpty { p.issue = "未识别到项目现有的 Personal Team" }
                            result.projects.append(p); seen.insert(key)
                        }
                    } catch { result.issues.append("\(container.lastPathComponent) / \(scheme)：\(error.localizedDescription)") }
                }
            } catch { result.issues.append("\(container.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }
    public static func isIPhoneApp(_ settings: [String: Any]) -> Bool {
        guard settings["PRODUCT_TYPE"] as? String == "com.apple.product-type.application" else { return false }
        let families = (settings["TARGETED_DEVICE_FAMILY"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return families.contains("1") && (settings["SDKROOT"] as? String ?? "").lowercased().contains("iphoneos")
    }
    public static func merge(_ scan: ScanResult, into state: inout State, now: Date) {
        for discovered in scan.projects {
            if let index = state.projects.firstIndex(where: { $0.id == discovered.id }) {
                var p = discovered
                let old = state.projects[index]
                p.managementID = old.managementID
                p.enabled = old.enabled; p.approvedBundleID = old.approvedBundleID; p.approvedTeamID = old.approvedTeamID
                p.boundDeviceID = old.boundDeviceID; p.deviceName = old.deviceName; p.lastTransport = old.lastTransport
                p.lastSuccess = old.lastSuccess; p.lastAttempt = old.lastAttempt; p.nextRetry = old.nextRetry
                p.installedExpiration = old.installedExpiration; p.profileUUID = old.profileUUID; p.lastResult = old.lastResult
                if old.approvedBundleID != nil && (old.approvedBundleID != p.bundleID || old.approvedTeamID != p.teamID) {
                    p.issue = "Bundle ID 或 Team 已改变；需关闭后重新开启此项目"
                }
                state.projects[index] = p
            } else {
                var p = discovered
                p.approve(false)
                state.projects.append(p)
            }
        }
        state.projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        state.lastScan = now
        state.scanIssues = scan.issues
    }
}
