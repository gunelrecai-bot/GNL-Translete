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
    @State private var whisper = WhisperEngine.shared
    @State private var apple = AppleSpeechSupport.shared
    @State private var checking = false
    @State private var tick = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !embedded {
                        HStack(spacing: 12) {
                            Image("Logo").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading) {
                                Text("GNL-Canlı Çeviri").font(.title2.bold())
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
                    row("Apple konuşma motoru (Türkçe + İngilizce)", ok: apple.isReady, detail: apple.statusText) {
                        if apple.state == .needsAssets || { if case .failed = apple.state { return true }; return false }() {
                            Button("İndir") { Task { await apple.install(); ConversationController.shared.restartListening() } }
                        }
                    }
                    row(apple.isReady ? "Yedek: Whisper (isteğe bağlı)" : "Konuşma tanıma modeli (Whisper)", ok: whisper.state == .ready || whisper.state == .standby, detail: whisperText + (tick < 0 ? "" : "")) {
                        Button("İndir") { Task { await whisper.downloadOnly() } }
                            .disabled({ switch whisper.state { case .downloading, .loading: return true; default: return false } }())
                    }
                    if case .failed = whisper.state {
                        Button("Tekrar Dene") { Task { await whisper.prepare() } }
                            .buttonStyle(.borderedProminent).tint(theme.accent).foregroundStyle(theme.onAccent)
                    }
                    ForEach(onDevice, id: \.locale) { s in
                        row("Yerleşik tanıyıcı (telaffuz + son yedek) (\(s.locale == "tr-TR" ? "Türkçe" : "İngilizce"))", ok: s.ready,
                            detail: s.ready ? "Hazır, çevrimdışı" : "Eksik: Ayarlar → Genel → Klavye → Dikte'yi açın ve klavyelere \(s.locale == "tr-TR" ? "Türkçe" : "English (US)") ekleyin. iPhone dil dosyasını kendisi indirir.") { EmptyView() }
                    }
                    row("Çeviri dil paketi (Türkçe ⇄ İngilizce)", ok: transReady,
                        detail: transText) {
                        Button("İndir") {
                            // ikinci dokunuşta da sistem indirme penceresini yeniden tetikle
                            if transConfig == nil { transConfig = .init(source: Translator.tr, target: Translator.en) }
                            else { transConfig?.invalidate() }
                        }
                    }
                    row("Cevap üretim modeli", ok: model.state == .ready, detail: modelText) {
                        Button("İndir") { model.download() }
                            .disabled({ if case .downloading = model.state { return true }; return false }())
                    }
                    row("Seslendirme", ok: !SpeechOutput.voices(.tr).isEmpty && !SpeechOutput.voices(.en).isEmpty,
                        detail: "Türkçe: \(SpeechOutput.voices(.tr).count) ses · İngilizce: \(SpeechOutput.voices(.en).count) ses (iPhone'daki hazır sesler)") { EmptyView() }

                    Text("Sürüm \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.footnote.bold()).foregroundStyle(theme.onBg.opacity(0.75))
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
        .task {
            // Ayarlar'dan dil indirildiğinde de durum kendiliğinden güncellensin
            while !Task.isCancelled {
                await refreshAsync()
                tick += 1
                try? await Task.sleep(for: .seconds(3))
            }
        }
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
        micOK && speechAuthOK && (apple.isReady || whisper.isDownloaded || onDevice.allSatisfy(\.ready)) && transReady && model.state == .ready
    }
    private var whisperText: String {
        switch whisper.state {
        case .standby: "\(whisper.size == .turbo ? "Turbo" : "Small") indirildi · yedekte bekliyor. Boyut seçimi: Ayarlar → Konuşma Motoru."
        case .ready: "Whisper \(whisper.size == .turbo ? "large-v3 turbo" : "small") · MIT · kurulu, çevrimdışı"
        case .missing: "İsteğe bağlı yedek · \(whisper.approxSize). Yalnızca Apple motoru çalışmazsa devreye girer."
        case .downloading(let p): "İndiriliyor %\(Int(p * 100))"
        case .loading:
            "Hazırlanıyor… \(Int(Date().timeIntervalSince(whisper.loadStarted ?? Date()))) sn · \(whisper.stage). İlk seferde birkaç dakika sürebilir; uygulamadan çıkma."
        case .failed(let e): "Hata: \(e)"
        }
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
        if apple.state == .checking { await apple.check() }
        model.refresh()
    }
}

private func SFSpeechAuthorized() -> Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
