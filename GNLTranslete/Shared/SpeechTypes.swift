import Foundation

// Bu klasördeki dosyalar hem uygulamada hem de Mac'teki otomatik test düzeneğinde derlenir.
// UIKit / AVAudioSession gibi yalnızca iPhone'a ait şeyler burada kullanılmaz.

struct HeardTurn {
    let text: String
    let language: DetectedLanguage
    let confidence: Float
}

enum DetectedLanguage: String, Codable {
    case tr, en, mixed
    var title: String { switch self { case .tr: "Türkçe"; case .en: "İngilizce"; case .mixed: "Karışık" } }
}

/// Sözlük denetimi: uygulamada UITextChecker, Mac testinde NSSpellChecker bağlanır.
enum Spell {
    /// (kelime, dil) → sözlükte var mı
    nonisolated(unsafe) static var isWord: (String, DetectedLanguage) -> Bool = { _, _ in true }
    nonisolated(unsafe) static var available = false
}
