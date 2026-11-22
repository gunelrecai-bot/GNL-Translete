import UIKit

/// Uygulamada sözlük denetimini iPhone'un klavye sözlüğüne (UITextChecker) bağlar.
enum SpellSetup {
    static func install() {
        let langs = UITextChecker.availableLanguages
        Spell.available = langs.contains("tr_TR") && langs.contains("en_US")
        Spell.isWord = { word, lang in
            let code = lang == .tr ? "tr_TR" : "en_US"
            let r = UITextChecker().rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
                                                          startingAt: 0, wrap: false, language: code)
            return r.location == NSNotFound
        }
    }
}
