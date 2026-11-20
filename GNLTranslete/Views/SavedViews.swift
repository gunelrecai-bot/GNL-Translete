import SwiftUI
import SwiftData

// MARK: Kaydet → Klasör Seç
struct FolderPickerView: View {
    let english: String
    let turkish: String
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.createdAt) private var folders: [Folder]
    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading) {
                        Text(english).font(.headline)
                        Text(turkish).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section("Klasör Seç") {
                    Button { showNew = true } label: { Label("Yeni Klasör", systemImage: "folder.badge.plus") }
                    ForEach(folders) { f in
                        Button { save(to: f) } label: {
                            HStack { Label(f.name, systemImage: "folder"); Spacer(); Text("\(f.phrases.filter { !$0.trashed }.count)").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Kaydet").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } } }
            .alert("Yeni Klasör", isPresented: $showNew) {
                TextField("Klasör adı", text: $newName)
                Button("Oluştur ve Kaydet") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    let f = Folder(name: n)
                    ctx.insert(f)
                    save(to: f)
                }
                Button("Vazgeç", role: .cancel) {}
            }
        }
    }

    private func save(to f: Folder) {
        let p = SavedPhrase(english: english, turkish: turkish, folder: f)
        ctx.insert(p)
        try? ctx.save()
        dismiss()
    }
}

// MARK: Menü → Kaydedilenler
struct SavedFoldersView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Folder.createdAt) private var folders: [Folder]
    @Query private var allPhrases: [SavedPhrase]
    @State private var search = ""
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        List {
            if search.isEmpty {
                ForEach(folders) { f in
                    NavigationLink { FolderDetailView(folder: f) } label: {
                        HStack {
                            Label(f.name, systemImage: "folder")
                            Spacer()
                            let n = f.phrases.filter { !$0.trashed }.count
                            let s = f.phrases.filter { !$0.trashed && $0.struggling }.count
                            Text(s > 0 ? "\(n) · \(s) zor" : "\(n)").foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.forEach { ctx.delete(folders[$0]) }; try? ctx.save() }
                if folders.isEmpty { Text("Henüz kayıt yok. Sohbet kartındaki Kaydet ile cümle ekleyebilirsin.").foregroundStyle(.secondary) }
            } else {
                let q = search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr"))
                let hits = allPhrases.filter { p in
                    !p.trashed && (p.english.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q) ||
                                   p.turkish.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr")).contains(q))
                }
                ForEach(hits) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.english).font(.headline)
                        Text(p.turkish).font(.subheadline)
                        Label(p.folder?.name ?? "-", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if hits.isEmpty { Text("Sonuç yok").foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $search, prompt: "Türkçe veya İngilizce ara")
        .navigationTitle("Kaydedilenler")
        .toolbar { Button { showNew = true } label: { Image(systemName: "folder.badge.plus") } }
        .alert("Yeni Klasör", isPresented: $showNew) {
            TextField("Klasör adı", text: $newName)
            Button("Oluştur") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { ctx.insert(Folder(name: n)); try? ctx.save() }
                newName = ""
            }
            Button("Vazgeç", role: .cancel) {}
        }
    }
}

struct FolderDetailView: View {
    @Bindable var folder: Folder
    @Environment(\.modelContext) private var ctx
    @State private var editing: SavedPhrase?
    @State private var pronounce: SavedPhrase?
    @State private var undoItem: SavedPhrase?
    @State private var practiceMode: PracticeLaunch?
    @State private var askResume = false

    private var phrases: [SavedPhrase] { folder.phrases.filter { !$0.trashed }.sorted { $0.createdAt < $1.createdAt } }

    var body: some View {
        List {
            Section {
                Button { startPractice(onlyStruggling: false) } label: { Label("Pratik Yap", systemImage: "graduationcap") }
                    .disabled(phrases.isEmpty)
                Button { startPractice(onlyStruggling: true) } label: { Label("Zorlandıklarımı Çalış", systemImage: "flame") }
                    .disabled(!phrases.contains { $0.struggling })
            }
            Section("Cümleler") {
                ForEach(phrases) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(p.english).font(.headline)
                            if p.struggling { Image(systemName: "flame.fill").foregroundStyle(.orange).font(.caption) }
                        }
                        Text(p.turkish).font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            Button("Dinle") { speak(p.english, 1.0) }
                            Button("Yavaş") { speak(p.english, 0.7) }
                            Button("Telaffuzumu Kontrol Et") { pronounce = p }
                        }
                        .font(.caption.weight(.semibold)).buttonStyle(.borderless)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { trash(p) } label: { Label("Sil", systemImage: "trash") }
                        Button { editing = p } label: { Label("Düzenle", systemImage: "pencil") }.tint(.blue)
                    }
                }
            }
        }
        .navigationTitle(folder.name)
        .overlay(alignment: .bottom) {
            if let u = undoItem {
                HStack {
                    Text("Cümle silindi")
                    Spacer()
                    Button("Geri Al") { u.trashed = false; try? ctx.save(); undoItem = nil }.bold()
                }
                .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
                .transition(.move(edge: .bottom))
            }
        }
        .sheet(item: $editing) { p in EditPhraseView(phrase: p) }
        .sheet(item: $pronounce) { p in PronunciationView(phrase: p) }
        .navigationDestination(item: $practiceMode) { l in PracticeView(folder: folder, launch: l) }
        .confirmationDialog("Yarım kalan bir tur var", isPresented: $askResume, titleVisibility: .visible) {
            Button("Kaldığım Yerden Devam Et") { practiceMode = PracticeLaunch(resume: true, onlyStruggling: folder.practiceState?.onlyStruggling ?? false) }
            Button("Yeni Tur Başlat") { folder.practiceState = nil; practiceMode = PracticeLaunch(resume: false, onlyStruggling: pendingOnlyStruggling) }
            Button("Vazgeç", role: .cancel) {}
        }
    }

    @State private var pendingOnlyStruggling = false

    private func startPractice(onlyStruggling: Bool) {
        pendingOnlyStruggling = onlyStruggling
        if folder.practiceState != nil { askResume = true }
        else { practiceMode = PracticeLaunch(resume: false, onlyStruggling: onlyStruggling) }
    }

    /// Sil: hemen listeden çıkar; kısa süre Geri Al. Pratik durumu korunduğu için geri yüklenir.
    private func trash(_ p: SavedPhrase) {
        p.trashed = true
        try? ctx.save()
        withAnimation { undoItem = p }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if undoItem?.id == p.id {
                withAnimation { undoItem = nil }
                if p.trashed { ctx.delete(p); try? ctx.save() }
            }
        }
    }

    private func speak(_ t: String, _ rate: Float) {
        SpeechOutput.shared.enqueue(.init(text: t, lang: .en, rateFactor: rate, generation: Int.max, publicSpeaker: false))
    }
}

struct PracticeLaunch: Hashable, Identifiable {
    var id: String { "\(resume)-\(onlyStruggling)" }
    let resume: Bool
    let onlyStruggling: Bool
}

struct EditPhraseView: View {
    @Bindable var phrase: SavedPhrase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @State private var en = ""
    @State private var tr = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("İngilizce") { TextField("İngilizce", text: $en, axis: .vertical) }
                Section("Türkçe") { TextField("Türkçe", text: $tr, axis: .vertical) }
            }
            .navigationTitle("Düzenle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") { phrase.english = en; phrase.turkish = tr; try? ctx.save(); dismiss() }
                        .disabled(en.trimmingCharacters(in: .whitespaces).isEmpty || tr.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { en = phrase.english; tr = phrase.turkish }
        }
    }
}

struct PronunciationView: View {
    let phrase: SavedPhrase
    @Environment(\.dismiss) private var dismiss
    @State private var one = OneShotListener()
    @State private var listening = false
    @State private var feedback: PronunciationFeedback?
    @State private var showDetails = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(phrase.english).font(.title2.bold()).multilineTextAlignment(.center)
                Text(phrase.turkish).foregroundStyle(.secondary)
                Button { Task { await check() } } label: {
                    Label(listening ? "Dinliyorum…" : "Telaffuzumu Kontrol Et", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity).padding()
                }
                .buttonStyle(.borderedProminent).disabled(listening)

                if let f = feedback {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(f.short).font(.headline)
                        if showDetails { Text(f.details).font(.subheadline) }
                        HStack {
                            Button(showDetails ? "Gizle" : "Ayrıntılar") { showDetails.toggle() }
                            Spacer()
                            Button("Geri Bildirimi Dinle") {
                                SpeechOutput.shared.enqueue(.init(text: f.short, lang: .tr, rateFactor: nil, generation: Int.max, publicSpeaker: false))
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Telaffuz").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } } }
        }
        .onDisappear { one.cancel() }
    }

    private func check() async {
        listening = true; feedback = nil; showDetails = false
        let heard = await one.listen(locale: "en-US")
        listening = false
        feedback = SpeechCompare.pronunciation(target: phrase.english, heard: heard)
    }
}
