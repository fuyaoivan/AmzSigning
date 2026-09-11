import XCTest
@testable import AmzSigningCore

final class FakeRenewer: Renewing {
    var calls: [String] = []
    var operation: ((Project, StateStore) throws -> RenewalReceipt)?
    func renew(_ project: Project, store: StateStore) throws -> RenewalReceipt {
        calls.append(project.id)
        return try operation?(project, store) ?? RenewalReceipt(expiration: Date().addingTimeInterval(604800), profileUUID: "new", device: testDevice)
    }
}
final class FakeRunner: CommandRunning {
    var calls: [[String]] = []
    var handler: ((String, [String]) throws -> CommandOutput)?
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        calls.append([executable] + arguments)
        return try handler?(executable, arguments) ?? CommandOutput(status: 0, data: Data())
    }
}
private let testDevice = Device(id: "core-id", udid: "phone-id", name: "Test iPhone", transport: "localNetwork")

final class CoreTests: XCTestCase {
    var temporary: URL!
    var paths: Paths!
    var store: StateStore!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws {
        temporary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/TestData").appendingPathComponent("AmzSigningTests-\(UUID().uuidString)")
        paths = Paths(base: temporary.appendingPathComponent("support"))
        store = try StateStore(paths: paths)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    func project(_ name: String = "SampleApp") -> Project {
        var p = Project(container: "/Projects/\(name).xcodeproj", scheme: name, target: name,
                        bundleID: "com.test.\(name)", teamID: "TEAM", automatic: true, personalTeam: true)
        p.approve(true); return p
    }
    func seed(_ projects: [Project]) throws { try store.update { $0.projects = projects } }

    func testSixDaysUsesLastSuccessAndNotProfileCreation() {
        var p = project(); p.lastSuccess = now
        p.localExpiration = now.addingTimeInterval(604800)
        var s = State(); s.projects = [p]
        XCTAssertFalse(s.eligible(p, at: now.addingTimeInterval(Timing.renewal - 1)))
        XCTAssertTrue(s.eligible(p, at: now.addingTimeInterval(Timing.renewal)))
        s.mode = .away
        XCTAssertFalse(s.eligible(p, at: now.addingTimeInterval(Timing.renewal)))
    }
    func testFailureWaitsSixHoursAndSuccessRestartsSixDays() throws {
        var p = project(); p.lastSuccess = now.addingTimeInterval(-Timing.renewal)
        try seed([p]); let renewer = FakeRenewer()
        renewer.operation = { _, _ in throw AmzError("offline") }
        let engine = RenewalEngine(store: store, renewer: renewer)
        let result = try engine.execute(force: false, now: { self.now })
        XCTAssertEqual(result?.failureCount, 1)
        XCTAssertEqual(try store.read().projects[0].lastSuccess, p.lastSuccess)
        XCTAssertNil(try engine.execute(force: false, now: { self.now.addingTimeInterval(Timing.retry - 1) }))
        renewer.operation = nil
        let done = now.addingTimeInterval(Timing.retry)
        XCTAssertEqual(try engine.execute(force: false, now: { done })?.successCount, 1)
        let fresh = try store.read().projects[0]
        XCTAssertNil(fresh.nextRetry)
        XCTAssertEqual(fresh.lastSuccess, done)
        XCTAssertEqual(fresh.nextDue, done.addingTimeInterval(Timing.renewal))
    }
    func testAwayBlocksManualAndAutomaticRenewalUntilAutomaticModeResumes() throws {
        try seed([project()]); let fake = FakeRenewer()
        let engine = RenewalEngine(store: store, renewer: fake)
        try store.update { $0.mode = .away }
        XCTAssertNil(try engine.execute(force: true, now: { self.now }))
        XCTAssertNil(try engine.execute(force: false, now: { self.now.addingTimeInterval(86400 * 30) }))
        XCTAssertTrue(fake.calls.isEmpty)
        try store.update { $0.mode = .automatic }
        XCTAssertEqual(try engine.execute(force: false, now: { self.now })?.successCount, 1)
    }
    func testPausedBetweenProjectsStopsRemainingWork() throws {
        try seed([project(), project("OtherApp")]); let fake = FakeRenewer()
        fake.operation = { _, store in
            try store.update { $0.mode = .away }
            return RenewalReceipt(expiration: self.now.addingTimeInterval(604800), profileUUID: "p", device: testDevice)
        }
        _ = try RenewalEngine(store: store, renewer: fake).execute(force: true, now: { self.now })
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(try store.read().mode, .away)
    }
    func testAttemptDeadlinePersistedBeforeSideEffects() throws {
        try seed([project()]); let fake = FakeRenewer()
        fake.operation = { p, store in
            let current = try store.read().projects[0]
            XCTAssertEqual(current.nextRetry, self.now.addingTimeInterval(Timing.retry))
            XCTAssertEqual(current.lastAttempt, self.now)
            throw AmzError("interrupted")
        }
        _ = try RenewalEngine(store: store, renewer: fake).execute(force: true, now: { self.now })
    }
    func testNewProjectsDefaultOffAndExplicitSwitchPersists() {
        var state = State()
        let scan = ScanResult(projects: [project(), project("OtherApp"), project("NewApp")])
        XcodeScanner.merge(scan, into: &state, now: now)
        XCTAssertTrue(state.projects.allSatisfy { !$0.enabled })
        let index = state.projects.firstIndex { $0.name == "SampleApp" }!
        state.projects[index].approve(true)
        XcodeScanner.merge(scan, into: &state, now: now)
        XCTAssertTrue(state.projects[index].enabled)
    }
    func testRenamedIdentityNeverSilentlyApproved() {
        var state = State()
        var p = project()
        XcodeScanner.merge(ScanResult(projects: [p]), into: &state, now: now)
        state.projects[0].approve(true)
        p.bundleID = "com.test.Different"
        XcodeScanner.merge(ScanResult(projects: [p]), into: &state, now: now)
        XCTAssertNotNil(state.projects[0].issue)
        XCTAssertThrowsError(try XcodeRenewer.validateIdentity(state.projects[0]))
    }
    func testManagedProjectsRenewWithoutPersistentScanDirectories() throws {
        try seed([project()]); let fake = FakeRenewer()
        XCTAssertNil(try store.read().pendingScan)
        XCTAssertEqual(try RenewalEngine(store: store, renewer: fake).execute(force: false)?.successCount, 1)
        XCTAssertEqual(fake.calls.count, 1)
    }
    func testRemovingProjectStopsFutureRenewal() throws {
        let p = project(); try seed([p])
        try store.update { $0.removeProject(p) }
        let fake = FakeRenewer()
        XCTAssertNil(try RenewalEngine(store: store, renewer: fake).execute(force: true))
        XCTAssertTrue(fake.calls.isEmpty)
    }
    func testRemovedAndReaddedProjectDoesNotReceiveOldRunResults() throws {
        let p = project(); try seed([p]); let fake = FakeRenewer()
        fake.operation = { old, store in
            try store.update {
                $0.removeProject(old)
                XcodeScanner.merge(ScanResult(projects: [self.project()]), into: &$0, now: self.now)
            }
            return RenewalReceipt(expiration: self.now.addingTimeInterval(604800), profileUUID: "old", device: testDevice)
        }
        _ = try RenewalEngine(store: store, renewer: fake).execute(force: true, now: { self.now })
        let replacement = try store.read().projects[0]
        XCTAssertNotEqual(replacement.managementID, p.managementID)
        XCTAssertNil(replacement.lastSuccess)
        XCTAssertNil(replacement.boundDeviceID)
        XCTAssertFalse(replacement.enabled)
    }
    func testDisabledProjectCannotBeManuallyRenewed() throws {
        var p = project(); p.approve(false); try seed([p])
        let fake = FakeRenewer()
        XCTAssertNil(try RenewalEngine(store: store, renewer: fake).execute(force: true, projectID: p.id))
    }
    func testAutomaticPersonalTeamAndIdentityGuards() {
        var p = project(); XCTAssertNoThrow(try XcodeRenewer.validateIdentity(p))
        p.automatic = false; XCTAssertThrowsError(try XcodeRenewer.validateIdentity(p))
        p.automatic = true; p.personalTeam = false; XCTAssertThrowsError(try XcodeRenewer.validateIdentity(p))
        p.personalTeam = true; p.teamID = "OTHER"; XCTAssertThrowsError(try XcodeRenewer.validateIdentity(p))
    }
    func profileDictionary(expiration: Date? = nil) -> [String: Any] {
        ["UUID": "profile", "TeamIdentifier": ["TEAM"], "TeamName": "Personal", "CreationDate": now,
         "ExpirationDate": expiration ?? now.addingTimeInterval(604800), "LocalProvision": true,
         "ProvisionedDevices": [testDevice.udid], "Entitlements": ["application-identifier": "TEAM.com.test.SampleApp", "get-task-allow": true]]
    }
    func testProfileMustActuallyRenewAndContainSameTeamBundleAndDevice() throws {
        let url = temporary.appendingPathComponent("fixture.mobileprovision")
        let fresh = try SigningProfile(url: url, dictionary: profileDictionary())
        XCTAssertNoThrow(try fresh.validate(project: project(), device: testDevice, now: now))
        let stale = try SigningProfile(url: url, dictionary: profileDictionary(expiration: now.addingTimeInterval(86400)))
        XCTAssertThrowsError(try stale.validate(project: project(), device: testDevice, now: now))
        var wrong = testDevice; wrong.udid = "wrong"
        XCTAssertThrowsError(try fresh.validate(project: project(), device: wrong, now: now))
        var wrongProject = project(); wrongProject.bundleID = "com.other"
        XCTAssertThrowsError(try fresh.validate(project: wrongProject, device: testDevice, now: now))
    }
    func testCorruptedStateFailsClosedWithoutOverwriting() throws {
        let bad = Data("not json".utf8); try bad.write(to: paths.state)
        XCTAssertThrowsError(try store.read())
        XCTAssertThrowsError(try store.update { $0.mode = .automatic })
        XCTAssertEqual(try Data(contentsOf: paths.state), bad)
    }
    func testConcurrentSettingsAndResultsDoNotLoseWrites() throws {
        try seed([project()])
        let id = project().id
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            if i % 2 == 0 { try! store.update { $0.scanIssues.append("\(i)") } }
            else { try! store.updateProject(id) { $0.lastResult = "result" } }
        }
        XCTAssertEqual(try store.read().scanIssues.count, 20)
        XCTAssertEqual(try store.read().projects[0].lastResult, "result")
    }
    func testWorkerLockExcludesConcurrentRuns() throws {
        let url = paths.base.appendingPathComponent("test.lock")
        let lock = try FileLock(url: url, nonblocking: true)
        try withExtendedLifetime(lock) { XCTAssertThrowsError(try FileLock(url: url, nonblocking: true)) }
    }
    func testProfileBackupRecoveryIsScopedAndCrashSafe() throws {
        let cache = temporary.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let matching = cache.appendingPathComponent("matching.mobileprovision")
        let other = cache.appendingPathComponent("unrelated.mobileprovision")
        try Data("matching-original".utf8).write(to: matching); try Data("unrelated".utf8).write(to: other)
        let runner = FakeRunner()
        runner.handler = { _, args in
            var dictionary = self.profileDictionary()
            if args.last?.hasSuffix("unrelated.mobileprovision") == true { dictionary["TeamIdentifier"] = ["OTHER"] }
            return CommandOutput(status: 0, data: try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
        }
        let manager = ProfileManager(runner: runner, paths: paths, caches: [cache])
        XCTAssertNotNil(try manager.quarantine(bundleIDs: ["com.test.SampleApp"], teamID: "TEAM"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: matching.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        try manager.recover()
        XCTAssertEqual(try String(contentsOf: matching), "matching-original")
        XCTAssertEqual(try String(contentsOf: other), "unrelated")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.backups.path).isEmpty)
    }
    func testCleanupRemovesBuildsAndLimitsLogCountAgeAndBytes() throws {
        let unrelated = temporary.appendingPathComponent("user-file")
        try Data("retain".utf8).write(to: unrelated)
        try Data("build".utf8).write(to: paths.builds.appendingPathComponent("stale"))
        for index in 0..<25 {
            let file = paths.logs.appendingPathComponent("\(index).log")
            try Data(repeating: 65, count: 1_100_000).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(-index))], ofItemAtPath: file.path)
        }
        let old = paths.logs.appendingPathComponent("old.log")
        try Data("old".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Maintenance.logAge - 1)], ofItemAtPath: old.path)
        try Maintenance.clean(paths: paths, now: now)
        let files = try FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.count, Maintenance.logCount)
        XCTAssertLessThanOrEqual(try files.reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize!) }, Maintenance.logBudget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.builds.path).isEmpty)
        XCTAssertEqual(try String(contentsOf: unrelated), "retain")
    }
    func testLogFileCannotGrowWithoutBound() throws {
        let file = paths.logs.appendingPathComponent("large.log")
        let runner = CommandRunner(paths: paths, logURL: file)
        runner.appendLog(String(repeating: "a", count: Maintenance.singleLogBudget + 10000))
        XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!, Maintenance.singleLogBudget)
    }
    func testLaunchdRunsAtLoginAndCatchesSleepWithoutKeepAlive() {
        let plist = Scheduler.propertyList(worker: "/Applications/AmzSigning.app/Contents/Helpers/AmzSigningAgent")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
        XCTAssertEqual((plist["StartCalendarInterval"] as? [[String: Int]])?.count, 60)
        XCTAssertNil(plist["StartInterval"])
    }
    func testScannerSkipsBuildCachesSymlinksAndDeduplicatesRoots() throws {
        let root = temporary.appendingPathComponent("Projects")
        for name in ["App/App.xcodeproj", "Other/Other.xcworkspace", "node_modules/Bad.xcodeproj", "Library/Bad.xcodeproj", ".build/Bad.xcodeproj"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let result = XcodeScanner.containers(in: [root.path, root.appendingPathComponent("App").path])
        XCTAssertEqual(result.urls.count, 2)
        XCTAssertTrue(result.issues.isEmpty)
    }
    func testOnlyNativeIPhoneApplicationsAreIncluded() {
        let b: [String: Any] = ["PRODUCT_TYPE": "com.apple.product-type.application", "SDKROOT": "/SDK/iPhoneOS.sdk", "TARGETED_DEVICE_FAMILY": "1,2"]
        XCTAssertTrue(XcodeScanner.isIPhoneApp(b))
        var other = b; other["TARGETED_DEVICE_FAMILY"] = "2"; XCTAssertFalse(XcodeScanner.isIPhoneApp(other))
        other = b; other["PRODUCT_TYPE"] = "com.apple.product-type.app-extension"; XCTAssertFalse(XcodeScanner.isIPhoneApp(other))
    }
    func testDeviceParsesWirelessAndRejectsSimulator() {
        let device: [String: Any] = ["identifier": "core-id", "hardwareProperties": ["udid": "phone-id", "deviceType": "iPhone", "reality": "physical"],
            "connectionProperties": ["transportType": "localNetwork", "pairingState": "paired"],
            "deviceProperties": ["name": "Test iPhone", "developerModeStatus": "enabled"]]
        XCTAssertEqual(DeviceManager.parseDevices(["devices": [device]]), [testDevice])
        var sim = device; sim["hardwareProperties"] = ["udid": "sim", "deviceType": "iPhone", "reality": "simulated"]
        XCTAssertTrue(DeviceManager.parseDevices(["devices": [sim]]).isEmpty)
    }
    func testNoInstallWhenAppIsAbsent() throws {
        let runner = FakeRunner()
        runner.handler = { _, args in
            let index = args.firstIndex(of: "--json-output")!
            let json: [String: Any] = ["info": ["outcome": "success"], "result": ["apps": []]]
            try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: args[index + 1]))
            return CommandOutput(status: 0, data: Data())
        }
        XCTAssertThrowsError(try DeviceManager(runner: runner, paths: paths).install(appURL: temporary.appendingPathComponent("test.app"), bundleID: "test", device: testDevice))
        XCTAssertFalse(runner.calls.contains { $0.contains("install") })
        XCTAssertFalse(runner.calls.contains { $0.contains("uninstall") })
    }
    func testWirelessSetupOnlyAppliesToAlreadyPairedUSBDevice() throws {
        let runner = FakeRunner(); let manager = DeviceManager(runner: runner, paths: paths)
        try manager.prepareWireless(testDevice)
        var device = testDevice; device.transport = "wired"; device.paired = false
        try manager.prepareWireless(device)
        XCTAssertTrue(runner.calls.isEmpty)
        device.paired = true; try manager.prepareWireless(device)
        XCTAssertEqual(runner.calls, [["/usr/bin/xcrun", "xcdevice", "enable", "--timeout=15", device.udid]])
    }
    func testExplicitReenableAcceptsIdentityChangeWithoutClearingOtherGuards() {
        var p = project(); p.bundleID = "com.test.NewID"
        p.issue = "Bundle ID 或 Team 已改变；需关闭后重新开启此项目"
        p.approve(false); p.approve(true)
        XCTAssertNoThrow(try XcodeRenewer.validateIdentity(p))
        p.automatic = false
        XCTAssertThrowsError(try XcodeRenewer.validateIdentity(p))
    }
    func testSubprocessTimeoutKillsItsChildrenAndReturnsPromptly() throws {
        let marker = temporary.appendingPathComponent("must-not-exist")
        let start = Date()
        XCTAssertThrowsError(try CommandRunner(paths: paths).run("/bin/sh", ["-c", "(sleep 2; touch '" + marker.path + "') & wait"], timeout: 0.15))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
