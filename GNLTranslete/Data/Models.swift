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
/// Türkçe söz:  duyulan · italik İngilizcesi · (Cevap Ver →) cevap
/// İngilizce söz: duyulan · italik Türkçesi · italik doğal İngilizcesi · (Cevap Ver →) cevap
struct ConversationTurn: Identifiable, Equatable {
    let id = UUID()
    var heard: String
    var heardLanguage: DetectedLanguage
    var translation: String = ""      // .tr → İngilizce, .en → Türkçe
    var natural: String = ""          // yalnızca .en: doğal İngilizce
    var reply: String = ""            // Cevap Ver ile üretilir
    var replyTR: String = ""
    var replying = false
    var naturalPending = false
    var tone: ToneResult = .none
    var status: String = ""
    var isOwnTranslation = false      // Cümlemi Çevir sonucu
    var isQuestion = false            // bana soru soruldu → cevap önerisi kendiliğinden hazırlanır
}
