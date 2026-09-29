import Foundation

public enum NotificationPermission: String, Codable { case allowed, denied, notDetermined }
public enum NoticeOutcome: String, Codable { case submitted, permissionRequired, failed }

public struct UserNotice: Codable, Equatable {
    public var id = UUID().uuidString
    public var issue: SetupIssue
    public var nextAttempt: Date?
    public var submittedAt: Date?
    public var outcome: NoticeOutcome?
    public init(issue: SetupIssue) { self.issue = issue }
    // v1.2.0's "attempted" is intentionally ignored: it never confirmed submission.
    public func isDue(at now: Date) -> Bool { submittedAt == nil && now >= (nextAttempt ?? .distantPast) }
}

/// State locking coordinates foreground and headless delivery. A persisted retry
/// deadline bounds crashes; only the notification service's acknowledgement marks success.
public final class NoticeDelivery {
    private let store: StateStore
    public init(store: StateStore) { self.store = store }

    public func claim(now: Date = Date()) throws -> UserNotice? {
        let state = try store.read()
        guard state.mode == .automatic, let notice = state.notice,
              state.requiresAction(notice.issue), notice.isDue(at: now) else { return nil }
        var claimed: UserNotice?
        try store.update { state in
            guard state.mode == .automatic, state.notice?.id == notice.id,
                  state.requiresAction(notice.issue), state.notice?.isDue(at: now) == true else { return }
            state.notice?.nextAttempt = now.addingTimeInterval(Timing.retry)
            state.notice?.outcome = nil
            claimed = state.notice
        }
        return claimed
    }

    public func finish(id: String, outcome: NoticeOutcome, now: Date = Date()) throws {
        let state = try store.read()
        guard state.notice?.id == id else { return }
        try store.update { state in
            guard state.notice?.id == id else { return }
            state.notice?.outcome = outcome
            state.notice?.submittedAt = outcome == .submitted ? now : nil
            state.notice?.nextAttempt = outcome == .submitted ? nil : now.addingTimeInterval(Timing.retry)
        }
    }

    public func authorizationChanged(_ permission: NotificationPermission) throws {
        let state = try store.read()
        let resume = permission == .allowed && state.notice?.outcome == .permissionRequired
        guard state.notificationPermission != permission || resume else { return }
        try store.update { state in
            state.notificationPermission = permission
            if permission == .allowed, state.notice?.outcome == .permissionRequired {
                state.notice?.nextAttempt = nil
            }
        }
    }

    public func dispatch(runner: CommandRunning, application: URL, now: Date = Date()) throws {
        guard let notice = try claim(now: now) else { return }
        do {
            _ = try runner.run(application.path, ["--notify", notice.id], timeout: 15)
        } catch {
            try finish(id: notice.id, outcome: .failed, now: now)
        }
        // Exit code zero alone does not acknowledge a submitted notification.
        if let current = try store.read().notice, current.id == notice.id, current.outcome == nil {
            try finish(id: notice.id, outcome: .failed, now: now)
        }
    }
}
