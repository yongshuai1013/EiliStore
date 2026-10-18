import Foundation
import SideSign

@main struct DeveloperPortalModelTests {
    @MainActor static func main() async {
        await noSessionDoesNotCallService()
        await successfulLoadAndPartialFailure()
        await staleTeamResultIsIgnored()
        await emptyTeamsClearState()
        await executeLocksAndSanitizes()
        print("DeveloperPortalModelTests: OK")
    }

    @MainActor static func noSessionDoesNotCallService() async {
        let fake = FakeDeveloperPortalService()
        let model = DeveloperPortalModel(service: fake, hasSession: { false })
        await model.load()
        expect(model.errorMessage != nil, "missing-session error expected")
        expect(await fake.fetchTeamCount == 0, "teams must not be fetched without session")
    }

    @MainActor static func successfulLoadAndPartialFailure() async {
        let fake = FakeDeveloperPortalService()
        let t = SideSign.Team("T1")
        await fake.setTeams([t])
        await fake.setAppIDs([SideSign.AppID("id.b", name: "zeta"), SideSign.AppID("id.a", name: "Alpha")], team: t)
        await fake.setDevices([SideSign.Device("d1", name: "Phone")], team: t)
        await fake.fail(["profiles"], true)
        let model = DeveloperPortalModel(service: fake, hasSession: { true })
        await model.load()
        expect(model.team == t && model.teams == [t], "team should load")
        expect(model.appIDs.map(\.name) == ["Alpha", "zeta"], "app IDs should load in sorted order")
        expect(model.devices.count == 1, "unfailed sections should remain available")
        expect(model.sectionErrors["profiles"] != nil, "failed section should be identified")
        expect(!model.isLoading, "load should finish")
    }

    @MainActor static func staleTeamResultIsIgnored() async {
        let fake = FakeDeveloperPortalService()
        let a = SideSign.Team("A"), b = SideSign.Team("B")
        await fake.setTeams([a, b]); await fake.block(team: "A")
        let model = DeveloperPortalModel(service: fake, hasSession: { true })
        let oldLoad = Task { await model.load() }
        for _ in 0..<200 { if await fake.calls("appIDs") > 0 { break }; await Task.yield() }
        await model.selectTeam(b)
        await fake.releaseBlockedFetch()
        await oldLoad.value
        expect(model.team == b, "team switch must win over stale load")
        expect(model.appIDs.isEmpty, "stale results must not overwrite current sections")
    }

    @MainActor static func emptyTeamsClearState() async {
        let fake = FakeDeveloperPortalService()
        let t = SideSign.Team("A")
        await fake.setTeams([t]); await fake.setAppIDs([SideSign.AppID("x")], team: t)
        let model = DeveloperPortalModel(service: fake, hasSession: { true })
        await model.load(); expect(!model.appIDs.isEmpty, "initial fixture should populate state")
        await fake.setTeams([]); await model.load()
        expect(model.team == nil && model.teams.isEmpty && model.appIDs.isEmpty, "empty teams should clear selected data")
    }

    @MainActor static func executeLocksAndSanitizes() async {
        let fake = FakeDeveloperPortalService(), t = SideSign.Team("A")
        await fake.setTeams([t])
        let model = DeveloperPortalModel(service: fake, hasSession: { true })
        await model.load()
        var operationCalls = 0
        var continuation: CheckedContinuation<Void, Never>?
        let first = Task { await model.execute { _ in operationCalls += 1; await withCheckedContinuation { continuation = $0 } } }
        for _ in 0..<200 { if model.isActing { break }; await Task.yield() }
        let second = await model.execute { _ in operationCalls += 100 }
        expect(!second && operationCalls == 1, "concurrent execute must be rejected")
        continuation?.resume()
        expect(await first.value, "first operation should succeed")
        let failed = await model.execute { _ in throw NSError(domain: "payload=PRIVATE_TOKEN", code: 1) }
        expect(!failed, "failing operation should report false")
        expect(!(model.errorMessage ?? "").contains("PRIVATE_TOKEN") && !(model.errorMessage ?? "").contains("payload"), "error must not disclose token or payload")
    }

    static func expect(_ condition: Bool, _ message: String) { if !condition { fatalError("ASSERTION FAILED: \(message)") } }
}

extension FakeDeveloperPortalService {
    func setTeams(_ value: [SideSign.Team]) { teamResults = value }
    func setAppIDs(_ value: [SideSign.AppID], team: SideSign.Team) { appIDResults[team.identifier] = value }
    func setDevices(_ value: [SideSign.Device], team: SideSign.Team) { deviceResults[team.identifier] = value }
    func fail(_ sections: Set<String>, _ value: Bool) { failingSections = value ? sections : [] }
    func block(team: String?) { blockedTeam = team }
    func calls(_ section: String) -> Int { sectionCalls[section, default: 0] }
}
