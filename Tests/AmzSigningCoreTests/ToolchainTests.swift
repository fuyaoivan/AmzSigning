import XCTest
@testable import AmzSigningCore

private final class StubToolchain: ToolchainChecking {
    var current = ToolchainSelection(fingerprint: "version-one", developerDirectory: "/Applications/Xcode.app/Contents/Developer", version: "27.0")
    var issue: SetupIssue?
    var inspections = 0
    var configured: [ToolchainSelection] = []
    var failure: Error?
    func selection() throws -> ToolchainSelection { current }
    func configure(_ selection: ToolchainSelection) { configured.append(selection) }
    func inspect(_ selection: ToolchainSelection) throws -> SetupIssue? {
        inspections += 1
        if let failure { throw failure }
        return issue
    }
}

final class ToolchainTests: XCTestCase {
    private var root: URL!
    private var store: StateStore!
    private var checker: StubToolchain!
    private var monitor: ToolchainMonitor!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestData/\(UUID().uuidString)")
        store = try StateStore(paths: Paths(base: root.appendingPathComponent("Data")))
        checker = StubToolchain()
        monitor = ToolchainMonitor(store: store, checker: checker)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func project(_ name: String = "SampleApp") -> Project {
        var p = Project(container: "/Projects/\(name).xcodeproj", scheme: name, target: name,
                        bundleID: "org.example.\(name)", teamID: "EXAMPLE", automatic: true, personalTeam: true)
        p.approve(true); p.lastSuccess = now.addingTimeInterval(-Timing.renewal)
        return p
    }
    func testLicenseBlocksBeforeRenewalWithoutAdvancingProjectSchedule() throws {
        let p = project(); try store.update { $0.projects = [p] }
        checker.issue = .license
        XCTAssertFalse(try monitor.prepare(now: now))
        let state = try store.read()
        XCTAssertEqual(state.projects[0], p)
        XCTAssertEqual(state.toolchain?.issue, .license)
        XCTAssertEqual(state.notice?.issue, .license)
        XCTAssertTrue(state.recentRuns.isEmpty)
    }
    func testHealthyIdleChecksUseCacheAndDoNotRewriteState() throws {
        XCTAssertTrue(try monitor.prepare(now: now))
        let data = try Data(contentsOf: store.paths.state)
        XCTAssertTrue(try monitor.prepare(now: now.addingTimeInterval(60)))
        XCTAssertEqual(checker.inspections, 1)
        XCTAssertEqual(checker.configured.count, 2)
        XCTAssertEqual(try Data(contentsOf: store.paths.state), data)
    }
    func testXcodeOrOSFingerprintChangeChecksBeforeRenewalIsDue() throws {
        var p = project(); p.lastSuccess = now; try store.update { $0.projects = [p] }
        XCTAssertTrue(try monitor.prepare(now: now))
        checker.current.fingerprint = "updated-os-or-xcode"; checker.issue = .license
        XCTAssertFalse(try monitor.prepare(now: now.addingTimeInterval(60)))
        XCTAssertEqual(checker.inspections, 2)
        XCTAssertFalse(try store.read().eligible(p, at: now.addingTimeInterval(60)))
        XCTAssertEqual(try store.read().notice?.issue, .license)
    }
    func testBlockedEnvironmentRechecksAfterFiveMinutesWithoutDuplicateNotice() throws {
        checker.issue = .license
        XCTAssertFalse(try monitor.prepare(now: now))
        let notice = try store.read().notice
        XCTAssertFalse(try monitor.prepare(now: now.addingTimeInterval(299)))
        XCTAssertEqual(checker.inspections, 1)
        XCTAssertFalse(try monitor.prepare(now: now.addingTimeInterval(300)))
        XCTAssertEqual(checker.inspections, 2)
        XCTAssertEqual(try store.read().notice, notice)
    }
    func testLicenseAcceptanceFingerprintChangeRecoversBeforeNextCheck() throws {
        checker.issue = .license; _ = try monitor.prepare(now: now)
        checker.current.fingerprint = "license-accepted"; checker.issue = nil
        XCTAssertTrue(try monitor.prepare(now: now.addingTimeInterval(20)))
        XCTAssertNil(try store.read().toolchain?.issue)
        XCTAssertNil(try store.read().notice)
    }
    func testRecoveryClearsOnlyEnvironmentRetryDeadlines() throws {
        var environment = project(); environment.recordFailure("Xcode license pending", at: now, issue: .license)
        var offline = project("OfflineApp"); offline.recordFailure("device offline", at: now)
        try store.update { $0.projects = [environment, offline] }
        XCTAssertTrue(try monitor.prepare(now: now.addingTimeInterval(30)))
        let state = try store.read()
        XCTAssertNil(state.projects[0].nextRetry)
        XCTAssertEqual(state.projects[0].lastSuccess, environment.lastSuccess)
        XCTAssertTrue(state.eligible(state.projects[0], at: now.addingTimeInterval(30)))
        XCTAssertEqual(state.projects[1], offline)
        XCTAssertFalse(state.eligible(state.projects[1], at: now.addingTimeInterval(30)))
    }
    func testLegacyLicenseErrorRecoversWithoutWaitingForSixHourDeadline() throws {
        var p = project()
        p.recordFailure("xcrun failed (69): You have not agreed to the Xcode license agreements.", at: now)
        try store.update { $0.projects = [p] }
        XCTAssertTrue(try monitor.prepare(now: now))
        let fake = FakeRenewer()
        XCTAssertEqual(try RenewalEngine(store: store, renewer: fake).execute(force: false, now: { self.now })?.successCount, 1)
        XCTAssertEqual(try store.read().projects[0].nextDue, now.addingTimeInterval(Timing.renewal))
    }
    func testForcedCheckDoesNotWaitForCacheAndFailedInspectionIsNotReady() throws {
        XCTAssertTrue(try monitor.prepare(now: now))
        checker.failure = AmzError("temporary installation failure")
        XCTAssertFalse(try monitor.prepare(force: true, now: now.addingTimeInterval(1)))
        XCTAssertEqual(try store.read().toolchain?.issue, .toolsUnavailable)
    }
    func testAwayAndEmptyStateDoNotRequestAutomaticEnvironmentChecks() {
        var state = State(); XCTAssertFalse(state.needsToolchain)
        state.projects = [project()]; XCTAssertTrue(state.needsToolchain)
        state.mode = .away; XCTAssertFalse(state.needsToolchain)
        state.requestScan(roots: ["/Projects"]); XCTAssertTrue(state.needsToolchain)
    }
    func testActionFailuresAreTypedAndKeepSixHourRetry() throws {
        try store.update { $0.projects = [project()] }
        let fake = FakeRenewer(); fake.operation = { _, _ in throw SetupRequired(.account) }
        _ = try RenewalEngine(store: store, renewer: fake).execute(force: false, now: { self.now })
        let state = try store.read()
        XCTAssertEqual(state.projects[0].retryIssue, .account)
        XCTAssertEqual(state.projects[0].nextRetry, now.addingTimeInterval(Timing.retry))
        XCTAssertEqual(state.notice?.issue, .account)
    }
    func testCommandFailureRetainsActionableLicenseClassification() {
        let runner = FakeRunner(); runner.handler = { _, _ in
            CommandOutput(status: 69, data: Data("You have not agreed to the Xcode license agreements.".utf8))
        }
        XCTAssertThrowsError(try runner.checked("/usr/bin/xcrun", ["devicectl", "list", "devices"])) {
            XCTAssertEqual(($0 as? SetupRequired)?.issue, .license)
        }
    }
    func testReadinessProbeUsesOnlyReadOnlyCommandsAndStopsAtLicense() throws {
        let runner = FakeRunner(); runner.handler = { _, _ in
            CommandOutput(status: 69, data: Data("You have not agreed to the Xcode license agreements.".utf8))
        }
        let checker = XcodeToolchain(runner: runner, configureEnvironment: { _ in })
        XCTAssertEqual(try checker.inspect(self.checker.current), .license)
        XCTAssertEqual(runner.calls, [["/usr/bin/xcodebuild", "-version"]])
    }
    func testFirstLaunchAndMissingSDKAreDistinctBlockers() throws {
        let runner = FakeRunner()
        runner.handler = { _, arguments in
            CommandOutput(status: arguments == ["-checkFirstLaunchStatus"] ? 1 : 0, data: Data())
        }
        let checker = XcodeToolchain(runner: runner, configureEnvironment: { _ in })
        XCTAssertEqual(try checker.inspect(self.checker.current), .firstLaunch)
        runner.handler = { _, arguments in
            CommandOutput(status: arguments.contains("iphoneos") ? 1 : 0, data: Data())
        }
        XCTAssertEqual(try checker.inspect(self.checker.current), .sdkMissing)
        XCTAssertFalse(runner.calls.flatMap { $0 }.contains("-runFirstLaunch"))
        XCTAssertFalse(runner.calls.flatMap { $0 }.contains("-license"))
    }
    func testCommandLineToolsSelectionFallsBackToInstalledXcodeWithoutChangingSystemSelection() throws {
        let applications = root.appendingPathComponent("Applications")
        let contents = applications.appendingPathComponent("Xcode.app/Contents")
        let executable = contents.appendingPathComponent("Developer/usr/bin/xcodebuild")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": "27.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let runner = FakeRunner(); runner.handler = { _, _ in CommandOutput(status: 0, data: Data("/Library/Developer/CommandLineTools\n".utf8)) }
        var configured: String?
        let checker = XcodeToolchain(runner: runner, applications: [applications]) { configured = $0 }
        let selection = try checker.selection(); checker.configure(selection)
        XCTAssertEqual(selection.developerDirectory, contents.appendingPathComponent("Developer").path)
        XCTAssertEqual(configured, selection.developerDirectory)
        XCTAssertEqual(runner.calls, [["/usr/bin/xcode-select", "-p"]])
    }
    func testLockedPhoneIsNotMisdiagnosedAsMissingDeviceSupport() {
        let error = "The developer disk image could not be mounted on this device. The operation failed because the device was still locked."
        XCTAssertEqual(SetupIssue.classify(error), .deviceLocked)
    }
    func testSuccessfulRetryClearsActionNoticeForFutureIndependentFailures() throws {
        var p = project(); p.recordFailure("account expired", at: now, issue: .account)
        try store.update { $0.projects = [p]; $0.notice = UserNotice(issue: .account) }
        _ = try RenewalEngine(store: store, renewer: FakeRenewer()).execute(force: true, now: { self.now })
        XCTAssertNil(try store.read().notice)
        XCTAssertNil(try store.read().projects[0].retryIssue)
    }
    func testToolchainFieldsRemainOptionalInExistingV2State() throws {
        var state = State(); state.projects = [project()]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.amz.encode(state)) as! [String: Any]
        json.removeValue(forKey: "toolchain"); json.removeValue(forKey: "notice")
        let decoded = try JSONDecoder.amz.decode(State.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.version, 2)
        XCTAssertNil(decoded.toolchain)
        XCTAssertNil(decoded.notice)
        XCTAssertEqual(decoded.projects, state.projects)
    }
}
