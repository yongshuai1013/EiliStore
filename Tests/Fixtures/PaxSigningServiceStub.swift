import SideSign
public final class PaxSigningService: @unchecked Sendable { public static let shared=PaxSigningService(); public func sessionWithFreshAnisette() async throws -> (SideSign.Account,SideSign.Session) { throw SideSign.StubError.unconfigured } }
