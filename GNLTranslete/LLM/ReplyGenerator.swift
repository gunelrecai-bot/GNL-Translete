import Foundation

struct ReplyResult {
    var reply: String
    var tone: ToneResult
    var topic: String   // devam / bağlantılı / yeni / eski konuya dönüş
    var natural: String = ""  // son sözün doğal İngilizce karşılığı
}

/// Sohbet bağlamına göre kullanıcının söyleyebileceği doğal İngilizce cevabı üretir.
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

    func unload() { engine = nil }

    struct ContextTurn { let speaker: String; let english: String }

    func generate(history: [ContextTurn], latestEnglish: String, mode: ConversationMode, hint: String?) async -> ReplyResult? {
        loadIfNeeded()
        guard let engine else { return nil }

        let modeText = mode == .home
            ? "The user is at home talking with family. Speech may mix Turkish and English."
            : "The user is travelling and talking with native and non-native English speakers. The other person's English may be accented, incomplete or ungrammatical; interpret it from context."

        let system = """
        You help a Turkish speaker reply in spoken English. \(modeText)
        Write ONE natural reply the user can say out loud, using simple, common words.
        Match the length to the latest line: a short or incomplete line gets a short reply (one short sentence or a short question). Never write a long reply to a short line.
        If the latest line is unclear or incomplete, guess the most likely meaning in NATURAL and reply briefly, or ask one short clarifying question.
        If the last line is not a question, suggest a fitting reaction or a follow-up question.
        Never invent the user's preferences or facts that were not said. If needed, offer options ("Either is fine" / "Maybe A or B?") or a short clarification question in English.
        Keep the reply calm and appropriate even if the other person is rude.
        Answer in exactly this format:
        TOPIC: continue | related | new | return
        TONE: none or comma list of joke, teasing, sarcasm, slang, rude, profanity, insult, argument, warning, threat
        SURE: yes | no
        NATURAL: the latest line rewritten as natural, correct English with the same meaning and the same strength
        REPLY: the English reply, plain text, no brackets or quotes
        Examples:
        Latest line: going to school
        TOPIC: continue
        TONE: none
        SURE: yes
        NATURAL: I'm going to school.
        REPLY: Oh, nice. Have a good day!

        Latest line: Would you like a window seat?
        TOPIC: continue
        TONE: none
        SURE: yes
        NATURAL: Would you like a window seat?
        REPLY: Yes, please. That would be great.

        Latest line: sorry we full tonight
        TOPIC: new
        TONE: none
        SURE: yes
        NATURAL: Sorry, we're fully booked tonight.
        REPLY: Oh, I see. Is there another hotel nearby?

        Reply ONLY to the latest line. Use earlier lines just as background; never quote or repeat them unless the latest line refers to them.
        """

        var convo = "Conversation so far (oldest first):\n"
        for t in history.suffix(20) { convo += "\(t.speaker): \(t.english)\n" }
        convo += "\nLatest line from the other person: \(latestEnglish)\n"
        if let hint, !hint.isEmpty { convo += "The user's own direction for the reply (Turkish): \(hint)\n" }

        // Uzunluk konuşmaya göre: kısa söze kısa cevap
        let inWords = latestEnglish.split(separator: " ").count
        let budget = min(160, 70 + inWords * 6)
        let raw = await engine.generate([.init(role: "system", content: system), .init(role: "user", content: convo)], maxTokens: budget, temperature: 0.3)
        guard var r = Self.parse(raw) else { return nil }
        if inWords <= 5 { r.reply = Self.firstSentences(r.reply, max: 2, maxWords: 16) }
        return r
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

    static func parse(_ raw: String) -> ReplyResult? {
        var reply = "", topic = "continue", toneLine = "none", sure = true, natural = ""
        for line in raw.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.uppercased().hasPrefix("REPLY:") { reply = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if l.uppercased().hasPrefix("TOPIC:") { topic = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces).lowercased() }
            else if l.uppercased().hasPrefix("TONE:") { toneLine = String(l.dropFirst(5)).lowercased() }
            else if l.uppercased().hasPrefix("NATURAL:") { natural = String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if l.uppercased().hasPrefix("SURE:") { sure = l.lowercased().contains("yes") }
            else if !reply.isEmpty && !l.isEmpty { reply += " " + l }   // çok satırlı cevap
        }
        if reply.isEmpty {
            reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        reply = reply.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”<>[] "))
        natural = natural.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”<>[] "))
        guard !reply.isEmpty else { return nil }
        let kinds = ToneKind.allCases.filter { toneLine.contains($0.rawValue) }
        return ReplyResult(reply: reply, tone: ToneResult(kinds: kinds, certain: sure), topic: topic, natural: natural)
    }
}
