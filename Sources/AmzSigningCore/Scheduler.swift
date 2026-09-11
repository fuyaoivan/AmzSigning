import Foundation
import Darwin

public enum Scheduler {
    public static let label = "org.amzsigning.agent"
    public static var registrationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    public static func propertyList(worker: String) -> [String: Any] {
        ["Label": label, "ProgramArguments": [worker, "tick"], "RunAtLoad": true,
         // Calendar events coalesce across sleep and fire at wake. Idle ticks exit
         // after checking state and retention; discovery requires an explicit request.
         "StartCalendarInterval": (0..<60).map { ["Minute": $0] },
         "ProcessType": "Background", "LowPriorityIO": true, "Nice": 10,
         "KeepAlive": false, "ThrottleInterval": 30,
         "LimitLoadToSessionType": "Aqua", "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
    }
    public static func install(worker: String, paths: Paths, runner: CommandRunning? = nil) throws {
        guard FileManager.default.isExecutableFile(atPath: worker) else { throw AmzError("后台执行程序不存在") }
        let runner = runner ?? CommandRunner(paths: paths)
        let manager = FileManager.default
        try manager.createDirectory(at: registrationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList(worker: worker), format: .xml, options: 0)
        let domain = "gui/\(getuid())"
        let destination = try? manager.destinationOfSymbolicLink(atPath: registrationURL.path)
        if (try? Data(contentsOf: paths.scheduler)) != data || destination != paths.scheduler.path {
            _ = try? runner.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 10)
            try data.write(to: paths.scheduler, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.scheduler.path)
            if manager.fileExists(atPath: registrationURL.path) || destination != nil { try manager.removeItem(at: registrationURL) }
            try manager.createSymbolicLink(at: registrationURL, withDestinationURL: paths.scheduler)
        }
        let loaded = try runner.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 10)
        if loaded.status != 0 { try runner.checked("/bin/launchctl", ["bootstrap", domain, registrationURL.path], timeout: 15) }
    }
}
