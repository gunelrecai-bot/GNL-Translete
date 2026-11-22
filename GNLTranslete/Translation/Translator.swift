import Foundation
import Translation

/// Apple Translation çerçevesi; diller indirildikten sonra tamamen cihaz içinde çalışır.
/// Çeviriler sırayla yapılır (aynı anda iki istek oturumu bozabiliyor); hata olursa oturum yenilenip bir kez daha denenir.
actor Translator {
    static let shared = Translator()
    static let tr = Locale.Language(identifier: "tr")
    static let en = Locale.Language(identifier: "en")

    private var trToEn: TranslationSession?
    private var enToTr: TranslationSession?
    private var tail: Task<Void, Never>?

    enum Direction { case trToEn, enToTr }

    static func status() async -> (trEn: LanguageAvailability.Status, enTr: LanguageAvailability.Status) {
        let a = LanguageAvailability()
        let s1 = await a.status(from: tr, to: en)
        let s2 = await a.status(from: en, to: tr)
        return (s1, s2)
    }

    private func session(_ dir: Direction, fresh: Bool) -> TranslationSession {
        switch dir {
        case .trToEn:
            if fresh || trToEn == nil { trToEn = TranslationSession(installedSource: Self.tr, target: Self.en) }
            return trToEn!
        case .enToTr:
            if fresh || enToTr == nil { enToTr = TranslationSession(installedSource: Self.en, target: Self.tr) }
            return enToTr!
        }
    }

    private func run(_ text: String, _ dir: Direction) async throws -> String {
        do {
            return try await session(dir, fresh: false).translate(text).targetText
        } catch {
            // oturum geçersizleşmiş olabilir (arka plan, uzun bekleme): yenile ve bir kez daha dene
            return try await session(dir, fresh: true).translate(text).targetText
        }
    }

    func translate(_ text: String, _ dir: Direction) async throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        let prev = tail
        let job = Task { () throws -> String in
            _ = await prev?.value
            return try await self.run(t, dir)
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }

    func batch(_ texts: [String], _ dir: Direction) async -> [String] {
        var out: [String] = []
        for t in texts { out.append((try? await translate(t, dir)) ?? "") }
        return out
    }
}
