import Foundation
import SwiftData

@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \SavedPhrase.folder) var phrases: [SavedPhrase] = []
    var practiceStateData: Data?   // yarım kalan tur (PracticeState JSON)

    init(name: String) {
        id = UUID(); self.name = name; createdAt = Date()
    }

    var practiceState: PracticeState? {
        get { practiceStateData.flatMap { try? JSONDecoder().decode(PracticeState.self, from: $0) } }
        set { practiceStateData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

@Model
final class SavedPhrase {
    @Attribute(.unique) var id: UUID
    var english: String
    var turkish: String
    var createdAt: Date
    var folder: Folder?
    /// Zorlandıklarım listesinde mi
    var struggling: Bool = false
    /// Arka arkaya farklı turlarda "Bildim" sayısı (2 olunca Zorlandıklarım'dan çıkar)
    var knownStreak: Int = 0
    var lastKnownSessionID: UUID?
    var trashed: Bool = false   // Geri Al için yumuşak silme

    init(english: String, turkish: String, folder: Folder?) {
        id = UUID(); self.english = english; self.turkish = turkish; createdAt = Date(); self.folder = folder
    }
}

/// Yarım kalan pratik turu.
struct PracticeState: Codable, Equatable {
    var sessionID = UUID()
    var order: [UUID]            // ilk geçiş sırası
    var index: Int = 0
    var skippedOnce: [UUID] = [] // tur sonunda bir kez daha gösterilecek
    var inSecondPass = false
    var secondPassIndex = 0
    var known = 0
    var repeatNeeded = 0
    var skipped = 0
    var onlyStruggling = false
}

/// Sohbet kartı (bellekte; yeniden açılışta boş başlar).
struct ConversationTurn: Identifiable, Equatable {
    let id = UUID()
    var generation: Int
    var heard: String
    var heardLanguage: DetectedLanguage
    var translation: String = ""        // Türkçe çeviri (İngilizce söz) veya İngilizce çeviri (Türkçe söz)
    var englishEquivalent: String = ""  // Ev modunda İngilizce sözün doğal İngilizce karşılığı
    var suggestion: String = ""
    var suggestionTR: String = ""
    var tone: ToneResult = .none
    var topic: String = ""
    var status: String = "Çevriliyor…"
    var isOwnTranslation = false        // Cümlemi Çevir sonucu
}
