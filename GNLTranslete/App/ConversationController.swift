import Foundation
import Observation
import AVFoundation

/// Dinleme → çeviri → ton → yeni cevap → kulaklık akışını yönetir.
@MainActor
@Observable
final class ConversationController {
    static let shared = ConversationController()

    private(set) var turns: [ConversationTurn] = []
    private(set) var partial = ""
    private(set) var level: Float = 0
    private(set) var listening = false
    private(set) var errorText: String?
    /// Kullanıcı bilerek Duraklat'a bastı
    private(set) var userPaused = false
    /// Kamera / Kaydedilenler açık
    private var overlayPauses = 0
    var hint = ""   // Türkçe İpucu (bir sonraki cevap için)

    /// Son "Cümlemi Çevir" sonucu: Karşıya Oku bunu okur
    private(set) var lastOwnEnglish: String?

    private var generation = 0
    private let listener = ListeningEngine()
    private let speech = SpeechOutput.shared
    private let route = AudioRoute.shared
    private var lastSuggestion: String?

    private init() {
        // Kendi sesimizi yeni söz olarak işlemeyelim: hoparlörden çalarken mikrofonu yok say.
        let sp = speech, rt = route
        listener.isMuted = { @Sendable in rt.speakerOverride || (sp.isSpeaking && !rt.headphonesActive) }
        listener.onPartial = { [weak self] t in self?.partial = t }
        listener.onLevel = { [weak self] l in self?.level = l }
        listener.onTurn = { [weak self] t in
            Task { @MainActor in await self?.handle(t) }
        }
        route.onHeadphonesChanged = { [weak self] on in
            guard let self else { return }
            if !on { self.speech.pauseForHeadphones() }
            // açıldığında: aynı sohbetten devam; eski sesler çalınmaz
        }
    }

    var headphonesReady: Bool { route.headphonesActive }

    var statusLine: String {
        let l: String
        if !AppSettings.shared.setupComplete { l = "Kurulum bekleniyor" }
        else if userPaused { l = "Duraklatıldı" }
        else if overlayPauses > 0 { l = "Dinleme beklemede" }
        else if listening { l = "Dinleniyor" }
        else { l = "Dinleme kapalı" }
        return "\(l) · \(route.statusText)"
    }

    // MARK: Dinleme denetimi
    func startIfAllowed() {
        guard AppSettings.shared.setupComplete, !userPaused, overlayPauses == 0, !listening else { return }
        do {
            try listener.start()
            listening = true
            errorText = nil
        } catch {
            errorText = "Mikrofon başlatılamadı: \(error.localizedDescription)"
        }
    }

    private func stopListening() {
        listener.stop()
        listening = false
        partial = ""
    }

    func togglePause() {
        if userPaused { userPaused = false; startIfAllowed() }
        else { userPaused = true; stopListening() }
    }

    /// Kamera veya Kaydedilenler açılınca
    func beginOverlay() {
        overlayPauses += 1
        stopListening()
    }

    /// Ana ekrana dönüş. Elle Devam Et seçiliyse kullanıcı Devam Et'e basana kadar bekler.
    func endOverlay(applyResumeSetting: Bool = true) {
        overlayPauses = max(0, overlayPauses - 1)
        guard overlayPauses == 0 else { return }
        if applyResumeSetting && AppSettings.shared.resumeBehavior == .manual && !userPaused {
            userPaused = true
        }
        startIfAllowed()
    }

    func setMode(_ m: ConversationMode) {
        AppSettings.shared.mode = m   // bağlam korunur
    }

    func newConversation() {
        generation += 1
        speech.stopAll()
        turns.removeAll()
        lastSuggestion = nil
        lastOwnEnglish = nil
        hint = ""
        partial = ""
        if !userPaused { startIfAllowed() }
    }

    // MARK: Akış
    private func handle(_ heard: HeardTurn) async {
        partial = ""
        if isEcho(heard.text) { return }

        // Seyahat modunda Türkçe söz kullanıcının kendisidir: cevap önerisi değil, İngilizcesi gerekir.
        if heard.language == .tr && AppSettings.shared.mode == .travel {
            await translateOwn(heard.text)
            return
        }

        generation += 1
        let gen = generation
        speech.dropOlder(than: gen)    // güncelliğini yitirmiş öneriler kuyrukta birikmesin
        let mode = AppSettings.shared.mode
        var turn = ConversationTurn(generation: gen, heard: heard.text, heardLanguage: heard.language)
        turn.tone = ToneLexicon.analyze(heard.text)
        turns.append(turn)

        // 1) Çeviri (önce, cevabı beklemeden seslendirilir)
        do {
            switch heard.language {
            case .en:
                turn.translation = try await Translator.shared.translate(heard.text, .enToTr)
            case .tr:
                turn.translation = try await Translator.shared.translate(heard.text, .trToEn)
            case .mixed:
                async let trMeaning = Translator.shared.translate(heard.text, .enToTr)
                async let enVersion = Translator.shared.translate(heard.text, .trToEn)
                turn.translation = try await trMeaning
                turn.englishEquivalent = try await enVersion
            }
            turn.status = "Cevap hazırlanıyor…"
        } catch {
            turn.status = "Çeviri yapılamadı: dil paketi eksik olabilir"
        }
        update(turn)

        if !turn.tone.isEmpty {
            speech.enqueue(.init(text: turn.tone.shortWarning, lang: .tr, rateFactor: nil, generation: gen, publicSpeaker: false))
        }
        switch heard.language {
        case .en, .mixed:
            if !turn.translation.isEmpty { speech.enqueue(.init(text: turn.translation, lang: .tr, rateFactor: nil, generation: gen, publicSpeaker: false)) }
            if heard.language == .mixed, !turn.englishEquivalent.isEmpty {
                speech.enqueue(.init(text: turn.englishEquivalent, lang: .en, rateFactor: nil, generation: gen, publicSpeaker: false))
            }
        case .tr:
            if !turn.translation.isEmpty { speech.enqueue(.init(text: turn.translation, lang: .en, rateFactor: nil, generation: gen, publicSpeaker: false)) }
        }

        // 2) Bağlama uygun yeni cevap
        let englishLine = heard.language == .tr ? turn.translation : (turn.englishEquivalent.isEmpty ? heard.text : turn.englishEquivalent)
        let history = contextHistory(excluding: turn.id)
        let currentHint = hint
        let result = await ReplyGenerator.shared.generate(history: history, latestEnglish: englishLine, mode: mode, hint: currentHint)
        guard turns.contains(where: { $0.id == turn.id }) else { return }   // Yeni Sohbet ile temizlendiyse

        if let r = result {
            turn.suggestion = r.reply
            turn.topic = r.topic
            turn.tone = ToneLexicon.merge(turn.tone, r.tone)
            if heard.language == .en, mode == .home, !r.natural.isEmpty,
               r.natural.lowercased() != heard.text.lowercased() {
                turn.englishEquivalent = r.natural
            }
            turn.suggestionTR = (try? await Translator.shared.translate(r.reply, .enToTr)) ?? ""
            turn.status = ""
            hint = ""   // İpucu yalnızca bir sonraki cevabı yönlendirir
            lastSuggestion = r.reply
        } else {
            turn.status = ReplyGenerator.shared.loadError ?? "Cevap modeli hazır değil (Kurulum'a bakın)"
        }
        update(turn)

        // Ev modunda İngilizce söz: Türkçe anlamdan sonra doğal İngilizce karşılık
        if heard.language == .en, mode == .home, !turn.englishEquivalent.isEmpty, gen == generation {
            speech.enqueue(.init(text: turn.englishEquivalent, lang: .en, rateFactor: nil, generation: gen, publicSpeaker: false))
        }
        // Yeni bir söz gelmediyse öneriyi oku (Türkçesi seslendirilmez)
        if !turn.suggestion.isEmpty, gen == generation {
            speech.enqueue(.init(text: "Sen söyle", lang: .tr, rateFactor: nil, generation: gen, publicSpeaker: false))
            speech.enqueue(.init(text: turn.suggestion, lang: .en, rateFactor: nil, generation: gen, publicSpeaker: false))
        }
    }

    private func update(_ t: ConversationTurn) {
        if let i = turns.firstIndex(where: { $0.id == t.id }) { turns[i] = t }
    }

    private func contextHistory(excluding id: UUID) -> [ReplyGenerator.ContextTurn] {
        var out: [ReplyGenerator.ContextTurn] = []
        for t in turns.suffix(21) where t.id != id {
            let line: String
            if t.isOwnTranslation { line = t.translation }
            else if t.heardLanguage == .tr { line = t.translation.isEmpty ? t.heard : t.translation }
            else { line = t.englishEquivalent.isEmpty ? t.heard : t.englishEquivalent }
            out.append(.init(speaker: t.isOwnTranslation ? "User" : "Other", english: line))
        }
        return Array(out.suffix(20))
    }

    /// Kullanıcının öneriyi tekrar etmesi veya uygulamanın kendi sesi yeni soru sayılmaz.
    private func isEcho(_ text: String) -> Bool {
        let recent = speech.recentSpoken.filter { Date().timeIntervalSince($0.at) < 25 }.map(\.text)
        let candidates = recent + [lastSuggestion, lastOwnEnglish].compactMap { $0 }
        return candidates.contains { Self.similarity($0, text) > 0.6 }
    }

    nonisolated static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    }

    nonisolated static func similarity(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    // MARK: Kart düğmeleri
    func replay(_ text: String, slow: Bool) {
        speech.enqueue(.init(text: text, lang: .en, rateFactor: slow ? 0.7 : 1.0, generation: generation, publicSpeaker: false))
    }

    // MARK: Cümlemi Çevir
    func translateOwn(_ turkish: String) async {
        let t = turkish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        generation += 1
        let gen = generation
        speech.dropOlder(than: gen)
        var turn = ConversationTurn(generation: gen, heard: t, heardLanguage: .tr)
        turn.isOwnTranslation = true
        turns.append(turn)
        do {
            turn.translation = try await Translator.shared.translate(t, .trToEn)
            turn.status = ""
            lastOwnEnglish = turn.translation
            speech.enqueue(.init(text: turn.translation, lang: .en, rateFactor: nil, generation: gen, publicSpeaker: false))
        } catch {
            turn.status = "Çeviri yapılamadı: dil paketi eksik olabilir"
        }
        update(turn)
    }

    /// Karşıya Oku: yalnızca son kendi çevirini hoparlörden okur.
    func readAloudToOther() {
        guard let text = lastOwnEnglish else { return }
        speech.enqueue(.init(text: text, lang: .en, rateFactor: nil, generation: generation, publicSpeaker: true))
    }
}
