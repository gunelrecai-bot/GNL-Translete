import SwiftUI
import Translation
import AVFoundation
import Speech

/// İlk kurulum: izinler + modellerin bir kez indirilmesi. Eksikler açıkça gösterilir.
struct SetupView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    var embedded = false   // Menü → Kurulum Durumu

    @State private var micOK = false
    @State private var speechAuthOK = false
    @State private var onDevice: [DeviceSpeechStatus] = []
    @State private var trans: (trEn: LanguageAvailability.Status, enTr: LanguageAvailability.Status)?
    @State private var transConfig: TranslationSession.Configuration?
    @State private var transConfig2: TranslationSession.Configuration?
    @State private var model = ModelStore.shared
    @State private var checking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !embedded {
                        HStack(spacing: 12) {
                            Image("Logo").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading) {
                                Text("GNL-Translete").font(.title2.bold())
                                Text("İlk kurulum · İnternet yalnızca bu indirmeler için kullanılır.").font(.footnote).opacity(0.8)
                            }
                        }.foregroundStyle(theme.onBg)
                    }

                    row("Mikrofon izni", ok: micOK, detail: micOK ? "Verildi" : "Gerekli") {
                        Button("İzin Ver") { Task { await requestMic() } }
                    }
                    row("Konuşma tanıma izni", ok: speechAuthOK, detail: speechAuthOK ? "Verildi" : "Gerekli") {
                        Button("İzin Ver") { Task { speechAuthOK = await ListeningEngine.requestAuth(); refresh() } }
                    }
                    ForEach(onDevice, id: \.locale) { s in
                        row("Cihaz içi konuşma tanıma (\(s.locale == "tr-TR" ? "Türkçe" : "İngilizce"))", ok: s.ready,
                            detail: s.ready ? "Hazır, çevrimdışı" : "Eksik: Ayarlar → Genel → Klavye → Dikte'yi açın ve klavyelere \(s.locale == "tr-TR" ? "Türkçe" : "English (US)") ekleyin. iPhone dil dosyasını kendisi indirir.") { EmptyView() }
                    }
                    row("Çeviri dil paketi (Türkçe ⇄ İngilizce)", ok: transReady,
                        detail: transText) {
                        Button("İndir") {
                            transConfig = .init(source: Translator.tr, target: Translator.en)
                        }
                    }
                    row("Cevap üretim modeli", ok: model.state == .ready, detail: modelText) {
                        Button("İndir") { model.download() }
                            .disabled({ if case .downloading = model.state { return true }; return false }())
                    }
                    row("Seslendirme", ok: !SpeechOutput.voices(.tr).isEmpty && !SpeechOutput.voices(.en).isEmpty,
                        detail: "Türkçe: \(SpeechOutput.voices(.tr).count) ses · İngilizce: \(SpeechOutput.voices(.en).count) ses (iPhone'daki hazır sesler)") { EmptyView() }

                    Text("Kamera izni, Kamera ilk açıldığında istenir. Konuşmalar, kamera görüntüleri ve pratik verileri sunucuya gönderilmez.")
                        .font(.footnote).foregroundStyle(theme.onBg.opacity(0.75))

                    if !embedded {
                        Button {
                            settings.setupComplete = true
                            ConversationController.shared.startIfAllowed()
                        } label: {
                            Text(essentialsReady ? "Kurulumu Tamamla" : "Eksiklerle Devam Et")
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(theme.accent, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(theme.onAccent).font(.headline)
                        }
                        .disabled(!micOK || !speechAuthOK)
                        if !essentialsReady {
                            Text("Eksik kaynaklar tamamlanana kadar ilgili özellikler çalışmaz ve ekranda belirtilir.")
                                .font(.footnote).foregroundStyle(theme.onBg.opacity(0.75))
                        }
                    }
                }
                .padding()
            }
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle(embedded ? "Kurulum Durumu" : "")
            .navigationBarTitleDisplayMode(.inline)
        }
        .translationTask(transConfig) { session in
            try? await session.prepareTranslation()
            transConfig2 = .init(source: Translator.en, target: Translator.tr)
            await refreshAsync()
        }
        .translationTask(transConfig2) { session in
            try? await session.prepareTranslation()
            await refreshAsync()
        }
        .task { refresh() }
    }

    private var transReady: Bool { trans?.trEn == .installed && trans?.enTr == .installed }
    private var transText: String {
        guard let trans else { return "Kontrol ediliyor…" }
        if transReady { return "Kurulu, çevrimdışı" }
        if trans.trEn == .unsupported { return "Bu cihazda desteklenmiyor" }
        return "İndirilmedi (yaklaşık 100–200 MB)"
    }
    private var modelText: String {
        switch model.state {
        case .ready: "\(model.info.name) · \(model.info.license) · kurulu"
        case .missing: "\(model.info.name) · \(model.info.license) · ~1,1 GB, indirilmedi"
        case .downloading(let p): "İndiriliyor %\(Int(p * 100))"
        case .failed(let e): "İndirme hatası: \(e)"
        }
    }
    private var essentialsReady: Bool {
        micOK && speechAuthOK && onDevice.allSatisfy(\.ready) && transReady && model.state == .ready
    }

    private func row<B: View>(_ title: String, ok: Bool, detail: String, @ViewBuilder action: () -> B) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : theme.accent).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).opacity(0.8)
            }
            Spacer()
            if !ok { action().buttonStyle(.borderedProminent).tint(theme.accent).foregroundStyle(theme.onAccent) }
        }
        .foregroundStyle(theme.onCard)
        .padding()
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func requestMic() async {
        micOK = await AVAudioApplication.requestRecordPermission()
    }

    private func refresh() { Task { await refreshAsync() } }

    private func refreshAsync() async {
        micOK = AVAudioApplication.shared.recordPermission == .granted
        speechAuthOK = SFSpeechAuthorized()
        onDevice = ListeningEngine.onDeviceStatus()
        trans = await Translator.status()
        model.refresh()
    }
}

private func SFSpeechAuthorized() -> Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
