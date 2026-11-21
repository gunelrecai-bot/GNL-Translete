import SwiftUI
import SwiftData

@main
struct GNLTransleteApp: App {
    @State private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
        }
        .modelContainer(for: [Folder.self, SavedPhrase.self])
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ResolvedTheme(p: Themes.palette("gnl"))
}
extension EnvironmentValues {
    var theme: ResolvedTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase

    var body: some View {
        let theme = ResolvedTheme(p: settings.palette(for: scheme))
        Group {
            if settings.setupComplete {
                MainView()
            } else {
                SetupView()
            }
        }
        .environment(\.theme, theme)
        .tint(theme.accent)
        .task {
            // indirilmiş Whisper modelini belleğe yükle
            if WhisperEngine.shared.isDownloaded { await WhisperEngine.shared.prepare() }
        }
        .onChange(of: phase) { _, p in
            // arka plana geçişte bağlam korunur; geri gelince ses listesi yenilenir
            if p == .active { AudioRoute.shared.refresh() }
        }
    }
}
