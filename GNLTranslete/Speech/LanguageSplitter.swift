import Foundation
import UIKit

/// Bir konuşma sırasında Türkçe ve İngilizce art arda söylendiyse ("Merhaba benim adım Recai, hello my name is Recai")
/// metni dil parçalarına ayırır; her parça ayrı kart olur.
enum LanguageSplitter {
    static func split(_ h: HeardTurn) -> [HeardTurn] {
        let words = h.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 4,
              UITextChecker.availableLanguages.contains("tr_TR"),
              UITextChecker.availableLanguages.contains("en_US") else { return [h] }
        let tc = UITextChecker()
        func valid(_ w: String, _ code: String) -> Bool {
            let c = w.filter(\.isLetter)
            guard c.count >= 2 else { return false }
            return tc.rangeOfMisspelledWord(in: c, range: NSRange(location: 0, length: (c as NSString).length),
                                            startingAt: 0, wrap: false, language: code).location == NSNotFound
        }
        // her kelimeye dil etiketi: yalnız bir dilin sözlüğünde varsa o dil; ikisinde de / hiçbirinde yoksa komşusundan
        var labels: [DetectedLanguage?] = words.map { w in
            let en = valid(w, "en_US"), tr = valid(w, "tr_TR")
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
        // 3 kelimeden kısa parçalar ayrı kart olmasın, komşusuna katılsın
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
