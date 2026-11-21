import Foundation
import NaturalLanguage

enum ToneKind: String, Codable, CaseIterable {
    case joke, teasing, sarcasm, slang, rude, profanity, insult, argument, warning, threat, harsh

    var label: String {
        switch self {
        case .joke: "Şaka"
        case .teasing: "İğneleme"
        case .sarcasm: "Alay"
        case .slang: "Argo / abiyane"
        case .rude: "Kaba ifade"
        case .profanity: "Küfür"
        case .insult: "Hakaret"
        case .argument: "Tartışma"
        case .warning: "Sert uyarı"
        case .threat: "Tehdit"
        case .harsh: "Sert ton"
        }
    }
    var severity: Int {
        switch self {
        case .joke, .teasing, .slang: 1
        case .sarcasm, .argument, .rude, .harsh: 2
        case .profanity, .insult, .warning: 3
        case .threat: 4
        }
    }
}

struct ToneResult: Codable, Equatable {
    var kinds: [ToneKind]
    var certain: Bool

    static let none = ToneResult(kinds: [], certain: true)
    var isEmpty: Bool { kinds.isEmpty }

    /// Kartta ve AirPods uyarısında kullanılan kısa metin.
    var shortWarning: String {
        guard let top = kinds.max(by: { $0.severity < $1.severity }) else { return "" }
        return certain ? "Dikkat: \(top.label)" : "\(top.label) olabilir"
    }
}

/// Sözcük temelli ön değerlendirme; dil modelinin sonucuyla birleştirilir.
enum ToneLexicon {
    private static let en: [ToneKind: [String]] = [
        .profanity: ["fuck", "shit", "damn", "bitch", "bastard", "crap", "asshole", "piss off"],
        .insult: ["idiot", "stupid", "moron", "loser", "dumb", "useless", "pathetic"],
        .threat: ["or else", "i'll hurt", "you'll regret", "i will kill", "watch your back", "i'll call the police"],
        .warning: ["don't you dare", "last warning", "stop it now", "back off", "get out"],
        .rude: ["shut up", "whatever", "who cares", "mind your own business", "get lost"],
        .sarcasm: ["yeah right", "oh great", "big surprise", "thanks a lot", "nice going", "oh really"],
        .slang: ["gonna", "wanna", "dude", "bro", "y'all", "ain't", "lit", "sus", "no cap"],
        .joke: ["just kidding", "jk", "lol", "haha", "kidding"],
        .teasing: ["look who's", "aren't you", "someone's"],
        .argument: ["that's not true", "you always", "you never", "i disagree", "that's not fair"]
    ]
    private static let tr: [ToneKind: [String]] = [
        .profanity: ["siktir", "amk", "lan oğlum", "kahretsin", "hassiktir"],
        .insult: ["salak", "aptal", "gerizekalı", "mal", "beyinsiz", "ahmak"],
        .threat: ["görürsün sen", "seni öldürürüm", "pişman olursun", "polisi ararım"],
        .warning: ["son kez söylüyorum", "sakın", "kes artık", "defol"],
        .rude: ["kapa çeneni", "bana ne", "sus be"],
        .sarcasm: ["aferin sana", "ne güzel", "hiç belli olmuyor", "sağ ol ya"],
        .slang: ["kanka", "lan", "abi ya", "moruk", "naber"],
        .joke: ["şaka şaka", "şakaydı", "haha"],
        .argument: ["hiç de değil", "her zaman böylesin", "doğru değil", "haksızlık"]
    ]

    static func analyze(_ text: String) -> ToneResult {
        let cleaned = text.lowercased(with: Locale(identifier: "tr"))
            .map { $0.isLetter || $0 == "'" ? $0 : " " }
        let t = " " + String(cleaned) + " "
        var found: [ToneKind] = []
        for dict in [en, tr] {
            for (k, words) in dict where words.contains(where: { t.contains(" \($0) ") }) {
                if !found.contains(k) { found.append(k) }
            }
        }
        // tek başına hafif argo/şaka işaretleri belirsiz kabul edilir
        let certain = found.contains { $0.severity >= 3 }
        return ToneResult(kinds: found, certain: certain)
    }

    /// Apple'ın cihaz içi duygu skoru: belirgin olumsuzluk "Sert ton olabilir" olarak işaretlenir.
    static func sentiment(_ text: String) -> ToneResult {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        let score = Double(tag?.rawValue ?? "0") ?? 0
        return score <= -0.6 ? ToneResult(kinds: [.harsh], certain: false) : .none
    }

    static func merge(_ a: ToneResult, _ b: ToneResult) -> ToneResult {
        var kinds = a.kinds
        for k in b.kinds where !kinds.contains(k) { kinds.append(k) }
        let certain = (a.certain && !a.isEmpty) || (b.certain && !b.isEmpty) || kinds.contains { $0.severity >= 3 }
        return ToneResult(kinds: kinds, certain: certain)
    }
}
