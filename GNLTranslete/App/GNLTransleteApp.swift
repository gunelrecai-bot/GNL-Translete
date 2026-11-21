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
            // Eski sürümlerden kalan Whisper dosyalarını sil (yer kaplamasın)
            let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Whisper")
            try? FileManager.default.removeItem(at: old)
            // Apple motorunu kontrol et; hazırsa onunla dinle, değilse yerleşik tanıyıcı
            await AppleSpeechSupport.shared.check()
            ConversationController.shared.restartListening()
        }
        .onChange(of: phase) { _, p in
            // arka plana geçişte bağlam korunur; geri gelince ses listesi yenilenir
            // Arka planda dinleme ve modeller durur: telefon yavaşlamasın, pil bitmesin. Sohbet korunur.
            if p == .background { ConversationController.shared.enterBackground() }
            if p == .active { AudioRoute.shared.refresh(); ConversationController.shared.enterForeground() }
        }
    }
}
