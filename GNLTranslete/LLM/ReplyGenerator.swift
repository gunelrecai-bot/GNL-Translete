import Foundation
import NaturalLanguage

struct ReplyResult {
    var reply: String
    var tone: ToneResult
}

/// Cihaz içi dil modeli: doğal İngilizce karşılık ve "Cevap Ver" önerisi.
final class ReplyGenerator {
    static let shared = ReplyGenerator()
    private var engine: LlamaEngine?
    private var loadedTier: ModelTier?
    private(set) var loadError: String?

    var isLoaded: Bool { engine != nil }

    func loadIfNeeded() {
        let store = ModelStore.shared
        let tier = store.activeTier
        if engine != nil && loadedTier == tier { return }
        guard store.state == .ready else { return }
        engine = nil   // önceki modeli bellekten çıkar
        do { engine = try LlamaEngine(modelPath: store.fileURL.path); loadedTier = tier; loadError = nil }
        catch { loadError = error.localizedDescription; loadedTier = nil }
    }

    func unload() { engine = nil; loadedTier = nil }

    struct ContextTurn { let english: String }

    // MARK: Doğal İngilizce + ton
    struct Naturalized { var natural: String; var tone: ToneResult }

    /// Duyulan (bozuk, eksik, aksanlı olabilir) İngilizceyi aynı anlam ve sertlikte doğal İngilizceye çevirir; tonu da işaretler.
    func naturalize(_ heard: String, previous: [ContextTurn]) async -> Naturalized? {
        loadIfNeeded()
        guard let engine else { return nil }
        let system = """
        You clean up one line of spoken English that was transcribed by a speech recognizer.
        The line may be broken, accented, incomplete or contain wrongly heard words.
        1) NATURAL: rewrite it as natural, correct English with exactly the same meaning and the same strength (polite stays polite, rude stays rude, a joke stays a joke). If it is already fine, copy it unchanged. Add only words that are obviously missing. Never answer it and never add new information.
        2) TONE: none, or the clear tones from: joke, teasing, sarcasm, slang, rude, profanity, insult, argument, warning, threat. Only mark a tone if the words show it.
        Answer in exactly two lines.

        Examples:
        Line: going to school
        NATURAL: I'm going to school.
        TONE: none

        Line: you want window seat yes
        NATURAL: Would you like a window seat?
        TONE: none

        Line: yeah right great job genius
        NATURAL: Yeah, right. Great job, genius.
        TONE: sarcasm

        Line: shut up man you always do this
        NATURAL: Shut up, man. You always do this.
        TONE: rude, argument

        Line: Can I have the bill, please?
        NATURAL: Can I have the bill, please?
        TONE: none
        """
        var user = ""
        if !previous.isEmpty {
            user += "Earlier lines (only to understand unclear words):\n"
            for p in previous.suffix(3) { user += "- \(p.english)\n" }
        }
        user += "Line: \(heard)\n/no_think"
        let words = heard.split(separator: " ").count
        let raw = await engine.generate([.init(role: "system", content: system), .init(role: "user", content: user)],
                                        maxTokens: min(120, 40 + words * 4), temperature: 0.1)
        var natural = "", toneLine = "none"
        for line in raw.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.uppercased().hasPrefix("NATURAL:") { natural = String(l.dropFirst(8)) }
            else if l.uppercased().hasPrefix("TONE:") { toneLine = String(l.dropFirst(5)).lowercased() }
        }
        natural = natural.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”<>[] ").union(.whitespaces))
        if natural.isEmpty { return nil }
        // Anlam koruma: model cümleyi bambaşka bir şeye çevirdiyse duyulanı koru
        if !Self.sameMeaning(heard, natural) { natural = heard }
        let kinds = ToneKind.allCases.filter { toneLine.contains($0.rawValue) }
        return Naturalized(natural: natural, tone: ToneResult(kinds: kinds, certain: false))
    }

    /// Kelime örtüşmesi + cümle gömmesi ile kaba anlam karşılaştırması.
    static func sameMeaning(_ a: String, _ b: String) -> Bool {
        let overlap = ConversationController.similarity(a, b)
        if overlap >= 0.5 { return true }
        if let emb = NLEmbedding.sentenceEmbedding(for: .english) {
            return emb.distance(between: a.lowercased(), and: b.lowercased()) < 0.9
        }
        return overlap >= 0.3
    }

    /// Bağlam: son 3 söz + seçilen söze anlamca en yakın 3 eski söz (konu değişimi / eski konuya dönüş için).
    static func relevantContext(for line: String, from history: [ContextTurn]) -> [ContextTurn] {
        guard history.count > 6 else { return history }
        let recent = Array(history.suffix(3))
        let older = Array(history.dropLast(3))
        guard let emb = NLEmbedding.sentenceEmbedding(for: .english) else { return Array(history.suffix(6)) }
        let ranked = older.enumerated()
            .map { ($0.offset, emb.distance(between: line.lowercased(), and: $0.element.english.lowercased())) }
            .sorted { $0.1 < $1.1 }
            .prefix(3)
            .map(\.0)
            .sorted()
        return ranked.map { older[$0] } + recent
    }

    // MARK: Cevap Ver
    /// Kullanıcının seçtiği söze (kendisinin ya da karşıdakinin) sohbetin doğal devamı olacak cevabı üretir.
    func reply(to line: String, history: [ContextTurn], mode: ConversationMode, hint: String?) async -> ReplyResult? {
        loadIfNeeded()
        guard let engine else { return nil }

        let modeText = mode == .home
            ? "The user is at home talking with family; Turkish and English are mixed."
            : "The user is travelling and talking with native and non-native English speakers."

        let system = """
        You help a Turkish speaker continue a spoken conversation in English. \(modeText)
        The user picked one line of the conversation. It may have been said by the other person or by the user. It may be a question, a statement, or an incomplete or badly transcribed sentence.
        Suggest the ONE next thing the user could naturally say in response to that line, in simple, common English.
        Match the length to the line: a short line gets one short sentence. Never write a long reply to a short line.
        Never invent facts or preferences that were not said; if needed, offer simple options or ask one short question.
        Stay calm and polite even if the line is rude.
        Answer in exactly this format:
        TONE: none or comma list of joke, teasing, sarcasm, slang, rude, profanity, insult, argument, warning, threat
        REPLY: the English sentence, plain text, no quotes or brackets

        Examples:
        Line: I'm going to school.
        TONE: none
        REPLY: Oh, nice. Have a good day!

        Line: Would you like a window seat?
        TONE: none
        REPLY: Yes, please. That would be great.

        Line: Sorry, we're fully booked tonight.
        TONE: none
        REPLY: Oh, I see. Is there another hotel nearby?
        """

        var user = ""
        let ctx = Self.relevantContext(for: line, from: history)
        if !ctx.isEmpty {
            user += "Earlier conversation (background only, oldest first):\n"
            for t in ctx { user += "- \(t.english)\n" }
            user += "\n"
        }
        user += "Line: \(line)\n"
        if let hint, !hint.isEmpty { user += "The user's own direction for the reply (Turkish): \(hint)\n" }
        user += "/no_think"

        let words = line.split(separator: " ").count
        let raw = await engine.generate([.init(role: "system", content: system), .init(role: "user", content: user)],
                                        maxTokens: min(150, 60 + words * 6), temperature: 0.3)
        guard var r = Self.parse(raw) else { return nil }
        if words <= 5 { r.reply = Self.firstSentences(r.reply, max: 2, maxWords: 16) }
        return r
    }

    static func parse(_ raw: String) -> ReplyResult? {
        var reply = "", toneLine = "none"
        for line in raw.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.uppercased().hasPrefix("REPLY:") { reply = String(l.dropFirst(6)) }
            else if l.uppercased().hasPrefix("TONE:") { toneLine = String(l.dropFirst(5)).lowercased() }
            else if !reply.isEmpty && !l.isEmpty && !l.uppercased().hasPrefix("LINE:") { reply += " " + l }
        }
        if reply.isEmpty { reply = raw.components(separatedBy: .newlines).last { !$0.isEmpty } ?? "" }
        reply = reply.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”<>[] ").union(.whitespaces))
        guard !reply.isEmpty else { return nil }
        let kinds = ToneKind.allCases.filter { toneLine.contains($0.rawValue) }
        return ReplyResult(reply: reply, tone: ToneResult(kinds: kinds, certain: kinds.contains { $0.severity >= 3 }))
    }

    /// Kısa sözlere gelen uzun cevapları ilk cümle(ler)de keser.
    static func firstSentences(_ text: String, max: Int, maxWords: Int) -> String {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?".contains(ch) {
                out.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                let words = out.joined(separator: " ").split(separator: " ").count
                if out.count >= max || words >= maxWords { break }
            }
        }
        if out.isEmpty { return text }
        return out.joined(separator: " ")
    }
}
