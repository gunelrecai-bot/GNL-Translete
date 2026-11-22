import SwiftUI
import Observation

enum ConversationMode: String, Codable, CaseIterable {
    case home, travel
    var title: String { self == .home ? "Ev" : "Seyahat" }
}

enum SpeechEngineChoice: String, Codable, CaseIterable {
    case apple, whisper
    var title: String { self == .apple ? "Apple (anlık, en hafif)" : "Whisper (cümle bitince, daha isabetli olabilir)" }
}

enum ResumeBehavior: String, Codable, CaseIterable {
    case automatic, manual
    var title: String { self == .automatic ? "Otomatik Devam Et" : "Elle Devam Et" }
}

enum SpeechSpeed: String, Codable, CaseIterable {
    case slow, normal, fast
    var title: String { switch self { case .slow: "Yavaş"; case .normal: "Normal"; case .fast: "Hızlı" } }
    /// AVSpeechUtterance hız çarpanı (varsayılan hıza göre)
    var factor: Float { switch self { case .slow: 0.8; case .normal: 1.0; case .fast: 1.15 } }
}

enum ThemeSource: String, Codable, CaseIterable {
    case preset, custom, system
    var title: String { switch self { case .preset: "Hazır Tema"; case .custom: "Kendi Temam"; case .system: "Sisteme Uyumlu" } }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var setupComplete: Bool { didSet { d.set(setupComplete, forKey: "setupComplete") } }
    var mode: ConversationMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    var resumeBehavior: ResumeBehavior { didSet { d.set(resumeBehavior.rawValue, forKey: "resume") } }

    var themeSource: ThemeSource { didSet { d.set(themeSource.rawValue, forKey: "themeSource") } }
    var presetID: String { didSet { d.set(presetID, forKey: "presetID") } }
    var lightThemeID: String { didSet { d.set(lightThemeID, forKey: "lightThemeID") } }
    var darkThemeID: String { didSet { d.set(darkThemeID, forKey: "darkThemeID") } }
    var customPalette: ThemePalette { didSet { save(customPalette, "customPalette") } }

    var trVoiceID: String? { didSet { d.set(trVoiceID, forKey: "trVoice") } }
    var enVoiceID: String? { didSet { d.set(enVoiceID, forKey: "enVoice") } }
    var trSpeed: SpeechSpeed { didSet { d.set(trSpeed.rawValue, forKey: "trSpeed") } }
    var enSpeed: SpeechSpeed { didSet { d.set(enSpeed.rawValue, forKey: "enSpeed") } }
    var modelTier: ModelTier { didSet { d.set(modelTier.rawValue, forKey: "modelTier") } }
    /// İngilizce sözün Türkçesini kulaklıktan kendiliğinden oku (varsayılan kapalı)
    var autoReadTranslation: Bool { didSet { d.set(autoReadTranslation, forKey: "autoRead") } }
    /// Hafif mod: doğal İngilizce yalnızca istenince üretilir, telefon daha az yorulur
    var lightMode: Bool { didSet { d.set(lightMode, forKey: "lightMode") } }
    var speechEngine: SpeechEngineChoice { didSet { d.set(speechEngine.rawValue, forKey: "speechEngine") } }
    var noiseReduction: Bool { didSet { d.set(noiseReduction, forKey: "noiseReduction") } }
    var contextHints: Bool { didSet { d.set(contextHints, forKey: "contextHints") } }
    /// Sık kullanılan isimler (virgülle): motor bunları doğru yazmaya çalışır
    var customNames: String { didSet { d.set(customNames, forKey: "customNames") } }
    var nameList: [String] {
        customNames.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private init() {
        setupComplete = d.bool(forKey: "setupComplete")
        mode = ConversationMode(rawValue: d.string(forKey: "mode") ?? "") ?? .home
        resumeBehavior = ResumeBehavior(rawValue: d.string(forKey: "resume") ?? "") ?? .automatic
        themeSource = ThemeSource(rawValue: d.string(forKey: "themeSource") ?? "") ?? .preset
        presetID = d.string(forKey: "presetID") ?? "gnl"
        lightThemeID = d.string(forKey: "lightThemeID") ?? "lavender"
        darkThemeID = d.string(forKey: "darkThemeID") ?? "gnl"
        if let data = d.data(forKey: "customPalette"), let p = try? JSONDecoder().decode(ThemePalette.self, from: data) {
            customPalette = p
        } else {
            customPalette = Themes.palette("gnl")
        }
        trVoiceID = d.string(forKey: "trVoice")
        enVoiceID = d.string(forKey: "enVoice")
        trSpeed = SpeechSpeed(rawValue: d.string(forKey: "trSpeed") ?? "") ?? .normal
        enSpeed = SpeechSpeed(rawValue: d.string(forKey: "enSpeed") ?? "") ?? .normal
        modelTier = ModelTier(rawValue: d.string(forKey: "modelTier") ?? "") ?? .fast
        autoReadTranslation = d.bool(forKey: "autoRead")
        lightMode = d.object(forKey: "lightMode") as? Bool ?? true
        speechEngine = SpeechEngineChoice(rawValue: d.string(forKey: "speechEngine") ?? "") ?? .apple
        noiseReduction = d.bool(forKey: "noiseReduction")
        contextHints = d.object(forKey: "contextHints") as? Bool ?? true
        customNames = d.string(forKey: "customNames") ?? ""
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }

    func palette(for scheme: ColorScheme) -> ThemePalette {
        switch themeSource {
        case .preset: return Themes.palette(presetID)
        case .custom: return customPalette
        case .system: return Themes.palette(scheme == .dark ? darkThemeID : lightThemeID)
        }
    }
}
