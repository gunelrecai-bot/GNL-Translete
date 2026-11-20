import SwiftUI
import SwiftData

struct PracticeView: View {
    @Bindable var folder: Folder
    let launch: PracticeLaunch
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var state: PracticeState?
    @State private var countChoice = 10       // 5, 10, 0 = Tümü
    @State private var shuffled = false
    @State private var revealed = false
    @State private var answerHeard: String?
    @State private var verdict: SpeechCompare.MeaningVerdict?
    @State private var hintShown = false
    @State private var listening = false
    @State private var finished = false
    @State private var one = OneShotListener()

    private var pool: [SavedPhrase] {
        folder.phrases.filter { !$0.trashed && (!launch.onlyStruggling || $0.struggling) }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        Group {
            if finished, let s = state { summary(s) }
            else if let s = state, let p = current(s) { card(s, p) }
            else { startScreen }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.bg.ignoresSafeArea())
        .navigationTitle(launch.onlyStruggling ? "Zorlandıklarım" : "Pratik Yap")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if launch.resume, let saved = folder.practiceState { state = saved }
        }
        .onDisappear { one.cancel() }
    }

    // MARK: Başlangıç
    private var startScreen: some View {
        VStack(spacing: 18) {
            Text("\(pool.count) cümle").font(.headline).foregroundStyle(theme.onBg)
            Picker("Adet", selection: $countChoice) {
                Text("5 Cümle").tag(5); Text("10 Cümle").tag(10); Text("Tümü").tag(0)
            }.pickerStyle(.segmented)
            Picker("Sıra", selection: $shuffled) {
                Text("Sırayla").tag(false); Text("Karışık").tag(true)
            }.pickerStyle(.segmented)
            bigButton("Başla", primary: true) { begin() }.disabled(pool.isEmpty)
        }
    }

    private func begin() {
        var list = pool
        if shuffled { list.shuffle() }
        if countChoice > 0 { list = Array(list.prefix(countChoice)) }
        let s = PracticeState(order: list.map(\.id), onlyStruggling: launch.onlyStruggling)
        state = s
        persist()
        resetCard()
    }

    private func current(_ s: PracticeState) -> SavedPhrase? {
        let id: UUID?
        if s.inSecondPass { id = s.secondPassIndex < s.skippedOnce.count ? s.skippedOnce[s.secondPassIndex] : nil }
        else { id = s.index < s.order.count ? s.order[s.index] : nil }
        guard let id else { return nil }
        return folder.phrases.first { $0.id == id && !$0.trashed }
    }

    // MARK: Kart
    private func card(_ s: PracticeState, _ p: SavedPhrase) -> some View {
        let total = s.inSecondPass ? s.skippedOnce.count : s.order.count
        let pos = (s.inSecondPass ? s.secondPassIndex : s.index) + 1
        return ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Text(s.inSecondPass ? "Atlananlar \(pos) / \(total)" : "\(pos) / \(total)").font(.headline)
                    ProgressView(value: Double(pos), total: Double(max(total, 1))).tint(theme.accent)
                }
                .foregroundStyle(theme.onBg)

                VStack(spacing: 10) {
                    Text(p.turkish).font(.title2.bold()).multilineTextAlignment(.center)
                    if hintShown && !revealed {
                        Text("İpucu: " + p.english.split(separator: " ").prefix(2).joined(separator: " ") + " …").font(.subheadline)
                    }
                    if revealed {
                        Divider()
                        Text(p.english).font(.title3)
                        HStack {
                            Button("Tekrar Dinle") { speak(p.english, 1.0) }
                            Button("Yavaş Dinle") { speak(p.english, 0.7) }
                        }.font(.footnote.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity).padding(22)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 22))
                .foregroundStyle(theme.onCard)

                if let a = answerHeard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Senin cevabın: \(a)")
                        Text("Kayıtlı örnek: \(p.english)")
                        switch verdict {
                        case .same?: Label("Aynı anlam, kabul edildi.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .different(let why)?: Label(why, systemImage: "info.circle").foregroundStyle(.orange)
                        case nil: EmptyView()
                        }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(theme.chrome, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(theme.onBg)
                }

                if !revealed {
                    bigButton(listening ? "Dinliyorum…" : "Cevabımı Dinle", primary: true) { Task { await listenAnswer(p) } }
                        .disabled(listening)
                    if case .different? = verdict {
                        bigButton("İpucuyla Tekrar Dene", primary: false) { hintShown = true; answerHeard = nil; verdict = nil }
                    }
                    bigButton("Cevabı Göster", primary: false) { revealed = true; speak(p.english, 1.0) }
                }
                HStack(spacing: 10) {
                    bigButton("Bildim", primary: true) { known(p) }
                    bigButton("Tekrar Etmeliyim", primary: false) { needRepeat(p) }
                }
                Button("Atla") { skip(p) }.underline().foregroundStyle(theme.onBg)
            }
        }
    }

    private func listenAnswer(_ p: SavedPhrase) async {
        listening = true
        let heard = await one.listen(locale: "en-US")
        listening = false
        guard let h = heard?.text, !h.isEmpty else { answerHeard = "(duyulamadı)"; verdict = nil; return }
        answerHeard = h
        verdict = SpeechCompare.meaning(answer: h, expected: p.english)
    }

    // MARK: Kararlar
    private func known(_ p: SavedPhrase) {
        guard var s = state else { return }
        s.known += 1
        if p.lastKnownSessionID != s.sessionID {
            p.knownStreak += 1
            p.lastKnownSessionID = s.sessionID
        }
        // iki ayrı turda Bildim → Zorlandıklarım'dan çıkar, klasörde kalır
        if p.struggling && p.knownStreak >= 2 { p.struggling = false }
        state = s
        advance()
    }

    private func needRepeat(_ p: SavedPhrase) {
        guard var s = state else { return }
        s.repeatNeeded += 1
        p.knownStreak = 0          // arada Tekrar Etmeliyim → Bildim sayacı sıfırlanır
        p.struggling = true
        state = s
        advance()
    }

    private func skip(_ p: SavedPhrase) {
        guard var s = state else { return }
        if s.inSecondPass {
            s.skipped += 1          // ikinci atlayış: Atlandı + Zorlandıklarım
            p.struggling = true
            p.knownStreak = 0
        } else if !s.skippedOnce.contains(p.id) {
            s.skippedOnce.append(p.id)   // turun sonunda bir kez daha
        }
        state = s
        advance()
    }

    private func advance() {
        guard var s = state else { return }
        if s.inSecondPass { s.secondPassIndex += 1 } else { s.index += 1 }
        if !s.inSecondPass && s.index >= s.order.count {
            // ilk geçişte "Bildim/Tekrar" denmiş atlananları ikinci geçişten çıkar
            s.inSecondPass = true
        }
        state = s
        if s.inSecondPass && s.secondPassIndex >= s.skippedOnce.count {
            finished = true
            folder.practiceState = nil
        } else {
            persist()
        }
        try? ctx.save()
        resetCard()
    }

    private func persist() { folder.practiceState = state; try? ctx.save() }

    private func resetCard() {
        revealed = false; answerHeard = nil; verdict = nil; hintShown = false
    }

    // MARK: Özet
    private func summary(_ s: PracticeState) -> some View {
        VStack(spacing: 14) {
            Text("Tur bitti").font(.title.bold())
            let studied = s.order.count
            Group {
                Text("Çalışılan cümle: \(studied)")
                Text("Bildim: \(s.known)")
                Text("Tekrar Etmeliyim: \(s.repeatNeeded)")
                Text("Atlandı: \(s.skipped)")
            }.font(.title3)
            bigButton("Zorlandıklarımı Tekrar Et", primary: true) {
                let list = folder.phrases.filter { !$0.trashed && $0.struggling }
                guard !list.isEmpty else { return }
                state = PracticeState(order: list.map(\.id), onlyStruggling: true)
                finished = false
                persist(); resetCard()
            }
            .disabled(!folder.phrases.contains { !$0.trashed && $0.struggling })
            bigButton("Klasöre Dön", primary: false) { dismiss() }
        }
        .foregroundStyle(theme.onBg)
    }

    private func bigButton(_ t: String, primary: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(primary ? theme.accent : theme.card, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(primary ? theme.onAccent : theme.onCard)
        }
    }

    private func speak(_ t: String, _ r: Float) {
        SpeechOutput.shared.enqueue(.init(text: t, lang: .en, rateFactor: r, generation: Int.max, publicSpeaker: false))
    }
}
