import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AnisettePresentationModel: ObservableObject {
    @Published var importing = false
    @Published var resetting = false
    @Published var confirmingDownload = false
    @Published var working = false
    @Published var message: String?
    @Published var libraryStatus: EiliAnisetteLibraryStatus?

    func refreshLibraryStatus() async {
        let status = await EiliAnisetteService.shared.localLibraryStatus()
        guard !Task.isCancelled else { return }
        libraryStatus = status
    }

    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            working = true
            Task {
                do {
                    let status = try await EiliAnisetteService.shared.importLibraries(urls)
                    if case .incompatible(let reason) = status { message = "新版庫組已保存供離線檢查，目前不能用於本機登入。\n" + reason }
                    else { message = "舊版函式庫已匯入並通過基本檢查；尚未驗證真機登入結果。" }
                } catch { message = safeMessage(error) }
                await refreshLibraryStatus()
                working = false
            }
        case .failure(let error):
            guard (error as NSError).code != NSUserCancelledError else { return }
            message = "無法讀取選取的檔案，請重試。"
        }
    }

    func download() {
        working = true
        Task {
            do {
                let status = try await EiliAnisetteService.shared.downloadLibraries()
                if case .incompatible(let reason) = status { message = "函式庫已下載並保存，但目前不能用於本機登入。\n" + reason }
                else { message = "函式庫已下載，通過 SHA-256 與基本格式檢查；尚未驗證真機登入，遠端仍為預設。" }
            } catch { message = safeMessage(error) }
            await refreshLibraryStatus(); working = false
        }
    }

    func reset() {
        working = true
        Task {
            do { try await EiliAnisetteService.shared.resetLocal(); message = "已重設本機 Anisette；遠端身分及函式庫保留不變。" }
            catch { message = safeMessage(error) }
            await refreshLibraryStatus(); working = false
        }
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "操作已取消。" }
        if let downloadError = error as? ADIRuntimeLibraryDownloader.DownloadError { return downloadError.localizedDescription }
        return (error as? EiliAnisetteError)?.localizedDescription ?? "本機資料操作未完成，請檢查檔案並重試。"
    }
}
