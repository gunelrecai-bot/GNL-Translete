import SwiftUI

struct MenuView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var confirmNew = false
    @State private var visitedSaved = false   // Kaydedilenler / Hazır Arşiv açıldı mı

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { confirmNew = true } label: { Label("Yeni Sohbet", systemImage: "plus.bubble") }
                }
                Section {
                    NavigationLink { SavedFoldersView().onAppear { visitedSaved = true } } label: { Label("Kaydedilenler", systemImage: "bookmark") }
                    NavigationLink { ArchiveView().onAppear { visitedSaved = true } } label: { Label("Hazır Arşiv", systemImage: "books.vertical") }
                }
                Section {
                    NavigationLink { SettingsView() } label: { Label("Ayarlar", systemImage: "gearshape") }
                    NavigationLink { SetupView(embedded: true) } label: { Label("Kurulum Durumu", systemImage: "checklist") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("GNL-Canlı Çeviri · Sürüm \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            .navigationTitle("Menü")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
            .confirmationDialog("Mevcut sohbet temizlenecek. Yeni sohbet başlatılsın mı?", isPresented: $confirmNew, titleVisibility: .visible) {
                Button("Yeni Sohbet Başlat", role: .destructive) {
                    ConversationController.shared.newConversation()
                    dismiss()
                }
                Button("Vazgeç", role: .cancel) {}
            }
        }
        // Menü açıkken sohbet dinlemesi duraklar; bağlam korunur.
        .onAppear { ConversationController.shared.beginOverlay() }
        .onDisappear { ConversationController.shared.endOverlay(applyResumeSetting: visitedSaved) }
    }
}

