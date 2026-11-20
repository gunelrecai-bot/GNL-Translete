import SwiftUI

/// Menü → Hazır Arşiv (kişisel Kaydedilenler'den ayrı).
struct ArchiveView: View {
    private let store = ArchiveStore.shared
    @State private var query = ""
    @State private var kind: ArchiveEntry.Kind? = nil
    @State private var practicing = false

    var body: some View {
        let results = store.search(query, kind: kind)
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(store.report.isComplete ? "Doğrulandı" : "Arşiv içeriği eksik", systemImage: store.report.isComplete ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(store.report.isComplete ? .green : .orange)
                    Text(store.report.summary).font(.footnote)
                }
                Picker("Tür", selection: $kind) {
                    Text("Tümü").tag(ArchiveEntry.Kind?.none)
                    Text("Kelime").tag(ArchiveEntry.Kind?.some(.word))
                    Text("Cümle").tag(ArchiveEntry.Kind?.some(.sentence))
                    Text("Kalıp").tag(ArchiveEntry.Kind?.some(.pattern))
                }
                .pickerStyle(.segmented)
            }
            Section("\(results.count) kayıt") {
                ForEach(results.prefix(300)) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(e.en).font(.headline)
                            Spacer()
                            Button { speak(e.en, 1.0) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
                            Button { speak(e.en, 0.7) } label: { Image(systemName: "tortoise") }.buttonStyle(.borderless)
                        }
                        Text(e.tr).font(.subheadline)
                        HStack(spacing: 6) {
                            Text(e.category).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.thinMaterial, in: Capsule())
                            ForEach(e.tags ?? [], id: \.self) { t in
                                Text(t).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.25), in: Capsule())
                            }
                        }
                        if let n = e.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if results.count > 300 { Text("Daha fazlası için aramayı daraltın.").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $query, prompt: "Türkçe veya İngilizce ara")
        .navigationTitle("Hazır Arşiv")
        .toolbar {
            if !results.isEmpty {
                NavigationLink { ArchivePracticeView(items: Array(results.shuffled().prefix(10))) } label: { Text("Pratik") }
            }
        }
    }

    private func speak(_ t: String, _ r: Float) {
        SpeechOutput.shared.enqueue(.init(text: t, lang: .en, rateFactor: r, generation: Int.max, publicSpeaker: false))
    }
}

/// Arşivden 10 kayıtlık hızlı pratik: Türkçe gösterilir, kullanıcı İngilizcesini söyler.
struct ArchivePracticeView: View {
    let items: [ArchiveEntry]
    @State private var i = 0
    @State private var revealed = false
    @State private var verdict: String?
    @State private var one = OneShotListener()

    var body: some View {
        VStack(spacing: 18) {
            if i < items.count {
                let e = items[i]
                Text("\(i + 1) / \(items.count)").font(.headline)
                ProgressView(value: Double(i + 1), total: Double(items.count))
                Text(e.tr).font(.title2.bold()).multilineTextAlignment(.center).padding()
                if revealed { Text(e.en).font(.title3) }
                if let v = verdict { Text(v).font(.subheadline) }
                Button("Cevabımı Dinle") {
                    Task {
                        let h = await one.listen(locale: "en-US")
                        if let t = h?.text {
                            switch SpeechCompare.meaning(answer: t, expected: e.en) {
                            case .same: verdict = "Doğru: \(t)"
                            case .different(let why): verdict = "Senin cevabın: \(t)\n\(why)"
                            }
                        } else { verdict = "Duyulamadı" }
                    }
                }.buttonStyle(.borderedProminent)
                Button("Cevabı Göster") { revealed = true; SpeechOutput.shared.enqueue(.init(text: e.en, lang: .en, rateFactor: 1.0, generation: Int.max, publicSpeaker: false)) }
                Button("Sonraki") { i += 1; revealed = false; verdict = nil }
            } else {
                Text("Bitti!").font(.title.bold())
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Arşiv Pratiği")
        .onDisappear { one.cancel() }
    }
}
