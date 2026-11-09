import XCTest
@testable import AmzSigningCore

private final class FakeInstaller: DeviceInstalling {
    var calls: [String] = []
    var action: ((Project, String, StateStore) throws -> RenewalReceipt)?
    func install(_ project: Project, on udid: String, store: StateStore) throws -> RenewalReceipt {
        calls.append(project.id)
        return try action?(project, udid, store) ?? RenewalReceipt(expiration: Date().addingTimeInterval(604800), profileUUID: "new-profile",
            device: Device(id: "new-core", udid: udid, name: "New iPhone", transport: "wired"))
    }
}

final class InstallationTests: XCTestCase {
    private var root: URL!
    private var store: StateStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/TestData/\(UUID().uuidString)")
        store = try StateStore(paths: Paths(base: root))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func project(_ name: String = "Sample") -> Project {
        var p = Project(container: root.appendingPathComponent("\(name).xcodeproj").path, scheme: name, target: name,
                        bundleID: "org.example.\(name)", teamID: "EXAMPLE", automatic: true, personalTeam: true)
        p.approve(true); p.boundDeviceID = "old-phone"; p.deviceName = "Old iPhone"
        p.lastSuccess = now; p.installedExpiration = now.addingTimeInterval(604800)
        return p
    }
    func testSuccessChangesBindingAndStartsSixDayCycle() throws {
        let p = project(); try store.update { $0.projects = [p] }
        let installer = FakeInstaller()
        installer.action = { project, udid, store in
            XCTAssertEqual(try store.read().projects[0], p)
            return RenewalReceipt(expiration: self.now.addingTimeInterval(604800), profileUUID: "fresh",
                device: Device(id: "new-core", udid: udid, name: "New iPhone", transport: "wired"))
        }
        let result = try InstallationEngine(store: store, installer: installer).execute(InstallationRequest(deviceUDID: "new-phone", projects: [p]), now: { self.now })
        let updated = try store.read().projects[0]
        XCTAssertEqual(result.successCount, 1); XCTAssertEqual(updated.boundDeviceID, "new-phone")
        XCTAssertEqual(updated.nextDue, now.addingTimeInterval(Timing.renewal)); XCTAssertNil(updated.nextRetry)
    }
    func testFailurePreservesOldPhoneAndScheduleWithoutAutomaticFirstInstallRetry() throws {
        var p = project(); p.recordFailure("offline", at: now)
        try store.update { $0.projects = [p] }
        let installer = FakeInstaller(); installer.action = { _, _, _ in throw AmzError("build failed") }
        let result = try InstallationEngine(store: store, installer: installer).execute(InstallationRequest(deviceUDID: "new-phone", projects: [p]))
        XCTAssertEqual(result.failureCount, 1); XCTAssertEqual(try store.read().projects[0], p)
        XCTAssertNil(try store.read().activity)
    }
    func testManualNetworkFailureDoesNotPromiseAutomaticInstallationRetry() throws {
        let p = project(); try store.update { $0.projects = [p] }
        let installer = FakeInstaller()
        installer.action = { _, _, _ in throw AmzError(CommandDiagnostics.retryMessage("NSURLErrorDomain Code=-1004")!) }
        let result = try InstallationEngine(store: store, installer: installer).execute(InstallationRequest(deviceUDID: "new-phone", projects: [p]))
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertFalse(result.messages.joined().contains("自动重试"))
        XCTAssertTrue(result.messages.joined().contains("重新发起安装"))
        XCTAssertEqual(try store.read().projects[0], p)
    }
    func testPartialBatchOnlyRebindsSuccessfulProjects() throws {
        let a = project("First"), b = project("Second"); try store.update { $0.projects = [a, b] }
        let installer = FakeInstaller(); installer.action = { p, udid, _ in
            if p.id == b.id { throw AmzError("offline") }
            return RenewalReceipt(expiration: self.now.addingTimeInterval(604800), profileUUID: "fresh", device: Device(id: "new-core", udid: udid, name: "New", transport: "wired"))
        }
        let result = try InstallationEngine(store: store, installer: installer).execute(InstallationRequest(deviceUDID: "new-phone", projects: [a,b]))
        XCTAssertEqual(result.successCount, 1); XCTAssertEqual(result.failureCount, 1)
        XCTAssertEqual(try store.read().projects[0].boundDeviceID, "new-phone"); XCTAssertEqual(try store.read().projects[1], b)
    }
    func testAwayDisabledRemovedOrReboundProjectsRejectStaleRequests() throws {
        let p = project()
        let actual = InstallationRequest(deviceUDID: "new-phone", projects: [p])
        let installer = FakeInstaller(); let engine = InstallationEngine(store: store, installer: installer)
        for change in 0..<5 {
            try store.update { state in
                state.mode = .automatic; state.projects = [p]
                switch change {
                case 0: state.mode = .away
                case 1: state.projects[0].approve(false)
                case 2: state.projects = []
                case 3: state.projects[0].managementID = "re-added"
                default: state.projects[0].boundDeviceID = "other-phone"
                }
            }
            XCTAssertThrowsError(try engine.execute(actual))
        }
        XCTAssertTrue(installer.calls.isEmpty)
    }
    func testDuplicateOrEmptyRequestsFailBeforeInstallation() throws {
        let p = project();try store.update { $0.projects = [p] }
        for request in [InstallationRequest(deviceUDID: "", projects: [p]), InstallationRequest(deviceUDID: "new", projects: []), InstallationRequest(deviceUDID: "new", projects: [p,p])] {
            XCTAssertThrowsError(try request.validate(in: store.read()))
        }
    }
    func testChangedProjectDuringInstallDoesNotWriteIntoReplacementRecord() throws {
        let p = project();try store.update { $0.projects = [p] }
        let installer = FakeInstaller();installer.action = { _, udid, store in
            try store.update { $0.projects[0].managementID = "replacement" }
            return RenewalReceipt(expiration: self.now.addingTimeInterval(604800), profileUUID: "fresh", device: Device(id: "new", udid: udid, name: "New", transport: "wired"))
        }
        let result = try InstallationEngine(store: store, installer: installer).execute(InstallationRequest(deviceUDID: "new-phone", projects: [p]))
        XCTAssertEqual(result.failureCount, 1);XCTAssertEqual(try store.read().projects[0].boundDeviceID, "old-phone")
    }
    func testReceiptFromAnotherDeviceDoesNotRebind() throws {
        let p = project();try store.update { $0.projects = [p] }
        let installer = FakeInstaller();installer.action = { _, _, _ in
            RenewalReceipt(expiration: self.now.addingTimeInterval(604800), profileUUID: "fresh", device: Device(id: "wrong", udid: "wrong", name: "Wrong", transport: "wired"))
        }
        XCTAssertEqual(try InstallationEngine(store: store, installer: installer).execute(InstallationRequest(deviceUDID: "new-phone", projects: [p])).failureCount, 1)
        XCTAssertEqual(try store.read().projects[0], p)
    }

    private func pipeline(_ p: Project, existingVersion: String? = nil, validProfile: Bool = true, disappearsAfterInstall: Bool = false, appearingVersion: String? = nil, duringBuild: (() throws -> Void)? = nil) throws -> (XcodeRenewer, FakeRunner) {
        try FileManager.default.createDirectory(atPath: p.container, withIntermediateDirectories: true)
        let runner = FakeRunner(); var installed = false; var built = false
        let product = store.paths.builds.appendingPathComponent("renew-\(p.id)/Products/Sample.app")
        runner.handler = { executable, args in
            var payload: Any = [:]
            if executable == "/usr/bin/xcrun" {
                var result: [String: Any] = [:]
                if args.contains("devices") {
                    result = ["devices": [["identifier": "new-core", "hardwareProperties": ["deviceType": "iPhone", "udid": "new-phone", "reality": "physical"],
                        "connectionProperties": ["pairingState": "paired", "transportType": "wired"], "deviceProperties": ["name": "New iPhone", "developerModeStatus": "enabled"]]]]
                } else if args.contains("install") {
                    installed = true; result = ["installedApplications": [["bundleID": p.bundleID]]]
                } else {
                    let presentVersion = built ? appearingVersion ?? existingVersion : existingVersion
                    let exists = presentVersion != nil || (installed && !disappearsAfterInstall)
                    result = ["apps": exists ? [["bundleIdentifier": p.bundleID, "version": installed ? "1.0" : presentVersion!, "bundleVersion": "1"]] : []]
                }
                let json = ["info": ["outcome": "success"], "result": result]
                try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: args[args.firstIndex(of: "--json-output")! + 1]))
            } else if executable == "/usr/bin/xcodebuild", args.contains("-showBuildSettings") {
                payload = [["buildSettings": ["TARGET_NAME": p.target, "PRODUCT_TYPE": "com.apple.product-type.application", "TARGETED_DEVICE_FAMILY": "1", "SDKROOT": "iphoneos", "PRODUCT_BUNDLE_IDENTIFIER": p.bundleID, "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": p.teamID, "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "1", "TARGET_BUILD_DIR": product.deletingLastPathComponent().path, "FULL_PRODUCT_NAME": product.lastPathComponent]]]
            } else if executable == "/usr/bin/xcodebuild", args.contains("build") {
                try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
                let info = ["CFBundleIdentifier": p.bundleID, "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: product.appendingPathComponent("Info.plist"))
                try Data().write(to: product.appendingPathComponent("embedded.mobileprovision"))
                built = true; try duringBuild?()
            } else if executable == "/usr/bin/security" {
                let profile: [String: Any] = ["UUID": "fresh", "TeamIdentifier": [p.teamID], "LocalProvision": true,
                    "Entitlements": ["application-identifier": p.teamID + "." + p.bundleID, "get-task-allow": true],
                    "CreationDate": Date(), "ExpirationDate": Date().addingTimeInterval(validProfile ? 604800 : 60), "ProvisionedDevices": ["new-phone"]]
                return CommandOutput(status: 0, data: try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0))
            }
            return CommandOutput(status: 0, data: try JSONSerialization.data(withJSONObject: payload))
        }
        let profiles = ProfileManager(runner: runner, paths: store.paths, caches: [])
        return (XcodeRenewer(runner: runner, paths: store.paths, profileManager: profiles), runner)
    }
    func testFirstInstallationUsesExplicitDeviceRegistrationAndVerifiedProfile() throws {
        let p = project();try store.update { $0.projects = [p] }
        let (renewer, runner) = try pipeline(p)
        let result = try InstallationEngine(store: store, installer: renewer).execute(InstallationRequest(deviceUDID: "new-phone", projects: [p]))
        XCTAssertEqual(result.successCount, 1)
        XCTAssertTrue(runner.calls.contains { $0.contains("-allowProvisioningDeviceRegistration") })
        XCTAssertEqual(runner.calls.filter { $0.contains("install") }.count, 1)
        XCTAssertFalse(runner.calls.flatMap { $0 }.contains("uninstall"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.paths.builds.path).isEmpty)
    }
    func testAutomaticRenewalStillRefusesMissingAppAndNeverRegistersNewDevice() throws {
        var p = project();p.boundDeviceID = "new-phone";try store.update { $0.projects = [p] }
        let (renewer, runner) = try pipeline(p)
        XCTAssertThrowsError(try renewer.renew(p, store: store))
        XCTAssertFalse(runner.calls.contains { $0.contains("install") || $0.contains("build") || $0.contains("-allowProvisioningDeviceRegistration") })
    }
    func testSelectedDeviceNeverFallsBackToAnotherPhone() throws {
        let p = project();try store.update { $0.projects = [p] }
        let (renewer, runner) = try pipeline(p)
        XCTAssertThrowsError(try renewer.install(p, on: "absent-phone", store: store))
        XCTAssertFalse(runner.calls.contains { $0.contains("install") || $0.contains("build") })
    }
    func testExistingNewerAppIsNotOverwritten() throws {
        let p = project();try store.update { $0.projects = [p] }
        let (renewer, runner) = try pipeline(p, existingVersion: "2.0")
        XCTAssertThrowsError(try renewer.install(p, on: "new-phone", store: store))
        XCTAssertFalse(runner.calls.contains { $0.contains("install") || $0.contains("build") })
    }
    func testInvalidProfilePreventsFirstInstallation() throws {
        let p = project();try store.update { $0.projects = [p] }
        let (renewer, runner) = try pipeline(p, validProfile: false)
        XCTAssertThrowsError(try renewer.install(p, on: "new-phone", store: store))
        XCTAssertFalse(runner.calls.contains { $0.contains("install") })
    }
    func testMissingPostInstallAppDoesNotChangeBinding() throws {
        let p = project();try store.update { $0.projects = [p] }
        let (renewer, _) = try pipeline(p, disappearsAfterInstall: true)
        let result = try InstallationEngine(store: store, installer: renewer).execute(InstallationRequest(deviceUDID: "new-phone", projects: [p]))
        XCTAssertEqual(result.failureCount, 1);XCTAssertEqual(try store.read().projects[0], p)
    }
    func testNewerAppAppearingDuringBuildIsNotOverwritten() throws {
        let p = project(); try store.update { $0.projects = [p] }
        let (renewer, runner) = try pipeline(p, appearingVersion: "2.0")
        XCTAssertThrowsError(try renewer.install(p, on: "new-phone", store: store))
        XCTAssertFalse(runner.calls.contains { $0.contains("install") })
    }
    func testAwayModeDuringBuildStopsBeforeFirstInstall() throws {
        let p = project(); try store.update { $0.projects = [p] }
        let (renewer, runner) = try pipeline(p, duringBuild: { try self.store.update { $0.mode = .away } })
        XCTAssertThrowsError(try renewer.install(p, on: "new-phone", store: store))
        XCTAssertFalse(runner.calls.contains { $0.contains("install") })
        XCTAssertEqual(try store.read().projects[0], p)
    }

}
