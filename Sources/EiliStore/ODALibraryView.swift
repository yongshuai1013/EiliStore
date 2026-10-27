import SwiftUI

/// On-Device Anisette library source: where the runtime ADI libraries are
/// fetched from, plus an explicit re-download that replaces the cached set.
/// The sign-in path reads the same configuration
/// (EiliODASourceConfiguration), so the URLs saved here are the ones the
/// next on-device sign-in and refresh will actually use. Saving a URL never
/// replaces already-cached libraries by itself.
struct ODALibraryView: View {
    @State private var sourceURL: String
    @State private var fallbackURL: String
    @State private var isRefreshing = false
    @State private var message: String?

    init() {
        let defaults = UserDefaults.standard
        _sourceURL = State(initialValue: defaults.string(forKey: EiliODASourceConfiguration.sourceURLKey) ?? "")
        _fallbackURL = State(initialValue: defaults.string(forKey: EiliODASourceConfiguration.fallbackURLKey) ?? "")
    }

    var body: some View {
        Form {
            Section(header: Text("LIBRARY SOURCE"),
                    footer: Text("來源留空時使用預設目錄（\(EiliODASourceConfiguration.defaultCatalogURLString)）；備援留空時使用預設位址（\(EiliODASourceConfiguration.defaultFallbackURLString)）。只改網址不會更換已快取的函式庫：改完請按下方重新下載，再 Reset adi.pb 重新佈建。")) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("來源網址").font(.subheadline)
                    TextField(EiliODASourceConfiguration.defaultCatalogURLString, text: $sourceURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("odalib-source-field")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("備援網址").font(.subheadline)
                    TextField(EiliODASourceConfiguration.defaultFallbackURLString, text: $fallbackURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("odalib-fallback-field")
                }
                Button("儲存來源") { saveSources() }
                    .accessibilityIdentifier("odalib-save-sources")
                    .disabled(isRefreshing)
            }

            Section(header: Text("LIBRARIES")) {
                Button {
                    refresh()
                } label: {
                    HStack {
                        if isRefreshing {
                            ProgressView()
                        }
                        Text("從來源重新下載函式庫")
                    }
                }
                .disabled(isRefreshing)
                .accessibilityIdentifier("odalib-refresh")

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("本機函式庫來源")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("oda-library-page")
    }

    private func saveSources() {
        let defaults = UserDefaults.standard
        let source = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fallbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty {
            defaults.removeObject(forKey: EiliODASourceConfiguration.sourceURLKey)
        } else {
            defaults.set(source, forKey: EiliODASourceConfiguration.sourceURLKey)
        }
        if fallback.isEmpty {
            defaults.removeObject(forKey: EiliODASourceConfiguration.fallbackURLKey)
        } else {
            defaults.set(fallback, forKey: EiliODASourceConfiguration.fallbackURLKey)
        }
        message = "來源已儲存；下一次本機登入與重新下載會使用新來源。"
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            do {
                try await EiliAnisetteService.shared.refreshRemoteODALibraries()
                message = "函式庫已從目前來源重新下載並安裝。請回到用戶自定義按 Reset adi.pb，再重新登入。"
            } catch {
                message = error.localizedDescription
            }
            isRefreshing = false
        }
    }
}
