import Foundation
import Observation
import AVFoundation

/// Dinleme → Whisper ile yazıya dökme → çeviri (+ doğal İngilizce) akışı.
/// Kulaklığa yalnızca kullanıcının bastığı şeyler gider (Çeviriyi Dinle / Doğal İngilizceyi Dinle / Cevap Ver).
@MainActor
@Observable
final class ConversationController {
    static let shared = ConversationController()

    private(set) var turns: [ConversationTurn] = []
    private(set) var level: Float = 0
    private(set) var hearingSpeech = false
    private(set) var transcribing = 0
    private(set) var listening = false
    private(set) var errorText: String?
    private(set) var userPaused = false
    private var overlayPauses = 0
    var hint = ""

    private(set) var lastOwnEnglish: String?

    private let recorder = UtteranceRecorder()
    private let speech = SpeechOutput.shared
    private let route = AudioRoute.shared
    private var queue: [[Float]] = []
    private var working = false

    private init() {
        // Hoparlörden (Karşıya Oku) çalarken mikrofonu yok say: kendi sesimiz yeni söz sayılmasın.
        let sp = speech, rt = route
        recorder.isMuted = { @Sendable in rt.speakerOverride || (sp.isSpeaking && !rt.headphonesActive) }
        recorder.onLevel = { [weak self] l, s in self?.level = l; self?.hearingSpeech = s }
        recorder.onUtterance = { [weak self] samples in self?.enqueue(samples) }
        route.onHeadphonesChanged = { [weak self] on in
            if !on { self?.speech.pauseForHeadphones() }
        }
    }

    var statusLine: String {
        let l: String
        if !AppSettings.shared.setupComplete { l = "Kurulum bekleniyor" }
        else if WhisperEngine.shared.state != .ready { l = "Konuşma modeli hazırlanıyor" }
        else if userPaused { l = "Duraklatıldı" }
        else if overlayPauses > 0 { l = "Dinleme beklemede" }
        else if transcribing > 0 { l = "Yazıya dökülüyor…" }
        else if hearingSpeech { l = "Konuşma algılandı" }
        else if listening { l = "Dinleniyor" }
        else { l = "Dinleme kapalı" }
        return "\(l) · \(route.statusText)"
    }

    // MARK: Dinleme denetimi
    func startIfAllowed() {
        guard AppSettings.shared.setupComplete, !userPaused, overlayPauses == 0, !listening else { return }
        do {
            try recorder.start()
            listening = true
            errorText = nil
        } catch {
            errorText = "Mikrofon başlatılamadı: \(error.localizedDescription)"
        }
    }

    private func stopListening() {
        recorder.stop()
        listening = false
        hearingSpeech = false
    }

    func togglePause() {
        if userPaused { userPaused = false; startIfAllowed() }
        else { userPaused = true; stopListening() }
    }

    func beginOverlay() {
        overlayPauses += 1
        stopListening()
    }

    func endOverlay(applyResumeSetting: Bool = true) {
        overlayPauses = max(0, overlayPauses - 1)
        guard overlayPauses == 0 else { return }
        if applyResumeSetting && AppSettings.shared.resumeBehavior == .manual && !userPaused {
            userPaused = true
        }
        startIfAllowed()
    }

    func setMode(_ m: ConversationMode) { AppSettings.shared.mode = m }

    func newConversation() {
        speech.stopAll()
        turns.removeAll()
        queue.removeAll()
        lastOwnEnglish = nil
        hint = ""
        if !userPaused { startIfAllowed() }
    }

    // MARK: Yazıya dökme kuyruğu (arka arkaya konuşmalar kaybolmasın)
    private func enqueue(_ samples: [Float]) {
        queue.append(samples)
        transcribing = queue.count + (working ? 1 : 0)
        guard !working else { return }
        working = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let s = queue.removeFirst()
            transcribing = queue.count + 1
            if let heard = await WhisperEngine.shared.transcribe(s) {
                await handle(heard)
            }
        }
        working = false
        transcribing = 0
    }

    // MARK: Kart oluşturma
    private func handle(_ heard: HeardTurn) async {
        var turn = ConversationTurn(heard: heard.text, heardLanguage: heard.language)
        turn.tone = ToneLexicon.merge(ToneLexicon.analyze(heard.text), ToneLexicon.sentiment(heard.text))
        turn.naturalPending = heard.language == .en
        turns.append(turn)

        do {
            turn.translation = try await Translator.shared.translate(heard.text, heard.language == .en ? .enToTr : .trToEn)
        } catch {
            turn.status = "Çeviri yapılamadı: dil paketi eksik olabilir"
        }
        update(turn)
        if AppSettings.shared.autoReadTranslation, heard.language == .en, !turn.translation.isEmpty {
            speech.enqueue(.init(text: turn.translation, lang: .tr, rateFactor: nil, generation: 0, publicSpeaker: false))
        }

        // İngilizce söz: 3. satır doğal İngilizce (arka planda)
        if heard.language == .en {
            let id = turn.id
            let prev = englishHistory(before: id)
            Task {
                let nat = await ReplyGenerator.shared.naturalize(heard.text, previous: prev)
                guard var t = self.turns.first(where: { $0.id == id }) else { return }
                t.naturalPending = false
                t.natural = nat?.natural ?? ""
                if let tone = nat?.tone { t.tone = ToneLexicon.merge(t.tone, tone) }
                if nat == nil && t.status.isEmpty { t.status = ReplyGenerator.shared.loadError ?? "Dil modeli hazır değil (Ayarlar → Cevap Modeli)" }
                self.update(t)
            }
        }
    }

    private func update(_ t: ConversationTurn) {
        if let i = turns.firstIndex(where: { $0.id == t.id }) { turns[i] = t }
    }

    /// Kartın İngilizce hâli (bağlam için).
    private func englishOf(_ t: ConversationTurn) -> String {
        if t.heardLanguage == .tr { return t.translation.isEmpty ? t.heard : t.translation }
        return t.natural.isEmpty ? t.heard : t.natural
    }

    private func englishHistory(before id: UUID) -> [ReplyGenerator.ContextTurn] {
        guard let idx = turns.firstIndex(where: { $0.id == id }) else { return [] }
        return turns[..<idx].suffix(20).map { .init(english: englishOf($0)) }
    }

    // MARK: Kart düğmeleri
    /// Türkçe sözün İngilizce çevirisini / İngilizce sözün doğal hâlini kulaklıktan okur.
    func speakEnglishLine(of id: UUID, slow: Bool = false) {
        guard let t = turns.first(where: { $0.id == id }) else { return }
        let text = t.heardLanguage == .tr ? t.translation : (t.natural.isEmpty ? t.heard : t.natural)
        guard !text.isEmpty else { return }
        speech.stopAll()
        speech.enqueue(.init(text: text, lang: .en, rateFactor: slow ? 0.7 : 1.0, generation: 0, publicSpeaker: false))
    }

    /// Cevap Ver: seçilen söze cevap üret, kartın altına yaz ve kulaklıktan oku.
    func reply(to id: UUID) async {
        guard var t = turns.first(where: { $0.id == id }), !t.replying else { return }
        t.replying = true
        t.reply = ""; t.replyTR = ""
        update(t)
        let line = englishOf(t)
        let result = await ReplyGenerator.shared.reply(to: line, history: englishHistory(before: id),
                                                       mode: AppSettings.shared.mode, hint: hint)
        guard var cur = turns.first(where: { $0.id == id }) else { return }
        cur.replying = false
        if let r = result {
            cur.reply = r.reply
            cur.tone = ToneLexicon.merge(cur.tone, r.tone)
            cur.replyTR = (try? await Translator.shared.translate(r.reply, .enToTr)) ?? ""
            hint = ""
            update(cur)
            speech.stopAll()
            speech.enqueue(.init(text: r.reply, lang: .en, rateFactor: nil, generation: 0, publicSpeaker: false))
        } else {
            cur.status = ReplyGenerator.shared.loadError ?? "Cevap modeli hazır değil (Ayarlar → Cevap Modeli)"
            update(cur)
        }
    }

    func replay(_ text: String, slow: Bool) {
        speech.stopAll()
        speech.enqueue(.init(text: text, lang: .en, rateFactor: slow ? 0.7 : 1.0, generation: 0, publicSpeaker: false))
    }

    // MARK: Cümlemi Çevir
    func translateOwn(_ turkish: String) async {
        let t = turkish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var turn = ConversationTurn(heard: t, heardLanguage: .tr)
        turn.isOwnTranslation = true
        turns.append(turn)
        do {
            turn.translation = try await Translator.shared.translate(t, .trToEn)
            lastOwnEnglish = turn.translation
            speech.stopAll()
            speech.enqueue(.init(text: turn.translation, lang: .en, rateFactor: nil, generation: 0, publicSpeaker: false))
        } catch {
            turn.status = "Çeviri yapılamadı: dil paketi eksik olabilir"
        }
        update(turn)
    }

    /// Karşıya Oku: yalnızca son kendi çevirini hoparlörden okur.
    func readAloudToOther() {
        guard let text = lastOwnEnglish else { return }
        speech.stopAll()
        speech.enqueue(.init(text: text, lang: .en, rateFactor: nil, generation: 0, publicSpeaker: true))
    }

    nonisolated static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    }

    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }
}
