import AVFoundation
import Observation

enum SpeechLang { case tr, en
    var code: String { self == .tr ? "tr-TR" : "en-US" }
    var prefix: String { self == .tr ? "tr" : "en" }
}

/// Seslendirme kuyruğu. Özel sesler yalnızca kulaklık etkinken çalar;
/// eskimiş öğeler biriktirilmez.
@Observable
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechOutput()

    struct Item {
        let text: String
        let lang: SpeechLang
        let rateFactor: Float?   // nil → dil ayarı
        let generation: Int      // hangi konuşma sırasına ait
        let publicSpeaker: Bool  // Karşıya Oku
    }

    private let synth = AVSpeechSynthesizer()
    private var queue: [Item] = []
    private var current: Item?
    private(set) var isSpeaking = false
    /// Son seslendirilen metinler (yankı filtresi için).
    private(set) var recentSpoken: [(text: String, at: Date)] = []
    var onFinishedAll: (() -> Void)?

    private override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Ses seçimi
    static func voices(_ lang: SpeechLang) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang.prefix) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    /// Seçili ses yoksa aynı dilde çalışan yerel sese döner.
    func resolvedVoice(_ lang: SpeechLang) -> (voice: AVSpeechSynthesisVoice?, fellBack: Bool) {
        let s = AppSettings.shared
        let wanted = lang == .tr ? s.trVoiceID : s.enVoiceID
        let list = Self.voices(lang)
        if let id = wanted, let v = list.first(where: { $0.identifier == id }) { return (v, false) }
        let def = list.first(where: { $0.language == lang.code }) ?? list.first ?? AVSpeechSynthesisVoice(language: lang.code)
        return (def, wanted != nil)
    }

    // MARK: Kuyruk
    func enqueue(_ item: Item) {
        if !item.publicSpeaker && !AudioRoute.shared.headphonesActive { return } // hoparlöre özel ses verme
        queue.append(item)
        pump()
    }

    /// Belirli kuşaktan eski öğeleri at (güncelliğini yitirmiş öneriler).
    func dropOlder(than generation: Int) {
        queue.removeAll { $0.generation < generation }
    }

    func stopAll() {
        queue.removeAll()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Kulaklık koptu: çalanı durdur, bekleyenleri at.
    func pauseForHeadphones() {
        queue.removeAll { !$0.publicSpeaker }
        if let c = current, !c.publicSpeaker { synth.stopSpeaking(at: .immediate) }
    }

    private func pump() {
        guard !synth.isSpeaking, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        current = item
        if item.publicSpeaker { AudioRoute.shared.routeToSpeaker(true) }
        let u = AVSpeechUtterance(string: item.text)
        u.voice = resolvedVoice(item.lang).voice
        let s = AppSettings.shared
        let factor = item.rateFactor ?? (item.lang == .tr ? s.trSpeed.factor : s.enSpeed.factor)
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * factor)
        isSpeaking = true
        recentSpoken.append((item.text, Date()))
        recentSpoken = recentSpoken.filter { Date().timeIntervalSince($0.at) < 60 }
        synth.speak(u)
    }

    private func finishCurrent() {
        if current?.publicSpeaker == true { AudioRoute.shared.routeToSpeaker(false) }
        current = nil
        if queue.isEmpty {
            isSpeaking = false
            onFinishedAll?()
        } else {
            pump()
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finishCurrent() }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finishCurrent() }
    }
}
