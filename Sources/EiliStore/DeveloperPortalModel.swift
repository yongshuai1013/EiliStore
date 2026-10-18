import Foundation
import Combine
import SideSign

/// 參考 SideStore DeveloperServicesViewModel，另以 generation 隔離過期團隊請求。
@MainActor
public final class DeveloperPortalModel: ObservableObject {
    @Published public private(set) var teams: [SideSign.Team] = []
    @Published public private(set) var team: SideSign.Team?
    @Published public private(set) var appIDs: [SideSign.AppID] = []
    @Published public private(set) var profiles: [SideSign.ListedProvisioningProfile] = []
    @Published public private(set) var certificates: [SideSign.X509Certificate] = []
    @Published public private(set) var appGroups: [SideSign.AppGroup] = []
    @Published public private(set) var devices: [SideSign.Device] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isActing = false
    @Published public var errorMessage: String?
    @Published public var message: String?
    @Published public private(set) var sectionErrors: [String: String] = [:]
    private let service: any DeveloperPortalServicing
    private let hasSession: () -> Bool
    private var generation = 0

    public init(service: any DeveloperPortalServicing = DeveloperPortalService.shared,
                hasSession: @escaping () -> Bool = { PaxAuthService.shared.hasSavedSession }) {
        self.service = service
        self.hasSession = hasSession
    }

    public func load() async {
        guard !isActing, !Task.isCancelled else { return }
        let preferredID = team?.identifier
        generation += 1
        let token = generation
        clearSections()
        teams = []; team = nil; errorMessage = nil; message = nil
        guard hasSession() else { errorMessage = "尚未登入，請先登入 Apple ID。"; isLoading = false; return }
        isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            let fetched = try await service.fetchTeams()
            guard token == generation, !Task.isCancelled else { return }
            teams = fetched
            guard let selected = fetched.first(where: { $0.identifier == preferredID }) ?? fetched.first else {
                errorMessage = "Apple 沒有回傳可用的開發者團隊。"
                return
            }
            team = selected
            await loadSections(for: selected, token: token)
        } catch {
            guard token == generation else { return }
            errorMessage = Self.safeMessage(error)
        }
    }

    public func selectTeam(_ selected: SideSign.Team) async {
        guard !isActing, !Task.isCancelled,
              let selected = teams.first(where: { $0.identifier == selected.identifier }),
              team?.identifier != selected.identifier else { return }
        generation += 1
        let token = generation
        team = selected; clearSections(); errorMessage = nil; message = nil; isLoading = true
        defer { if token == generation { isLoading = false } }
        await loadSections(for: selected, token: token)
    }

    public func refresh() async {
        guard !isActing, !Task.isCancelled else { return }
        guard hasSession(), let current = team else { await load(); return }
        generation += 1
        let token = generation
        isLoading = true
        errorMessage = nil
        defer { if token == generation { isLoading = false } }
        await loadSections(for: current, token: token)
    }

    private func clearSections() {
        appIDs = []; profiles = []; certificates = []; appGroups = []; devices = []; sectionErrors = [:]
    }

    private func loadSections(for selected: SideSign.Team, token: Int) async {
        let service = self.service
        async let a = Self.capture { try await service.fetchAppIDs(for: selected) }
        async let p = Self.capture { try await service.fetchProfiles(for: selected) }
        async let c = Self.capture { try await service.fetchCertificates(for: selected) }
        async let g = Self.capture { try await service.fetchAppGroups(for: selected) }
        async let d = Self.capture { try await service.fetchDevices(for: selected) }
        let (ar, pr, cr, gr, dr) = await (a, p, c, g, d)
        guard token == generation, team?.identifier == selected.identifier, !Task.isCancelled else { return }
        sectionErrors = [:]
        apply(ar, key: "appIDs") { appIDs = $0.sorted { Self.before($0.name, $1.name) } }
        apply(pr, key: "profiles") { profiles = $0.sorted { Self.before($0.name, $1.name) } }
        apply(cr, key: "certificates") { certificates = $0.sorted { Self.before($0.machineName ?? $0.name, $1.machineName ?? $1.name) } }
        apply(gr, key: "appGroups") { appGroups = $0.sorted { Self.before($0.name, $1.name) } }
        apply(dr, key: "devices") { devices = $0.sorted { Self.before($0.name, $1.name) } }
    }

    private static func before(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
    private func apply<T>(_ result: Result<[T], Error>, key: String, assign: ([T]) -> Void) {
        switch result {
        case .success(let value): assign(value)
        case .failure(let error): sectionErrors[key] = Self.safeMessage(error)
        }
    }
    nonisolated private static func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    public func execute(_ operation: @escaping @MainActor (SideSign.Team) async throws -> Void) async -> Bool {
        guard !Task.isCancelled, !isLoading, !isActing else { return false }
        guard hasSession(), let current = team else {
            await load()
            return false
        }
        isActing = true; errorMessage = nil; message = nil
        defer { isActing = false }
        do {
            try await operation(current)
            message = "操作已完成。"
            // 操作持鎖期間只允許內部重載；外部 refresh/load/selectTeam 不可穿插。
            generation += 1
            let token = generation
            isLoading = true
            await loadSections(for: current, token: token)
            isLoading = false
            return true
        } catch {
            errorMessage = Self.safeMessage(error)
            return false
        }
    }

    private static func safeMessage(_ error: Error) -> String {
        if let validation = error as? DeveloperPortalValidationError { return validation.localizedDescription }
        if error is CancellationError { return "操作已取消；如已送出變更，請重新整理確認結果，避免重複提交。" }
        if error is URLError { return "網路請求未完成，請檢查連線後重新整理。" }
        // 不顯示原始 server payload、URL、登入資訊或憑證。
        return "Developer Portal 請求失敗，請重新整理；如登入已失效，請返回帳戶頁重新登入。"
    }
}
