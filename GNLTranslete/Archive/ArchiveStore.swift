import Foundation

struct ArchiveEntry: Codable, Identifiable, Hashable {
    var id: String { kind.rawValue + ":" + en }
    var kind: Kind = .word
    let en: String
    let tr: String
    let category: String
    var note: String?
    /// "kaba", "küfürlü", "şakacı", "alaycı" gibi kullanım etiketleri
    var tags: [String]?

    enum Kind: String, Codable { case word, sentence, pattern
        var title: String { switch self { case .word: "Kelime"; case .sentence: "Cümle"; case .pattern: "Kalıp" } }
    }
    enum CodingKeys: String, CodingKey { case en, tr, category, note, tags }
}

/// Çevrimdışı Hazır Arşiv: 5.000 kelime + 3.000 cümle + 1.000 kalıp hedefi.
final class ArchiveStore {
    static let shared = ArchiveStore()
    static let targets: [(ArchiveEntry.Kind, Int)] = [(.word, 5000), (.sentence, 3000), (.pattern, 1000)]

    private(set) var entries: [ArchiveEntry] = []
    private(set) var report = ValidationReport()

    struct ValidationReport {
        var counts: [ArchiveEntry.Kind: Int] = [:]
        var empty = 0
        var duplicates = 0
        var total: Int { counts.values.reduce(0, +) }
        var isComplete: Bool {
            empty == 0 && duplicates == 0 && ArchiveStore.targets.allSatisfy { counts[$0.0] == $0.1 }
        }
        var summary: String {
            let parts = ArchiveStore.targets.map { "\($0.0.title): \(counts[$0.0] ?? 0)/\($0.1)" }
            var s = parts.joined(separator: " · ") + " · Toplam: \(total)/9000"
            if empty > 0 { s += " · Boş kayıt: \(empty)" }
            if duplicates > 0 { s += " · Yinelenen: \(duplicates)" }
            return s
        }
    }

    private struct FileShape: Codable {
        var words: [ArchiveEntry]; var sentences: [ArchiveEntry]; var patterns: [ArchiveEntry]
    }

    private init() { load() }

    func load() {
        guard let url = Bundle.main.url(forResource: "archive", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(FileShape.self, from: data) else { return }
        func tag(_ a: [ArchiveEntry], _ k: ArchiveEntry.Kind) -> [ArchiveEntry] { a.map { var e = $0; e.kind = k; return e } }
        entries = tag(f.words, .word) + tag(f.sentences, .sentence) + tag(f.patterns, .pattern)
        report = Self.validate(entries)
    }

    /// Tür adetlerini, boş ve yinelenen kayıtları otomatik doğrular.
    static func validate(_ list: [ArchiveEntry]) -> ValidationReport {
        var r = ValidationReport()
        var seen = Set<String>()
        for e in list {
            r.counts[e.kind, default: 0] += 1
            let en = e.en.trimmingCharacters(in: .whitespaces), tr = e.tr.trimmingCharacters(in: .whitespaces)
            if en.isEmpty || tr.isEmpty || e.category.isEmpty { r.empty += 1 }
            let key = e.kind.rawValue + "|" + en.lowercased()
            if !seen.insert(key).inserted { r.duplicates += 1 }
        }
        return r
    }

    func search(_ q: String, kind: ArchiveEntry.Kind?) -> [ArchiveEntry] {
        let query = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr"))
        return entries.filter { e in
            (kind == nil || e.kind == kind) && (query.isEmpty ||
                e.en.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(query) ||
                e.tr.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr")).contains(query) ||
                e.category.lowercased().contains(query))
        }
    }

    var categories: [String] { Array(Set(entries.map(\.category))).sorted() }
}
