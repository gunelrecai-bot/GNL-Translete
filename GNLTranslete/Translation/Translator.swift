import Foundation
import Translation

/// Apple Translation çerçevesi; diller indirildikten sonra tamamen cihaz içinde çalışır.
actor Translator {
    static let shared = Translator()
    static let tr = Locale.Language(identifier: "tr")
    static let en = Locale.Language(identifier: "en")

    private var trToEn: TranslationSession?
    private var enToTr: TranslationSession?

    enum Direction { case trToEn, enToTr }

    static func status() async -> (trEn: LanguageAvailability.Status, enTr: LanguageAvailability.Status) {
        let a = LanguageAvailability()
        let s1 = await a.status(from: tr, to: en)
        let s2 = await a.status(from: en, to: tr)
        return (s1, s2)
    }

    func translate(_ text: String, _ dir: Direction) async throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        let session: TranslationSession
        switch dir {
        case .trToEn:
            if trToEn == nil { trToEn = TranslationSession(installedSource: Self.tr, target: Self.en) }
            session = trToEn!
        case .enToTr:
            if enToTr == nil { enToTr = TranslationSession(installedSource: Self.en, target: Self.tr) }
            session = enToTr!
        }
        return try await session.translate(t).targetText
    }

    func batch(_ texts: [String], _ dir: Direction) async -> [String] {
        var out: [String] = []
        for t in texts { out.append((try? await translate(t, dir)) ?? "") }
        return out
    }
}
