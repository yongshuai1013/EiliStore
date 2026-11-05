import Foundation

/// Coalesces concurrent lifecycle-triggered checks into one uncancellable run.
/// The next invocation after completion starts a fresh check (for foreground returns).
@MainActor
final class AutomaticRefreshCheckGate {
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func run(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        if let task {
            await task.value
            return
        }

        let task = Task { @MainActor in
            await operation()
        }
        self.task = task
        await task.value
        self.task = nil
    }
}

/// Synchronous main-actor guard shared by every refresh entry point.
@MainActor
final class RefreshOperationGate {
    private(set) var isRunning = false

    func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func end() {
        isRunning = false
    }
}
