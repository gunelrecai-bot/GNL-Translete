import Foundation
import NaturalLanguage

/// Canlı konuşma motorlarından gelen metinleri konuşma sıralarına (kartlara) dönüştürür.
/// - Türkçe ve İngilizce motor aynı sesi dinler; her birinin metni ayrı bir "şerit"te tutulur.
/// - Sessizlik (VAD) sıra sonunu belirler.
/// - Motorun tekrar gönderdiği önceki metin ayıklanır (kartlarda tekrar olmaz).
/// - Dil; sözlük + metin dili + canlı önizleme oyu + motor güveniyle seçilir.
final class TurnAssembler {
    struct LaneState {
        let lang: DetectedLanguage
        var finalText = ""
        var volatileText = ""
        var rawVolatile = ""
        var consumed: [String] = []
        var confSum = 0.0
        var confCount = 0
        var votes = 0.0
    }

    private(set) var lanes: [LaneState]
    private let lock = NSLock()

    // VAD
    var endSilence: TimeInterval = 0.8
    private var inSpeech = false
    private var silence: TimeInterval = 0
    private(set) var speechTime: TimeInterval = 0
    private var noiseFloor: Float = 0.006

    init(langs: [DetectedLanguage]) {
        lanes = langs.map { LaneState(lang: $0) }
    }

    // MARK: Sessizlik / sıra sonu
    struct VADResult { let speaking: Bool; let endTurn: Bool; let spoken: TimeInterval }

    func vad(rms: Float, duration: TimeInterval, muted: Bool) -> VADResult {
        if !inSpeech { noiseFloor = 0.95 * noiseFloor + 0.05 * min(rms, 0.05) }
        let voiced = !muted && rms > max(0.02, noiseFloor * 4)
        var end = false
        var spoken: TimeInterval = 0
        if voiced { inSpeech = true; silence = 0; speechTime += duration }
        else if inSpeech {
            silence += duration
            if silence >= endSilence { end = true; inSpeech = false; silence = 0; spoken = speechTime; speechTime = 0 }
        }
        return VADResult(speaking: inSpeech, endTurn: end, spoken: spoken)
    }

    // MARK: Motor sonuçları
    static func clean(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.first, "-–—•".contains(f) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        return s
    }
    static func words(_ t: String) -> [String] { t.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    static func norm(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// text, consumed ile başlıyorsa baştaki o kelimeleri at.
    static func strip(_ text: String, _ consumed: [String]) -> (matched: Int, rest: String) {
        let w = words(text)
        var n = 0
        while n < min(w.count, consumed.count) && norm(w[n]) == norm(consumed[n]) { n += 1 }
        guard n > 0, n * 2 >= min(w.count, consumed.count) else { return (0, text) }
        return (n, w.dropFirst(n).joined(separator: " "))
    }

    /// Bir motor sonucu geldi. Canlı önizleme metnini döndürür.
    @discardableResult
    func receive(lane i: Int, text rawText: String, isFinal: Bool, conf: Double?) -> String {
        lock.lock(); defer { lock.unlock() }
        guard i < lanes.count else { return "" }
        var text = Self.clean(rawText)
        lanes[i].rawVolatile = isFinal ? "" : text
        if !lanes[i].consumed.isEmpty {
            let r = Self.strip(text, lanes[i].consumed)
            if r.matched > 0 {
                text = r.rest
                if isFinal { lanes[i].consumed = Array(lanes[i].consumed.dropFirst(r.matched)) }
            } else if isFinal {
                lanes[i].consumed = []
            }
        }
        if isFinal {
            if !text.isEmpty { lanes[i].finalText += (lanes[i].finalText.isEmpty ? "" : " ") + text }
            lanes[i].volatileText = ""
            if let conf { lanes[i].confSum += conf; lanes[i].confCount += 1 }
        } else {
            lanes[i].volatileText = text
        }
        let preview = Self.decide(lanes, final: false)
        if let p = preview, let k = lanes.firstIndex(where: { $0.lang == p.language }) {
            lanes[k].votes += Double(p.text.count)
        }
        return preview?.text ?? ""
    }

    /// Sıra bitti: kartı üret, şeritleri sıfırla.
    func finish(spoken: TimeInterval) -> HeardTurn? {
        lock.lock()
        let snapshot = lanes
        for i in lanes.indices {
            lanes[i].consumed = lanes[i].rawVolatile.isEmpty ? [] : Self.words(lanes[i].rawVolatile)
            lanes[i].finalText = ""; lanes[i].volatileText = ""; lanes[i].confSum = 0; lanes[i].confCount = 0; lanes[i].votes = 0
        }
        lock.unlock()
        guard spoken >= 0.4, let best = Self.decide(snapshot, final: true),
              best.text.filter(\.isLetter).count >= 2 else { return nil }
        return best
    }

    // MARK: Dil seçimi
    static func decide(_ lanes: [LaneState], final: Bool) -> HeardTurn? {
        let texts = lanes.map { ($0.finalText + " " + $0.volatileText).trimmingCharacters(in: .whitespaces) }
        let bothConf = lanes.allSatisfy { $0.confCount > 0 }
        let totalVotes = max(1, lanes.map(\.votes).reduce(0, +))
        var best: (HeardTurn, Double)?
        for (i, l) in lanes.enumerated() {
            let text = texts[i]
            guard !text.isEmpty else { continue }
            let conf = l.confCount > 0 ? l.confSum / Double(l.confCount) : 0.5
            let nl = NLLanguageRecognizer()
            nl.languageConstraints = [.turkish, .english]
            nl.processString(text)
            let match = nl.languageHypotheses(withMaximum: 2)[l.lang == .tr ? .turkish : .english] ?? 0
            var score: Double
            if final {
                let valid = dictionaryRatio(text, lang: l.lang)
                score = valid * 0.5 + match * 0.3 + (l.votes / totalVotes) * 0.2
                if bothConf { score = score * 0.85 + conf * 0.15 }
            } else {
                score = match * 0.7 + (bothConf ? conf * 0.3 : 0.15)
            }
            if best == nil || score > best!.1 { best = (HeardTurn(text: text, language: l.lang, confidence: Float(conf)), score) }
        }
        return best?.0
    }

    static func dictionaryRatio(_ text: String, lang: DetectedLanguage) -> Double {
        guard Spell.available else { return 0.5 }
        let ws = text.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 2 }
        guard !ws.isEmpty else { return 0 }
        return Double(ws.filter { Spell.isWord($0, lang) }.count) / Double(ws.count)
    }
}

/// Aynı sırada iki dil konuşulduysa metni dil parçalarına ayırır; her parça ayrı kart olur.
enum LanguageSplitter {
    static func split(_ h: HeardTurn) -> [HeardTurn] {
        let words = h.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 4, Spell.available else { return [h] }
        func valid(_ w: String, _ l: DetectedLanguage) -> Bool {
            let c = w.filter(\.isLetter)
            return c.count >= 2 && Spell.isWord(c, l)
        }
        var labels: [DetectedLanguage?] = words.map { w in
            let en = valid(w, .en), tr = valid(w, .tr)
            if en && !tr { return .en }
            if tr && !en { return .tr }
            return nil
        }
        var last: DetectedLanguage?
        for i in labels.indices { if labels[i] == nil { labels[i] = last } else { last = labels[i] } }
        last = nil
        for i in labels.indices.reversed() { if labels[i] == nil { labels[i] = last } else { last = labels[i] } }

        var runs: [(lang: DetectedLanguage, words: [String])] = []
        for (w, l) in zip(words, labels) {
            let lang = l ?? h.language
            if let r = runs.last, r.lang == lang { runs[runs.count - 1].words.append(w) } else { runs.append((lang, [w])) }
        }
        var merged: [(lang: DetectedLanguage, words: [String])] = []
        for r in runs {
            if r.words.count < 3, !merged.isEmpty { merged[merged.count - 1].words += r.words } else { merged.append(r) }
        }
        if merged.count > 1, merged[0].words.count < 3 {
            merged[1].words = merged[0].words + merged[1].words
            merged.removeFirst()
        }
        guard merged.count > 1 else { return [h] }
        return merged.map { HeardTurn(text: $0.words.joined(separator: " "), language: $0.lang, confidence: h.confidence) }
    }
}
