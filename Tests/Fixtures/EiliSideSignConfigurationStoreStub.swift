import SideSign

public actor EiliSideSignClientConfigurationStore {
    public static let shared = EiliSideSignClientConfigurationStore()
    private init() {}

    public func makePortal() throws -> SideSign.DeveloperPortal {
        fatalError("Production portal configuration must not be used in offline service tests")
    }
}
