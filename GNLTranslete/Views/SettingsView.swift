import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        List {
            NavigationLink { AppearanceSettingsView() } label: { Label("Görünüm", systemImage: "paintpalette") }
            NavigationLink { VoiceSettingsView() } label: { Label("Ses ve Konuşma", systemImage: "speaker.wave.2") }
            ModelTierSection()
            Section {
                Toggle("Hafif mod (önerilen)", isOn: $s.lightMode)
            } header: { Text("Performans") } footer: {
                Text("Açıkken 3. satır (doğal İngilizce) yalnızca Doğal İngilizceyi Dinle'ye basınca üretilir; telefon daha az ısınır ve yavaşlamaz.")
            }
            Section {
                Toggle("İngilizce sözlerin Türkçesini kulaklıktan otomatik oku", isOn: $s.autoReadTranslation)
            } footer: {
                Text("Kapalıyken kulaklığa yalnızca bastığın düğmelerin sesi gelir.")
            }
            Section("Ana Ekrana Dönünce") {
                Picker("Ana Ekrana Dönünce", selection: $s.resumeBehavior) {
                    ForEach(ResumeBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
                Text("Kamera veya Kaydedilenler kapanınca dinleme nasıl sürsün. Bilerek Duraklat'a bastıysan Devam Et'e dokunana kadar beklenir.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Ayarlar")
    }
}

// MARK: Görünüm
struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var s = settings
        List {
            Section {
                PreviewCard(palette: settings.palette(for: scheme))
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section {
                Picker("Tema kaynağı", selection: $s.themeSource) {
                    ForEach(ThemeSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            switch settings.themeSource {
            case .preset:
                Section("Hazır Temalar") {
                    ForEach(Themes.all) { t in
                        Button { settings.presetID = t.id } label: { themeRow(t, selected: settings.presetID == t.id) }
                    }
                }
            case .custom:
                Section("Kendi Temam") {
                    ColorPicker("Zemin", selection: binding(\.background), supportsOpacity: false)
                    ColorPicker("Sohbet kartı", selection: binding(\.card), supportsOpacity: false)
                    ColorPicker("Sen söyle vurgusu", selection: binding(\.accent), supportsOpacity: false)
                    Text("Yazı rengi, okunaklı kalması için arka plana göre otomatik seçilir.").font(.footnote).foregroundStyle(.secondary)
                }
            case .system:
                Section("Açık görünümde") {
                    Picker("Açık", selection: $s.lightThemeID) { ForEach(Themes.all) { Text($0.name).tag($0.id) } }
                }
                Section("Koyu görünümde") {
                    Picker("Koyu", selection: $s.darkThemeID) { ForEach(Themes.all) { Text($0.name).tag($0.id) } }
                }
            }
            Section { Text("Uygulama simgesi kendi renklerini korur.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Görünüm")
    }

    private func binding(_ kp: WritableKeyPath<ThemePalette, RGB>) -> Binding<Color> {
        Binding(get: { settings.customPalette[keyPath: kp].color },
                set: { settings.customPalette[keyPath: kp] = RGB(color: $0) })
    }

    private func themeRow(_ t: ThemeDef, selected: Bool) -> some View {
        HStack {
            HStack(spacing: 0) {
                t.palette.background.color; t.palette.card.color; t.palette.accent.color
            }
            .frame(width: 66, height: 26).clipShape(RoundedRectangle(cornerRadius: 6))
            Text(t.name).foregroundStyle(.primary)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }
}

struct PreviewCard: View {
    let palette: ThemePalette
    var body: some View {
        let th = ResolvedTheme(p: palette)
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duyulan").font(.caption.bold()); Text("Would you like a window seat?")
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(th.card, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(th.onCard)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sen söyle").font(.caption.bold()); Text("Yes, please. That would be great.")
                Text("Evet, lütfen. Harika olur.").font(.caption).opacity(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(th.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(th.onAccent)
        }
        .padding(14)
        .background(th.bg, in: RoundedRectangle(cornerRadius: 18))
        .animation(.easeInOut, value: palette)
    }
}

// MARK: Ses ve Konuşma
struct VoiceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var phase
    @State private var trVoices: [AVSpeechSynthesisVoice] = []
    @State private var enVoices: [AVSpeechSynthesisVoice] = []
    @State private var previewNote: String?

    var body: some View {
        @Bindable var s = settings
        List {
            quickPick(.tr, title: "Türkçe ses", selection: $s.trVoiceID)
            quickPick(.en, title: "İngilizce ses (cevaplar)", selection: $s.enVoiceID)
            voiceSection(title: "Türkçe çeviri sesi", lang: .tr, voices: trVoices, selection: $s.trVoiceID,
                         sample: "Merhaba, çeviriler bu sesle okunacak.")
            Section("Türkçe hız") {
                Picker("Türkçe hız", selection: $s.trSpeed) { ForEach(SpeechSpeed.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            voiceSection(title: "İngilizce cevap / pratik sesi", lang: .en, voices: enVoices, selection: $s.enVoiceID,
                         sample: "Hello! Your English suggestions will sound like this.")
            Section("İngilizce hız") {
                Picker("İngilizce hız", selection: $s.enSpeed) { ForEach(SpeechSpeed.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Text("Tekrar Dinle normal hızda, Yavaş Dinle daha yavaş okur; bu ayarı değiştirmez.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Ek ses indirme") {
                Text("iPhone Ayarlar → Erişilebilirlik → Okunan İçerik → Sesler → Türkçe veya İngilizce → istediğin sesi indir. Uygulamaya dönünce liste kendiliğinden yenilenir. Hazır sesler yeterliyse indirme gerekmez.")
                    .font(.footnote)
                Button("iPhone Ayarlarını Aç") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
            }
        }
        .navigationTitle("Ses ve Konuşma")
        .onAppear(perform: reload)
        .onChange(of: phase) { _, p in if p == .active { reload() } }
    }

    @ViewBuilder
    private func quickPick(_ lang: SpeechLang, title: String, selection: Binding<String?>) -> some View {
        let female = SpeechOutput.best(lang, gender: .female)
        let male = SpeechOutput.best(lang, gender: .male)
        let current = SpeechOutput.shared.resolvedVoice(lang).voice
        Section(title) {
            HStack(spacing: 10) {
                pickButton("Doğal Kadın", voice: female, selected: current?.identifier == female?.identifier) { selection.wrappedValue = female?.identifier }
                pickButton("Doğal Erkek", voice: male, selected: current?.identifier == male?.identifier) { selection.wrappedValue = male?.identifier }
            }
            if let v = current, v.quality == .default {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Şu anki ses \"Standart\" kalitede, bu yüzden mekanik duyuluyor.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Doğal ses için bir kez indir (Wi-Fi, birkaç yüz MB):")
                    Text("iPhone Ayarlar → Erişilebilirlik → Okunan İçerik → Sesler → \(lang == .tr ? "Türkçe" : "English") → adının yanında **Premium** ya da **Gelişmiş** yazan bir kadın ve bir erkek sesi seç → indir.")
                    Text("Uygulamaya dönünce burada otomatik görünür ve Doğal Kadın / Doğal Erkek onları seçer.").foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
    }

    private func pickButton(_ title: String, voice: AVSpeechSynthesisVoice?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(voice.map { "\($0.name) · \(qualityName($0))" } ?? "Yok").font(.caption2).opacity(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(voice == nil)
    }

    private func qualityName(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality { case .premium: "Premium"; case .enhanced: "Gelişmiş"; default: "Standart" }
    }

    private func reload() {
        trVoices = SpeechOutput.voices(.tr)
        enVoices = SpeechOutput.voices(.en)
    }

    private func voiceSection(title: String, lang: SpeechLang, voices: [AVSpeechSynthesisVoice], selection: Binding<String?>, sample: String) -> some View {
        let resolved = SpeechOutput.shared.resolvedVoice(lang)
        return Section(title) {
            if resolved.fellBack {
                Label("Seçili ses artık yok; \(resolved.voice?.name ?? "yerel ses") kullanılıyor.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(voices, id: \.identifier) { v in
                Button {
                    selection.wrappedValue = v.identifier
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(v.name).foregroundStyle(.primary)
                            Text(describe(v)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if resolved.voice?.identifier == v.identifier { Image(systemName: "checkmark") }
                    }
                }
            }
            Button("Sesi Önizle") {
                if AudioRoute.shared.headphonesActive {
                    previewNote = nil
                    SpeechOutput.shared.enqueue(.init(text: sample, lang: lang, rateFactor: nil, generation: Int.max, publicSpeaker: false))
                } else {
                    previewNote = "Önizleme kulaklıktan çalar. AirPods'u takıp tekrar dene."
                }
            }
            if let n = previewNote { Text(n).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func describe(_ v: AVSpeechSynthesisVoice) -> String {
        let gender: String = switch v.gender { case .female: "Kadın"; case .male: "Erkek"; default: "Belirtilmemiş" }
        let region: String = v.language == "en-US" ? "Amerikan" : v.language == "en-GB" ? "Britanya" : v.language
        let q: String = switch v.quality { case .premium: "Premium"; case .enhanced: "Gelişmiş"; default: "Standart" }
        return "\(gender) · \(region) · \(q)"
    }
}


// MARK: Cevap Modeli (Hızlı / Kaliteli)
struct ModelTierSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var store = ModelStore.shared

    var body: some View {
        @Bindable var s = settings
        Section {
            Picker("Cevap modeli", selection: $s.modelTier) {
                ForEach(ModelTier.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ForEach(ModelTier.allCases, id: \.self) { t in
                let info = LLMModelInfo.of(t)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(t.title): \(info.name)").font(.subheadline.weight(.semibold))
                        Spacer()
                        switch store.states[t] ?? .missing {
                        case .ready:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .downloading(let p):
                            Text("%\(Int(p * 100))").font(.footnote.monospacedDigit())
                        case .missing, .failed:
                            Button("İndir") { store.download(t) }.buttonStyle(.bordered)
                        }
                    }
                    Text("\(info.note) · Lisans: \(info.license)").font(.caption).foregroundStyle(.secondary)
                    if case .failed(let e) = store.states[t] ?? .missing {
                        Text("İndirme hatası: \(e)").font(.caption).foregroundStyle(.red)
                    }
                }
                .swipeActions {
                    if store.states[t] == .ready && store.activeTier != t {
                        Button(role: .destructive) { store.delete(t) } label: { Label("Sil", systemImage: "trash") }
                    }
                }
            }
            if store.activeTier != settings.modelTier {
                Text("\(settings.modelTier.title) model henüz indirilmedi; şimdilik \(store.activeTier.title) model kullanılıyor.")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Cevap Modeli")
        } footer: {
            Text("İndirme Wi-Fi'de yapılmalı ve bitene kadar uygulama açık kalmalı. Kullanılmayan modeli sola kaydırıp silebilirsin.")
        }
        .onAppear { store.refresh() }
    }
}
