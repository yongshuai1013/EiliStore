import Foundation

@MainActor
private final class TestCounter {
    var value = 0
}

@main
struct AutomaticRefreshGateTests {
    @MainActor
    static func main() async {
        let checkGate = AutomaticRefreshCheckGate()
        let counter = TestCounter()

        let first = Task { @MainActor in
            await checkGate.run {
                counter.value += 1
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        while !checkGate.isRunning {
            await Task.yield()
        }
        // Cancelling the lifecycle caller must not cancel the shared Portal/device operation.
        first.cancel()
        let concurrent = Task { @MainActor in
            await checkGate.run {
                counter.value += 100
            }
        }
        await first.value
        await concurrent.value
        precondition(counter.value == 1, "concurrent or cancelled lifecycle checks must share one run")

        // A later foreground event is a new check, not permanently suppressed.
        await checkGate.run {
            counter.value += 10
        }
        precondition(counter.value == 11, "a later foreground check must run after the prior check completes")

        let refreshGate = RefreshOperationGate()
        precondition(refreshGate.begin(), "the first refresh must acquire the gate")
        precondition(!refreshGate.begin(), "a concurrent refresh must be rejected")
        refreshGate.end()
        precondition(refreshGate.begin(), "the refresh gate must be reusable after completion")
        refreshGate.end()

        print("PASS: automatic refresh gates coalesce, survive caller cancellation, and allow later foreground checks")
    }
}
