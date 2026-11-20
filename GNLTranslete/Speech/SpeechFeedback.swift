import Foundation
import NaturalLanguage

/// Tek seferlik İngilizce (veya Türkçe) söz yakalama: konuşmanın sonu otomatik algılanır.
@MainActor
final class OneShotListener {
    private var engine: ListeningEngine?

    func listen(locale: String, timeout: TimeInterval = 15) async -> HeardTurn? {
        let e = ListeningEngine(locales: [Locale(identifier: locale)])
        engine = e
        return await withCheckedContinuation { (c: CheckedContinuation<HeardTurn?, Never>) in
            var done = false
            func finish(_ t: HeardTurn?) {
                guard !done else { return }
                done = true
                e.stop()
                c.resume(returning: t)
            }
            e.onTurn = { t in finish(t) }
            do { try e.start() } catch { finish(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    func cancel() { engine?.stop() }
}

struct PronunciationFeedback {
    var short: String
    var details: String
    var uncertain: Bool
}

enum SpeechCompare {
    /// Telaffuz: hedef cümlenin kelimeleriyle tanınan kelimeleri karşılaştırır.
    /// Tanıma güveni düşükse kesin hata söylemez.
    static func pronunciation(target: String, heard: HeardTurn?) -> PronunciationFeedback {
        guard let heard, !heard.text.isEmpty else {
            return .init(short: "Sesin net duyulmadı. Bir kez daha, biraz daha yakından söyleyebilirsin.", details: "Kayıt çok kısa ya da sessiz olduğu için değerlendirme yapılmadı.", uncertain: true)
        }
        let t = tokens(target), h = tokens(heard.text)
        let missing = t.filter { !h.contains($0) }
        let extra = h.filter { !t.contains($0) }
        let lowConf = heard.confidence > 0 && heard.confidence < 0.5
        if missing.isEmpty {
            return .init(short: "Çok iyi! Cümlenin tamamı anlaşıldı.",
                         details: "Duyulan: \"\(heard.text)\"\nTüm kelimeler tanındı. Akıcılık için cümleyi bir nefeste, vurguyu anahtar kelimeye vererek tekrar edebilirsin.",
                         uncertain: false)
        }
        if lowConf {
            return .init(short: "Kayıt net değil; kesin bir hata söyleyemiyorum.",
                         details: "Duyulan: \"\(heard.text)\"\nŞu kelimeler duyulamamış olabilir: \(missing.joined(separator: ", ")). Ortam gürültülüyse tekrar dene.",
                         uncertain: true)
        }
        var d = "Duyulan: \"\(heard.text)\"\n"
        d += "Anlaşılmayan kelimeler: \(missing.joined(separator: ", "))\n"
        if !extra.isEmpty { d += "Onların yerine duyulan: \(extra.joined(separator: ", "))\n" }
        if let w = missing.first { d += "Örnek: \"\(w)\" kelimesini önce yavaşça tek başına, sonra cümlenin içinde söyle. Yavaş Dinle ile karşılaştır." }
        return .init(short: "\(missing.count) kelime farklı anlaşıldı: \(missing.prefix(3).joined(separator: ", "))", details: d, uncertain: false)
    }

    enum MeaningVerdict { case same, different(String) }

    /// Pratik: aynı anlamı veren farklı cevapları da kabul et.
    static func meaning(answer: String, expected: String) -> MeaningVerdict {
        let overlap = ConversationController.similarity(answer, expected)
        var dist: Double = 2
        if let emb = NLEmbedding.sentenceEmbedding(for: .english) {
            dist = emb.distance(between: answer.lowercased(), and: expected.lowercased())
        }
        if overlap >= 0.8 || dist < 0.55 { return .same }
        let t = tokens(expected), a = tokens(answer)
        let missing = t.filter { !a.contains($0) && $0.count > 2 }
        return .different(missing.isEmpty ? "Anlam kayıtlı cümleden farklı görünüyor." : "Eksik ya da farklı anlam taşıyan kelimeler: \(missing.prefix(5).joined(separator: ", "))")
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
    }
}
