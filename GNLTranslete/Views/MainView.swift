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
            FolderPickerView(english: t.reply, turkish: t.replyTR)
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
            Text("GNL-Canlı Çeviri").font(.title2.bold()).foregroundStyle(theme.onBg)
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
                    if convo.turns.isEmpty {
                        Text(convo.listening ? "Dinliyorum… Konuşulanlar burada kart olarak görünecek." : "Dinleme beklemede.")
                            .foregroundStyle(theme.onBg.opacity(0.7)).padding(.top, 40)
                    }
                    ForEach(convo.turns) { t in
                        TurnCard(turn: t, onSave: { saveTarget = t }).id(t.id)
                    }
                    if convo.hearingSpeech || convo.transcribing > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform").symbolEffect(.variableColor, isActive: true)
                            Text(convo.transcribing > 0 ? "Yazıya dökülüyor…" : "Konuşma algılandı…").italic()
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
    private var c: ConversationController { ConversationController.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: turn.isOwnTranslation ? "person.wave.2" : "waveform")
                Text(turn.isOwnTranslation ? "Cümlem" : (turn.heardLanguage == .en ? "İngilizce" : "Türkçe"))
                Spacer()
                if !turn.tone.isEmpty {
                    Label(turn.tone.shortWarning, systemImage: "exclamationmark.bubble")
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.3), in: Capsule())
                }
            }
            .font(.caption.weight(.semibold)).opacity(0.75)

            // 1. satır: duyulan
            Text(turn.heard).font(.title3.weight(.medium))
            // 2. satır: çeviri (italik)
            if !turn.translation.isEmpty {
                Text(turn.translation).font(.body).italic().opacity(0.85)
            }
            // 3. satır (yalnızca İngilizce): doğal İngilizce (italik)
            if turn.heardLanguage == .en && !turn.isOwnTranslation {
                if turn.naturalPending {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Doğal İngilizcesi hazırlanıyor…").font(.footnote).italic() }.opacity(0.7)
                } else if !turn.natural.isEmpty {
                    Label { Text(turn.natural).italic() } icon: { Image(systemName: "checkmark.seal") }
                        .font(.body).foregroundStyle(theme.onCard)
                }
            }

            // Düğmeler
            if !turn.isOwnTranslation {
                HStack(spacing: 8) {
                    small(turn.heardLanguage == .tr ? "Çeviriyi Dinle" : "Doğal İngilizceyi Dinle", "speaker.wave.2.fill", primary: false) {
                        c.speakEnglishLine(of: turn.id)
                    }
                    .disabled(turn.heardLanguage == .tr ? turn.translation.isEmpty : turn.naturalPending)
                    small(turn.replying ? "Hazırlanıyor…" : (turn.reply.isEmpty ? "Cevap Ver" : "Yeni Cevap"), "arrowshape.turn.up.left.fill", primary: true) {
                        Task { await c.reply(to: turn.id) }
                    }
                    .disabled(turn.replying)
                }
            }

            // Son satır: cevap (italik)
            if !turn.reply.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.reply).font(.title3).italic()
                    if !turn.replyTR.isEmpty { Text(turn.replyTR).font(.footnote).opacity(0.8) }
                    HStack(spacing: 16) {
                        Button { c.replay(turn.reply, slow: false) } label: { Label("Tekrar Dinle", systemImage: "play.fill") }
                        Button { c.replay(turn.reply, slow: true) } label: { Label("Yavaş", systemImage: "tortoise.fill") }
                        Button { onSave() } label: { Label("Kaydet", systemImage: "bookmark") }
                    }
                    .font(.footnote.weight(.semibold)).buttonStyle(.borderless).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(theme.onAccent)
            }
            if !turn.status.isEmpty {
                Text(turn.status).font(.footnote).opacity(0.75)
            }
        }
        .foregroundStyle(theme.onCard)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card.opacity(0.95), in: RoundedRectangle(cornerRadius: 20))
    }

    private func small(_ t: String, _ icon: String, primary: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Label(t, systemImage: icon).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(primary ? theme.accent : Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(primary ? theme.onAccent : theme.onCard)
        }
    }
}
