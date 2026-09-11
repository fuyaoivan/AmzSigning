import Foundation

public enum Maintenance {
    public static let logCount = 20
    public static let logAge: TimeInterval = 14 * 24 * 60 * 60
    public static let logBudget: Int64 = 20 * 1024 * 1024
    public static let singleLogBudget = 2 * 1024 * 1024
    /// Call only while holding the worker lock; never touches shared Xcode caches.
    public static func clean(paths: Paths, now: Date = Date()) throws {
        let manager = FileManager.default
        for url in try manager.contentsOfDirectory(at: paths.builds, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: url)
        }
        let logs = try manager.contentsOfDirectory(at: paths.logs,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let a = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
        var kept = 0; var bytes: Int64 = 0
        for url in logs {
            let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(attributes.fileSize ?? 0)
            if kept >= logCount || bytes + size > logBudget || now.timeIntervalSince(attributes.contentModificationDate ?? .distantPast) > logAge {
                try manager.removeItem(at: url)
            } else { kept += 1; bytes += size }
        }
        // A forced quit may leave one capture file. Names are private to this tool.
        for url in (try? manager.contentsOfDirectory(at: paths.temporary, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            do {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(date) > 60 * 60 { try? manager.removeItem(at: url) }
            }
        }
    }
}
