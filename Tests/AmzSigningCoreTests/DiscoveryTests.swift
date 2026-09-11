import XCTest
@testable import AmzSigningCore

private final class StubScanner: ProjectScanning {
    var calls: [[String]] = []
    var operation: (([String]) -> ScanResult)?
    func scan(roots: [String]) -> ScanResult {
        calls.append(roots)
        return operation?(roots) ?? ScanResult()
    }
}

final class DiscoveryTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!
    private var scanner: StubScanner!
    private var discovery: ProjectDiscovery!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func project(_ name: String = "SampleApp") -> Project {
        Project(container: "/Projects/\(name).xcodeproj", scheme: name, target: name,
                bundleID: "org.example.\(name)", teamID: "EXAMPLE", automatic: true, personalTeam: true)
    }
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestData/\(UUID().uuidString)")
        store = try StateStore(paths: Paths(base: directory))
        scanner = StubScanner()
        discovery = ProjectDiscovery(store: store, scanner: scanner)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testElapsedTimeDoesNotDiscoverProjects() throws {
        try store.update { $0.projects = [project()]; $0.lastScan = now }
        let original = try Data(contentsOf: store.paths.state)
        for days in [1, 6, 30, 365] {
            XCTAssertFalse(try discovery.runPending(now: now.addingTimeInterval(Double(days) * 86400)))
        }
        XCTAssertTrue(scanner.calls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.paths.state), original)
    }
    func testExplicitRequestIsConsumedOnceAndCanBeRepeatedForSameDirectory() throws {
        try store.update { $0.requestScan(roots: ["/Projects", "/Projects/."]) }
        XCTAssertTrue(try discovery.runPending(now: now))
        XCTAssertEqual(scanner.calls, [["/Projects"]])
        XCTAssertEqual(try store.read().lastScan, now)
        XCTAssertNil(try store.read().pendingScan)
        XCTAssertFalse(try discovery.runPending(now: now.addingTimeInterval(86400)))
        try store.update { $0.requestScan(roots: ["/Projects"]) }
        XCTAssertTrue(try discovery.runPending(now: now))
        XCTAssertEqual(scanner.calls.count, 2)
    }
    func testNewRequestDuringScanDiscardsOldResultsAndRemainsQueued() throws {
        try store.update { $0.requestScan(roots: ["/Projects"]) }
        scanner.operation = { _ in
            try! self.store.update { $0.requestScan(roots: ["/Other"]); $0.mode = .away }
            return ScanResult(projects: [self.project()], issues: ["obsolete result"])
        }
        try discovery.runPending(now: now)
        let state = try store.read()
        XCTAssertEqual(state.pendingScan?.roots, ["/Other"])
        XCTAssertEqual(state.mode, .away)
        XCTAssertTrue(state.projects.isEmpty)
        XCTAssertTrue(state.scanIssues.isEmpty)
        XCTAssertNil(state.lastScan)
        scanner.operation = nil
        try discovery.runPending(now: now)
        XCTAssertEqual(scanner.calls.last, ["/Other"])
        XCTAssertNil(try store.read().pendingScan)
    }
    func testRequestSurvivesWorkerContention() throws {
        let lock = try FileLock(url: directory.appendingPathComponent("worker.lock"), nonblocking: true)
        try withExtendedLifetime(lock) {
            try store.update { $0.requestScan(roots: ["/Projects"]) }
            XCTAssertThrowsError(try FileLock(url: directory.appendingPathComponent("worker.lock"), nonblocking: true))
            XCTAssertNotNil(try store.read().pendingScan)
        }
        XCTAssertTrue(try discovery.runPending(now: now))
    }
    func testRemoveDuringScanStaysRemovedAndExplicitLaterScanCanReadd() throws {
        let p = project()
        try store.update { $0.projects = [p]; $0.requestScan(roots: ["/Projects"]) }
        scanner.operation = { _ in
            try! self.store.update { $0.removeProject(p) }
            return ScanResult(projects: [self.project()])
        }
        try discovery.runPending(now: now)
        XCTAssertTrue(try store.read().projects.isEmpty)
        scanner.operation = { _ in ScanResult(projects: [self.project()]) }
        try store.update { $0.requestScan(roots: ["/Projects"]) }
        try discovery.runPending(now: now)
        let restored = try store.read().projects[0]
        XCTAssertNotEqual(restored.managementID, p.managementID)
        XCTAssertFalse(restored.enabled)
    }
    func testScanningUnrelatedDirectoryPreservesExistingProjectAndSchedule() throws {
        var p = project(); p.approve(true); p.lastSuccess = now
        try store.update { $0.projects = [p]; $0.requestScan(roots: ["/Other"]) }
        scanner.operation = { _ in ScanResult(projects: [self.project("AnotherApp")]) }
        try discovery.runPending(now: now)
        let state = try store.read()
        XCTAssertEqual(state.projects.first { $0.id == p.id }, p)
        XCTAssertTrue(state.eligible(p, at: now.addingTimeInterval(Timing.renewal)))
        XCTAssertFalse(state.projects.first { $0.id != p.id }!.enabled)
    }
    func testLegacyStateMigrationPreservesProjectsAndDropsDiscoveryScope() throws {
        var p = project(); p.approve(true); p.lastSuccess = now
        var state = State(); state.projects = [p]
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder.amz.encode(state)) as! [String: Any]
        legacy["version"] = 1; legacy["mode"] = "active"
        legacy["roots"] = []; legacy["scanRequestID"] = "old-request"; legacy["nextScan"] = "2000-01-01T00:00:00Z"
        var rows = legacy["projects"] as! [[String: Any]]
        rows[0].removeValue(forKey: "managementID"); rows[0]["available"] = false
        legacy["projects"] = rows
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.paths.state)
        try store.bootstrap()
        let saved = try store.read()
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(saved.mode, .automatic)
        XCTAssertEqual(saved.projects[0].lastSuccess, now)
        XCTAssertTrue(saved.eligible(saved.projects[0], at: now.addingTimeInterval(Timing.renewal)))
        XCTAssertNil(saved.pendingScan)
        XCTAssertFalse(try discovery.runPending(now: now))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.state)) as! [String: Any]
        for key in ["roots", "scanRequestID", "pauseUntil", "defaultNamesUsed", "nextScan"] { XCTAssertNil(json[key]) }
    }
    func testLegacyPausedModesMigrateToAwayAndUnknownVersionFailsClosed() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.amz.encode(State())) as! [String: Any]
        json["version"] = 1
        for mode in ["paused", "until", "away"] {
            json["mode"] = mode
            try JSONSerialization.data(withJSONObject: json).write(to: store.paths.state)
            XCTAssertEqual(try store.read().mode, .away)
        }
        json["version"] = 99
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: store.paths.state)
        XCTAssertThrowsError(try store.update { $0.mode = .automatic })
        XCTAssertEqual(try Data(contentsOf: store.paths.state), data)
    }
    func testFreshConfigurationHasNoProjectsOrAutomaticScan() throws {
        try store.bootstrap()
        XCTAssertTrue(try store.read().projects.isEmpty)
        XCTAssertEqual(try store.read().mode, .automatic)
        XCTAssertNil(try store.read().pendingScan)
        XCTAssertFalse(try discovery.runPending(now: now))
    }
    func testAppAndHelperResolveDataToContainingProjectFolder() throws {
        for executable in ["Contents/MacOS/AmzSigning", "Contents/Helpers/AmzSigningAgent"] {
            XCTAssertEqual(try Paths.projectDirectory(executable: URL(fileURLWithPath: "/Projects/AmzSigning/AmzSigning.app/\(executable)")).path,
                           "/Projects/AmzSigning")
        }
        XCTAssertThrowsError(try Paths.projectDirectory(executable: URL(fileURLWithPath: "/unknown/AmzSigningAgent")))
    }
}
