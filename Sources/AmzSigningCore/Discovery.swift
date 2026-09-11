import Foundation

public protocol ProjectScanning {
    func scan(roots: [String]) -> ScanResult
}

/// A one-off discovery request, including membership at the time of the request.
public struct ScanRequest: Codable, Equatable {
    public let id: String
    public let roots: [String]
    public let knownProjects: [String: String]
}

extension State {
    public mutating func requestScan(roots: [String]) {
        let paths = Array(Set(roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })).sorted()
        guard !paths.isEmpty else { return }
        pendingScan = ScanRequest(id: UUID().uuidString, roots: paths,
            knownProjects: Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.managementID ?? $0.id) }))
    }
}

public final class ProjectDiscovery {
    private let store: StateStore
    private let scanner: ProjectScanning
    public init(store: StateStore, scanner: ProjectScanning) {
        self.store = store; self.scanner = scanner
    }
    /// The caller holds the worker lock. Discovery has no time-based trigger.
    @discardableResult public func runPending(now: Date = Date()) throws -> Bool {
        guard let request = try store.read().pendingScan else { return false }
        let result = scanner.scan(roots: request.roots)
        try store.update { latest in
            guard latest.pendingScan?.id == request.id else { return }
            let current = result.projects.filter { project in
                guard let generation = request.knownProjects[project.id] else { return true }
                return latest.projects.contains { $0.id == project.id && $0.managementID == generation }
            }
            XcodeScanner.merge(ScanResult(projects: current, issues: result.issues), into: &latest, now: now)
            latest.pendingScan = nil
        }
        return true
    }
}
