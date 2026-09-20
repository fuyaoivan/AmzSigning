import XCTest
@testable import AmzSigningCore

final class DeviceCompatibilityTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestData/\(UUID().uuidString)")
        paths = Paths(base: root); try paths.prepare()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func modern(complete: Bool, enabled: Bool = true) -> [String: Any] {
        var hardware: [String: Any] = ["deviceType": "iPhone", "udid": "example-phone"]
        var state: [String: Any] = ["name": "Example iPhone"]
        if complete {
            hardware["reality"] = "physical"
            state["developerModeStatus"] = [enabled ? "enabled" : "disabled": ["mode": enabled ? 1 : 0]]
        }
        return ["identifier": "example-core-id", "properties": ["hardware": hardware, "state": state,
            "connection": ["pairingState": "paired", "transportType": "localNetwork"]]]
    }
    private func runnerReturning(_ result: [String: Any]) -> FakeRunner {
        let runner = FakeRunner()
        runner.handler = { _, args in
            let path = args[args.firstIndex(of: "--json-output")! + 1]
            try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": result])
                .write(to: URL(fileURLWithPath: path))
            return CommandOutput(status: 0, data: Data())
        }
        return runner
    }
    func testModernDeviceDetailsDoNotRequireDeprecatedFields() {
        let devices = DeviceManager.parseDevices(["devices": [modern(complete: true)]])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].physical, true)
        XCTAssertEqual(devices[0].developerMode, true)
        XCTAssertEqual(devices[0].transportTitle, "Wi-Fi")
    }
    func testPartialListIsUnknownRatherThanDisabledAndLoadsDetails() throws {
        let device = DeviceManager.parseDevices(["devices": [modern(complete: false)]])[0]
        XCTAssertNil(device.physical); XCTAssertNil(device.developerMode)
        let runner = runnerReturning(modern(complete: true))
        let confirmed = try DeviceManager(runner: runner, paths: paths).confirmed(device)
        XCTAssertEqual(confirmed.physical, true); XCTAssertEqual(confirmed.developerMode, true)
        XCTAssertTrue(runner.calls[0].contains("details"))
        XCTAssertFalse(runner.calls.flatMap { $0 }.contains("install"))
    }
    func testIncompleteDetailsFailClosedWithoutClaimingDeveloperModeIsDisabled() {
        let device = DeviceManager.parseDevices(["devices": [modern(complete: false)]])[0]
        let runner = runnerReturning(modern(complete: false))
        XCTAssertThrowsError(try DeviceManager(runner: runner, paths: paths).confirmed(device)) {
            XCTAssertNil($0 as? SetupRequired)
        }
    }
    func testExplicitlyDisabledDeveloperModeRequiresUserAction() {
        let device = DeviceManager.parseDevices(["devices": [modern(complete: true, enabled: false)]])[0]
        XCTAssertThrowsError(try DeviceManager(runner: FakeRunner(), paths: paths).confirmed(device)) {
            XCTAssertEqual(($0 as? SetupRequired)?.issue, .developerMode)
        }
    }
    func testDetailsCannotSilentlySwitchPhysicalDevice() {
        let device = DeviceManager.parseDevices(["devices": [modern(complete: false)]])[0]
        var different = modern(complete: true); different["identifier"] = "different-device"
        XCTAssertThrowsError(try DeviceManager(runner: runnerReturning(different), paths: paths).confirmed(device))
    }
    func testSimulatorIsRejectedWithoutRelyingOnLegacyRealityField() {
        var row = modern(complete: false)
        var properties = row["properties"] as! [String: Any]
        properties["connection"] = ["pairingState": "paired", "transportType": "sameMachine"]
        row["properties"] = properties
        XCTAssertTrue(DeviceManager.parseDevices(["devices": [row]]).isEmpty)
    }
    func testUnknownStateCannotReachInstallation() {
        let device = DeviceManager.parseDevices(["devices": [modern(complete: false)]])[0]
        let runner = FakeRunner()
        XCTAssertThrowsError(try DeviceManager(runner: runner, paths: paths).install(appURL: root.appendingPathComponent("Sample.app"), bundleID: "org.example.Sample", device: device))
        XCTAssertTrue(runner.calls.isEmpty)
    }
}
