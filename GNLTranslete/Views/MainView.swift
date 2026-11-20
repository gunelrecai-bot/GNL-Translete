import SwiftUI
import SwiftData

struct MainView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @State private var convo = ConversationController.shared
    @State private var route = AudioRoute.shared

    @State private var showMenu = false
    @State private var showTranslateMine = false
    @State private var showCamera = false
    @State private var showHint = false
    @State private var saveTarget: ConversationTurn?

    var body: some View {
        VStack(spacing: 10) {
            header
            modePicker
            statusLine
            cards
            controlsRow
            bottomBar
        }
        .padding(.horizontal, 14)
        .background(theme.bg.ignoresSafeArea())
        .onAppear {
            AudioRoute.shared.configure()
            convo.startIfAllowed()
        }
        .sheet(isPresented: $showMenu) { MenuView() }
        .sheet(isPresented: $showTranslateMine) { TranslateMineView() }
        .sheet(item: $saveTarget) { t in
            FolderPickerView(english: t.suggestion, turkish: t.suggestionTR)
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: { convo.endOverlay() }) {
            CameraTranslateView()
        }
        .alert("Türkçe İpucu", isPresented: $showHint) {
            TextField("Örn: kibarca reddet", text: $convo.hint)
            Button("Tamam") {}
        } message: {
            Text("Bir sonraki cevap önerisini yönlendirir.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("Logo").resizable().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 10))
            Text("GNL-Translete").font(.title2.bold()).foregroundStyle(theme.onBg)
            Spacer()
            Button { showMenu = true } label: {
                Image(systemName: "line.3.horizontal").font(.title2).foregroundStyle(theme.onBg)
            }
            .accessibilityLabel("Menü")
        }
        .padding(.top, 6)
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(ConversationMode.allCases, id: \.self) { m in
                let sel = settings.mode == m
                Button { convo.setMode(m) } label: {
                    Text(m.title).font(.headline)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(sel ? theme.accent : .clear, in: Capsule())
                        .foregroundStyle(sel ? theme.onAccent : theme.onBg.opacity(0.75))
                }
            }
        }
        .padding(4)
        .background(theme.chrome, in: Capsule())
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(convo.listening ? Color.green : (route.headphonesActive ? Color.orange : Color.red)).frame(width: 9, height: 9)
            Text(convo.statusLine).font(.subheadline)
        }
        .foregroundStyle(theme.onBg.opacity(0.9))
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if convo.turns.isEmpty && convo.partial.isEmpty {
                        Text(convo.listening ? "Dinliyorum… Karşındaki kişi konuşmaya başlayabilir." : "Dinleme beklemede.")
                            .foregroundStyle(theme.onBg.opacity(0.7)).padding(.top, 40)
                    }
                    ForEach(convo.turns) { t in
                        TurnCard(turn: t, onSave: { saveTarget = t }).id(t.id)
                    }
                    if !convo.partial.isEmpty {
                        HStack {
                            Image(systemName: "waveform")
                            Text(convo.partial).italic()
                            Spacer()
                        }
                        .padding().foregroundStyle(theme.onCard.opacity(0.8))
                        .background(theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                        .id("partial")
                    }
                    if let e = convo.errorText {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: convo.turns.count) { _, _ in
                if let last = convo.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            Button { convo.togglePause() } label: {
                Label(convo.userPaused ? "Devam Et" : "Duraklat", systemImage: convo.userPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(theme.chrome, in: Capsule())
            }
            Button { showHint = true } label: {
                Label(convo.hint.isEmpty ? "Türkçe İpucu" : "İpucu: \(convo.hint)", systemImage: "lightbulb")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(theme.chrome, in: Capsule())
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(theme.onBg)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            bottomButton("Cümlemi Çevir", icon: "character.bubble", primary: true, enabled: true) { showTranslateMine = true }
            bottomButton("Karşıya Oku", icon: "speaker.wave.2", primary: false, enabled: convo.lastOwnEnglish != nil) { convo.readAloudToOther() }
            bottomButton("Kamera", icon: "camera", primary: false, enabled: true) {
                convo.beginOverlay(); showCamera = true
            }
        }
        .padding(.bottom, 6)
    }

    private func bottomButton(_ title: String, icon: String, primary: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(primary ? theme.accent : theme.chrome, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(primary ? theme.onAccent : theme.onBg)
            .opacity(enabled ? 1 : 0.45)
        }
        .disabled(!enabled)
    }
}

struct TurnCard: View {
    let turn: ConversationTurn
    var onSave: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            if !turn.tone.isEmpty {
                Label(turn.tone.shortWarning, systemImage: "exclamationmark.bubble")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(theme.onCard)
            }
            section(turn.isOwnTranslation ? "Cümlem" : "Duyulan", icon: "waveform",
                    text: turn.heard, note: turn.isOwnTranslation ? nil : turn.heardLanguage.title)
            if !turn.translation.isEmpty {
                section("Çeviri", icon: "character.book.closed", text: turn.translation, note: nil)
            }
            if !turn.englishEquivalent.isEmpty {
                section("Doğal İngilizcesi", icon: "text.quote", text: turn.englishEquivalent, note: nil)
            }
            if !turn.suggestion.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Sen söyle", systemImage: "mic").font(.subheadline.weight(.bold))
                    Text(turn.suggestion).font(.title3)
                    if !turn.suggestionTR.isEmpty {
                        Text(turn.suggestionTR).font(.subheadline).opacity(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(theme.onAccent)

                HStack(spacing: 8) {
                    small("Tekrar Dinle", "play.fill") { ConversationController.shared.replay(turn.suggestion, slow: false) }
                    small("Yavaş Dinle", "tortoise.fill") { ConversationController.shared.replay(turn.suggestion, slow: true) }
                    small("Kaydet", "bookmark") { onSave() }
                }
            }
            if !turn.status.isEmpty {
                HStack { ProgressView().opacity(turn.status.hasSuffix("…") ? 1 : 0); Text(turn.status).font(.footnote); Spacer() }
                    .foregroundStyle(theme.onCard.opacity(0.8))
            }
        }
        .padding(12)
        .background(theme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
    }

    private func section(_ title: String, icon: String, text: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: icon).font(.subheadline.weight(.bold))
                Spacer()
                if let note { Text(note).font(.caption).opacity(0.7) }
            }
            Text(text).font(.title3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(theme.onCard)
    }

    private func small(_ t: String, _ icon: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Label(t, systemImage: icon).font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(theme.onCard)
        }
    }
}
