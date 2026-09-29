import XCTest
@testable import AmzSigningCore

final class RecoveryTests: XCTestCase {
    private var root: URL!
    private var store: StateStore!
    private var delivery: NoticeDelivery!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestData/\(UUID().uuidString)")
        store = try StateStore(paths: Paths(base: root))
        delivery = NoticeDelivery(store: store)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func project(_ name: String = "Sample") -> Project {
        var p = Project(container: "/Projects/\(name).xcodeproj", scheme: name, target: name,
                        bundleID: "org.example.\(name)", teamID: "EXAMPLE", automatic: true, personalTeam: true)
        p.approve(true); p.lastSuccess = now
        return p
    }
    private func seedNotice() throws {
        var p = project(); p.recordFailure("account missing", at: now, issue: .account)
        try store.update { $0.projects = [p]; $0.notice = UserNotice(issue: .account) }
    }
    private let networkError = """
    /Projects/Sample.xcodeproj: error: Unable to log in with account 'example@example.com'. An unexpected failure occurred while logging in (Underlying error code -1004). (in target 'Sample' from project 'Sample')
    /Projects/Sample.xcodeproj: error: No profiles for 'org.example.Sample' were found. (in target 'Sample' from project 'Sample')
    """
    func testLoginTransportFailureDoesNotRequestAccountReplacement() throws {
        XCTAssertTrue(CommandDiagnostics.isNetworkFailure(networkError))
        XCTAssertNil(SetupIssue.classify(networkError))
        let runner = FakeRunner(); runner.handler = { _, _ in CommandOutput(status: 65, data: Data(self.networkError.utf8)) }
        XCTAssertThrowsError(try runner.checked("/usr/bin/xcodebuild", ["build"])) {
            XCTAssertNil($0 as? SetupRequired)
            XCTAssertTrue($0.localizedDescription.contains("网络连接失败"))
        }
    }
    func testNetworkFailureKeepsSixHourRetryWithoutActionNotice() throws {
        let p = project(); try store.update { $0.projects = [p] }
        let renewer = FakeRenewer(); renewer.operation = { _, _ in throw AmzError(CommandDiagnostics.retryMessage(self.networkError)!) }
        _ = try RenewalEngine(store: store, renewer: renewer).execute(force: true, now: { self.now })
        let state = try store.read()
        XCTAssertNil(state.notice); XCTAssertNil(state.projects[0].retryIssue)
        XCTAssertEqual(state.projects[0].nextRetry, now.addingTimeInterval(Timing.retry))
        XCTAssertEqual(state.projects[0].lastSuccess, p.lastSuccess)
    }
    func testMissingAccountAndExpiredSessionRemainActionable() {
        XCTAssertEqual(SetupIssue.classify("/Projects/Sample.xcodeproj: error: No Accounts: Add a new account in Accounts settings."), .account)
        XCTAssertEqual(SetupIssue.classify("Your session has expired. Please log in."), .account)
        XCTAssertEqual(SetupIssue.classify(networkError + "\n/Projects/Other.xcodeproj: error: No Accounts: Add a new account."), .account)
    }
    func testAccountWarningCannotOverrideCompilerError() {
        let output = "DVTDeveloperAccountManager: session has expired\n/Projects/Sample.swift:18:7: error: cannot find value in scope"
        XCTAssertNil(SetupIssue.classify(output))
    }
    func testDeviceAssertionFailureIsTransientNotARequestToChangeTrust() {
        let output = "ERROR: The device is not able to fulfill the requested usage assertion requirements. (com.apple.dt.CoreDeviceError error 4016 (0xFB0))"
        XCTAssertNil(SetupIssue.classify(output))
        XCTAssertTrue(CommandDiagnostics.retryMessage(output)?.contains("iPhone 开发连接暂不可用") == true)
    }
    func testLegacyAttemptedNoticeHasNoSubmissionReceipt() throws {
        let data = Data(#"{"id":"example-notice","issue":"account","attempted":true}"#.utf8)
        let notice = try JSONDecoder.amz.decode(UserNotice.self, from: data)
        XCTAssertNil(notice.submittedAt); XCTAssertTrue(notice.isDue(at: now))
        let encoded = String(decoding: try JSONEncoder.amz.encode(notice), as: UTF8.self)
        XCTAssertFalse(encoded.contains("attempted"))
    }
    func testNotificationClaimSurvivesInterruptionWithoutBusyRetry() throws {
        try seedNotice()
        XCTAssertNotNil(try delivery.claim(now: now))
        let data = try Data(contentsOf: store.paths.state)
        XCTAssertNil(try delivery.claim(now: now.addingTimeInterval(60)))
        XCTAssertEqual(try Data(contentsOf: store.paths.state), data)
        XCTAssertNotNil(try delivery.claim(now: now.addingTimeInterval(Timing.retry)))
        XCTAssertNil(try store.read().notice?.submittedAt)
    }
    func testPermissionDenialDoesNotMarkSubmittedAndGrantResumesImmediately() throws {
        try seedNotice(); let notice = try XCTUnwrap(delivery.claim(now: now))
        try delivery.authorizationChanged(.denied)
        try delivery.finish(id: notice.id, outcome: .permissionRequired, now: now)
        XCTAssertNil(try store.read().notice?.submittedAt)
        XCTAssertNil(try delivery.claim(now: now.addingTimeInterval(1)))
        try delivery.authorizationChanged(.allowed)
        XCTAssertNotNil(try delivery.claim(now: now.addingTimeInterval(2)))
    }
    func testSuccessfulSubmissionIsAcknowledgedOnce() throws {
        try seedNotice(); let notice = try XCTUnwrap(delivery.claim(now: now))
        try delivery.finish(id: notice.id, outcome: .submitted, now: now)
        XCTAssertEqual(try store.read().notice?.submittedAt, now)
        XCTAssertNil(try delivery.claim(now: now.addingTimeInterval(Timing.retry * 2)))
    }
    func testZeroExitWithoutAcknowledgementIsNotSuccessfulDelivery() throws {
        try seedNotice()
        try delivery.dispatch(runner: FakeRunner(), application: root.appendingPathComponent("Example.app/Contents/MacOS/Example"), now: now)
        XCTAssertEqual(try store.read().notice?.outcome, .failed)
        XCTAssertNil(try store.read().notice?.submittedAt)
        XCTAssertEqual(try store.read().notice?.nextAttempt, now.addingTimeInterval(Timing.retry))
    }
    func testStaleDeliveryCannotModifyReplacementNotice() throws {
        try seedNotice(); let old = try XCTUnwrap(delivery.claim(now: now))
        let replacement = UserNotice(issue: .deviceLocked)
        try store.update { $0.notice = replacement }
        try delivery.finish(id: old.id, outcome: .submitted, now: now)
        XCTAssertEqual(try store.read().notice, replacement)
    }
    func testAwayOrRemovedProjectDoesNotSendActionNotice() throws {
        try seedNotice(); try store.update { $0.mode = .away }
        XCTAssertNil(try delivery.claim(now: now))
        try store.update { $0.mode = .automatic; $0.projects = [] }
        XCTAssertNil(try delivery.claim(now: now))
    }
    func testRetryFailuresDoesNotRenewHealthyOrNewProject() throws {
        let healthy = project("Healthy")
        var fresh = project("New"); fresh.lastSuccess = nil
        var failed = project("Failed"); failed.recordFailure("account missing", at: now, issue: .account)
        var disabled = project("Disabled"); disabled.recordFailure("offline", at: now); disabled.approve(false)
        try store.update { $0.projects = [healthy, failed, fresh, disabled] }
        let renewer = FakeRenewer()
        let result = try RenewalEngine(store: store, renewer: renewer).execute(force: true, failedOnly: true, now: { self.now })
        XCTAssertEqual(renewer.calls, [failed.id]); XCTAssertEqual(result?.trigger, "重试失败项目")
        XCTAssertEqual(try store.read().projects[0], healthy)
        XCTAssertEqual(try store.read().projects[2], fresh)
        XCTAssertNil(try store.read().projects[1].nextRetry)
    }
    func testRetryFailuresRespectsAwayMode() throws {
        try seedNotice(); try store.update { $0.mode = .away }
        let renewer = FakeRenewer()
        XCTAssertNil(try RenewalEngine(store: store, renewer: renewer).execute(force: true, failedOnly: true, now: { self.now }))
        XCTAssertTrue(renewer.calls.isEmpty)
    }
}
