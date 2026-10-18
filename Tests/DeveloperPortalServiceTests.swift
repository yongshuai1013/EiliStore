import Foundation
import SideSign

final class Counter: @unchecked Sendable { private let lock=NSLock(); private var n=0; func inc(){lock.lock();n += 1;lock.unlock()}; var value:Int{lock.lock();defer{lock.unlock()};return n} }
final class FakePortal: SideSign.DeveloperPortalAPI, @unchecked Sendable {
 var created:[String]=[]; var updated:[String]=[]; var deleteResult=false; var updatedFeatures:[[SideSign.Feature:String]]=[]; var calls:[String]=[]
 func fetchTeams(for:SideSign.Account,session:SideSign.Session) async throws->[SideSign.Team]{[]}
 func fetchAppIDs(for:SideSign.Team,session:SideSign.Session) async throws->[SideSign.AppID]{[]}
 func listProvisioningProfiles(for:SideSign.Team,session:SideSign.Session) async throws->[SideSign.ListedProvisioningProfile]{[]}
 func fetchCertificates(for:SideSign.Team,session:SideSign.Session) async throws->[SideSign.X509Certificate]{[]}
 func fetchAppGroups(for:SideSign.Team,session:SideSign.Session) async throws->[SideSign.AppGroup]{[]}
 func fetchDevices(for:SideSign.Team,types:SideSign.DeviceType,session:SideSign.Session) async throws->[SideSign.Device]{[]}
 func createProvisioningProfile(name:String,appID:SideSign.AppID,certificateIDs:[String],deviceIDs:[String],type:SideSign.ProfileType,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.ProvisioningProfile { created=[type.subPlatformParameter ?? "nil",type.distributionTypeParameter]; return .init() }
 func updateProvisioningProfile(profileID:String,name:String,appIDId:String,certificateIDs:[String],deviceIDs:[String],type:SideSign.ProfileType,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.ProvisioningProfile { updated=[type.subPlatformParameter ?? "nil",type.distributionTypeParameter]; return .init() }
 func downloadProvisioningProfile(profileID:String,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.ProvisioningProfile{.init()}
 func downloadProvisioningProfile(for:SideSign.AppID,isTeamProfile:Bool,subPlatform:String?,deviceType:SideSign.DeviceType,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.ProvisioningProfile{.init()}
 func downloadProvisioningProfile(for appID:SideSign.AppID,isTeamProfile:Bool,type:SideSign.ProfileType,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.ProvisioningProfile{.init()}
 func downloadProvisioningProfile(for appID:SideSign.AppID,type:SideSign.ProfileType,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.ProvisioningProfile{.init()}
 func deleteProvisioningProfile(profileID:String,team:SideSign.Team,session:SideSign.Session) async throws->Bool{deleteResult}
 func addAppGroup(name:String,groupIdentifier:String,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.AppGroup{.init()}
 func updateAppGroup(_ appGroup:SideSign.AppGroup,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.AppGroup{appGroup}
 func deleteAppGroup(_ appGroup:SideSign.AppGroup,team:SideSign.Team,session:SideSign.Session) async throws->Bool{false}
 func updateAppID(_ appID:SideSign.AppID,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.AppID{calls.append("enable"); updatedFeatures.append(appID.features); return appID}
 func assignAppGroups(_ appGroups:[SideSign.AppGroup],to appID:SideSign.AppID,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.AppID{calls.append("assign");return appID}
 func registerDevice(name:String,identifier:String,type:SideSign.DeviceType,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.Device{.init()}
 func updateDevice(_ device:SideSign.Device,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.Device{device}
 func disableDevice(_ device:SideSign.Device,team:SideSign.Team,session:SideSign.Session) async throws->SideSign.Device{device}
 func deleteDevice(_ device:SideSign.Device,team:SideSign.Team,session:SideSign.Session) async throws->Bool{false}
}
@main struct Tests {
 static func main() async throws {
  let p=FakePortal(); let fresh=Counter()
  let service=DeveloperPortalService(portal:p,sessionProvider:{fresh.inc(); return (SideSign.Account(),SideSign.Session())})
  let t=SideSign.Team("team",type:.paid), app=SideSign.AppID("com.example.app")
  _=try await service.createProfile(name:"x",appID:app,certificateIDs:["c"],deviceIDs:[],type:.tvOSAppStore,for:t)
  precondition(p.created == ["tvOS","store"])
  _=try await service.updateProfile(.init("pid"),name:"x",appIDId:app.identifier,certificateIDs:["c"],deviceIDs:[],type:.tvOSAppStore,for:t)
  precondition(p.updated == ["tvOS","store"])
  do {try await service.deleteProfile(.init("pid"),for:t); fatalError("false delete accepted")} catch DeveloperPortalValidationError.operationFailed {}
  let before=fresh.value; _=await service.deleteAllProfiles([.init("ok"),.init("bad")],for:t); let stats=await service.deleteAllProfiles([.init("a")],for:t)
  precondition(stats.deletedCount == 0 && stats.failedCount == 1 && fresh.value == before+3)
  p.deleteResult=true
  let invalid=DeveloperPortalService(portal:p,sessionProvider:{fatalError("called")})
  do {_=try await invalid.downloadProfile(.init(nil),for:t);fatalError("missing ID accepted")} catch DeveloperPortalValidationError.missingProfileIdentifier {}
  p.deleteResult=true;
  _=try await service.assignAppGroups([.init()],to:app,for:t)
  precondition(p.calls.suffix(2) == ["enable","assign"] && p.updatedFeatures.last == [SideSign.Feature.appGroups:"true"] && fresh.value == before+5)
  print("DeveloperPortalService contract tests passed")
 }
}
