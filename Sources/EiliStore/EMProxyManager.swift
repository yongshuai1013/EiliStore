import Foundation
import EMProxy

public class EMProxyManager {
    public static let shared = EMProxyManager()
    private init() {}

    public private(set) var isRunning = false

    public func start(bindHost: String = "127.0.0.1", bindPort: UInt16 = 51820) -> Int32 {
        let addr = "\(bindHost):\(bindPort)"
        let result = addr.withCString { ptr in
            start_emotional_damage(ptr)
        }
        if result == 0 {
            isRunning = true
        }
        return result
    }

    public func stop() -> Int32 {
        let result = stop_emotional_damage()
        if result == 0 {
            isRunning = false
        }
        return result
    }

}
