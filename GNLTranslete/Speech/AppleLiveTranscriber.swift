import Foundation
import AVFoundation
import Speech
import NaturalLanguage
import Observation
import UIKit

/// iOS 26+ SpeechAnalyzer / SpeechTranscriber: Apple'ın yeni cihaz içi konuşma motoru.
/// Konuşurken anlık (volatile) metin verir; Türkçe ve İngilizce iki ayrı motor aynı sesi paralel dinler,
/// dil güven puanı + metin dili kontrolüyle seçilir.
@Observable
final class AppleSpeechSupport {
    static let shared = AppleSpeechSupport()
    enum State: Equatable { case checking, unsupported(String), needsAssets, installing, ready, failed(String) }
    private(set) var state: State = .checking

    static let tr = Locale(identifier: "tr-TR")
    static let en = Locale(identifier: "en-US")

    var isReady: Bool { state == .ready }
    /// Türkçe yeni motorda yoksa Apple Dikte motoru (DictationTranscriber) kullanılır.
    private(set) var turkishViaDictation = false

    static func module(for lang: DetectedLanguage, dictation: Bool, volatile: Bool) -> any SpeechModule {
        let loc = lang == .tr ? tr : en
        let rep: Set<SpeechTranscriber.ReportingOption> = volatile ? [.volatileResults] : []
        if lang == .tr && dictation {
            return DictationTranscriber(locale: loc, contentHints: [], transcriptionOptions: [],
                                        reportingOptions: volatile ? [.volatileResults] : [],
                                        attributeOptions: [.transcriptionConfidence])
        }
        return SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: rep, attributeOptions: [.transcriptionConfidence])
    }

    @MainActor
    func check() async {
        guard SpeechTranscriber.isAvailable else { state = .unsupported("Bu cihazda yeni konuşma motoru yok"); return }
        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        let hasEN = supported.contains { $0.hasPrefix("en") }
        var hasTR = supported.contains { $0.hasPrefix("tr") }
        turkishViaDictation = false
        if !hasTR {
            let dict = await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
            if dict.contains(where: { $0.hasPrefix("tr") }) { hasTR = true; turkishViaDictation = true }
        }
        guard hasTR && hasEN else {
            state = .unsupported(hasEN ? "Türkçe desteklenmiyor" : "İngilizce desteklenmiyor")
            return
        }
        let enInstalled = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47).hasPrefix("en") }
        let trInstalled = turkishViaDictation
            ? await DictationTranscriber.installedLocales.contains { $0.identifier(.bcp47).hasPrefix("tr") }
            : await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47).hasPrefix("tr") }
        state = (enInstalled && trInstalled) ? .ready : .needsAssets
    }

    @MainActor
    func install() async {
        state = .installing
        do {
            for lang in [DetectedLanguage.tr, .en] {
                let m = Self.module(for: lang, dictation: turkishViaDictation, volatile: false)
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [m]) {
                    try await req.downloadAndInstall()
                }
            }
            await check()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var statusText: String {
        switch state {
        case .checking: "Kontrol ediliyor…"
        case .unsupported(let why): "Kullanılamıyor: \(why). Whisper kullanılacak."
        case .needsAssets: "Türkçe/İngilizce dil dosyaları indirilmedi"
        case .installing: "İndiriliyor…"
        case .ready: turkishViaDictation
            ? "Hazır · İngilizce: yeni motor, Türkçe: Apple Dikte · anlık · çevrimdışı"
            : "Hazır · anlık yazıya dökme · çevrimdışı"
        case .failed(let e): "Hata: \(e)"
        }
    }
}

/// Canlı dinleme motoru (Apple). Sıra bitince en olası dildeki metni verir.
final class AppleLiveTranscriber {
    private struct Lane {
        let lang: DetectedLanguage
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        var finalText = ""
        var volatileText = ""
        var confSum = 0.0
        var confCount = 0
        var votes = 0.0      // canlı önizlemede bu dilin kaç kez önde olduğu (uzunlukla ağırlıklı)
    }

    private let engine = AVAudioEngine()
    private var lanes: [Lane] = []
    private var tasks: [Task<Void, Never>] = []
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private let lock = NSLock()

    private var inSpeech = false
    private var silence: TimeInterval = 0
    private var speechTime: TimeInterval = 0
    private var noiseFloor: Float = 0.006
    private var lastChange = Date()

    var langs: [DetectedLanguage]
    var endSilence: TimeInterval = 0.8
    var isMuted: () -> Bool = { false }
    var onPartial: ((String) -> Void)?
    var onTurn: ((HeardTurn) -> Void)?
    var onLevel: ((Float, Bool) -> Void)?
    private(set) var running = false

    init(langs: [DetectedLanguage] = [.tr, .en]) { self.langs = langs }

    func start() async throws {
        guard !running else { return }
        AudioRoute.shared.configure()
        var built: [Lane] = []
        var modules: [any SpeechModule] = []
        let dict = AppleSpeechSupport.shared.turkishViaDictation
        for (i, l) in langs.enumerated() {
            let m = AppleSpeechSupport.module(for: l, dictation: dict, volatile: true)
            modules.append(m)
            // sonuçları dinle (modül türüne göre)
            if let t = m as? SpeechTranscriber {
                tasks.append(Task { [weak self] in
                    do { for try await r in t.results { self?.receive(lane: i, text: String(r.text.characters), isFinal: r.isFinal, conf: Self.confidence(r.text)) } } catch {}
                })
            } else if let t = m as? DictationTranscriber {
                tasks.append(Task { [weak self] in
                    do { for try await r in t.results { self?.receive(lane: i, text: String(r.text.characters), isFinal: r.isFinal, conf: Self.confidence(r.text)) } } catch {}
                })
            }
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            let a = SpeechAnalyzer(modules: [m])
            try await a.start(inputSequence: stream)
            built.append(Lane(lang: l, analyzer: a, input: cont))
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        lock.lock(); lanes = built; lock.unlock()

        let input = engine.inputNode
        // İsteğe bağlı gürültü azaltma (telefon görüşmesindeki filtre)
        try? input.setVoiceProcessingEnabled(AppSettings.shared.noiseReduction)
        let inFormat = input.outputFormat(forBus: 0)
        if let f = analyzerFormat { converter = AVAudioConverter(from: inFormat, to: f) }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in self?.process(buf) }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        lock.lock(); let hasLanes = !lanes.isEmpty; lock.unlock()
        guard running || hasLanes else { return }   // başlatma yarıdayken de durdurulabilsin
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let ls = lanes
        lanes = []
        lock.unlock()
        for l in ls { l.input.finish(); Task { await l.analyzer.cancelAndFinishNow() } }
        tasks.forEach { $0.cancel() }
        tasks = []
        running = false
        inSpeech = false
    }

    /// Konuya göre ipucu: sohbette geçen kelimeleri motora verir (yalnızca telefonda, kaydedilmez).
    func updateContext(_ words: [String]) {
        lock.lock(); let ls = lanes; lock.unlock()
        guard !ls.isEmpty else { return }
        Task {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = words
            for l in ls { try? await l.analyzer.setContext(ctx) }
        }
    }

    private static func confidence(_ s: AttributedString) -> Double? {
        var sum = 0.0, n = 0
        for run in s.runs {
            if let c = run.transcriptionConfidence { sum += c; n += 1 }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    private func receive(lane i: Int, text: String, isFinal: Bool, conf: Double?) {
        lock.lock()
        guard i < lanes.count else { lock.unlock(); return }
        if isFinal {
            lanes[i].finalText += (lanes[i].finalText.isEmpty ? "" : " ") + text.trimmingCharacters(in: .whitespaces)
            lanes[i].volatileText = ""
            if let conf { lanes[i].confSum += conf; lanes[i].confCount += 1 }
        } else {
            lanes[i].volatileText = text
        }
        lastChange = Date()
        let previewTurn = bestLocked()
        if let p = previewTurn, let k = lanes.firstIndex(where: { $0.lang == p.language }) {
            lanes[k].votes += Double(p.text.count)
        }
        let preview = previewTurn?.text ?? ""
        lock.unlock()
        DispatchQueue.main.async { if !preview.isEmpty { self.onPartial?(preview) } }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        let muted = isMuted()
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for k in 0..<n { sum += ch[k] * ch[k] }
        let rms = sqrt(sum / Float(max(n, 1)))
        let dur = Double(n) / buf.format.sampleRate

        // VAD: sıra sonu tespiti
        if !inSpeech { noiseFloor = 0.95 * noiseFloor + 0.05 * min(rms, 0.05) }
        let voiced = !muted && rms > max(0.02, noiseFloor * 4)
        var endTurn = false
        if voiced { inSpeech = true; silence = 0; speechTime += dur }
        else if inSpeech {
            silence += dur
            if silence >= endSilence { endTurn = true; inSpeech = false; silence = 0 }
        }
        let speaking = inSpeech
        DispatchQueue.main.async { self.onLevel?(rms, speaking) }

        if !muted, let converter, let fmt = analyzerFormat {
            let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate + 32)
            if let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) {
                var fed = false
                var err: NSError?
                converter.convert(to: out, error: &err) { _, st in
                    if fed { st.pointee = .noDataNow; return nil }
                    fed = true; st.pointee = .haveData; return buf
                }
                if out.frameLength > 0 {
                    lock.lock(); let ls = lanes; lock.unlock()
                    for l in ls { l.input.yield(AnalyzerInput(buffer: out)) }
                }
            }
        }

        if endTurn {
            let spoken = speechTime
            speechTime = 0
            // son kelimelerin kesinleşmesi için kısa bekleme
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.finishTurn(spoken: spoken) }
        }
    }

    private func finishTurn(spoken: TimeInterval) {
        lock.lock()
        let snapshot = lanes
        for i in lanes.indices {
            lanes[i].finalText = ""; lanes[i].volatileText = ""; lanes[i].confSum = 0; lanes[i].confCount = 0; lanes[i].votes = 0
        }
        lock.unlock()
        guard spoken >= 0.4, let best = Self.decide(snapshot, final: true),
              !best.text.isEmpty, best.text.filter(\.isLetter).count >= 2 else { return }
        onTurn?(best)
    }

    /// Canlı önizleme için hızlı seçim (yazım denetimi yok).
    private func bestLocked() -> HeardTurn? { Self.decide(lanes, final: false) }

    /// Dil seçimi. Yanlış dildeki motor genellikle sözlükte olmayan kelimeler üretir
    /// ("merhaba" → "Madama"); bu yüzden asıl ölçüt: kelimelerin o dilin sözlüğünde olması.
    /// Ek ölçütler: metnin dili (NaturalLanguage), canlı önizlemedeki önde olma oyu, (ikisinde de varsa) motor güveni.
    private static func decide(_ lanes: [Lane], final: Bool) -> HeardTurn? {
        let texts = lanes.map { ($0.finalText + " " + $0.volatileText).trimmingCharacters(in: .whitespaces) }
        let bothConf = lanes.allSatisfy { $0.confCount > 0 }
        let totalVotes = max(1, lanes.map(\.votes).reduce(0, +))
        var best: (HeardTurn, Double)?
        for (i, l) in lanes.enumerated() {
            let text = texts[i]
            guard !text.isEmpty else { continue }
            let conf = l.confCount > 0 ? l.confSum / Double(l.confCount) : 0.5
            let nl = NLLanguageRecognizer()
            nl.languageConstraints = [.turkish, .english]
            nl.processString(text)
            let match = nl.languageHypotheses(withMaximum: 2)[l.lang == .tr ? .turkish : .english] ?? 0
            var score: Double
            if final {
                let valid = dictionaryRatio(text, lang: l.lang)
                score = valid * 0.5 + match * 0.3 + (l.votes / totalVotes) * 0.2
                if bothConf { score = score * 0.85 + conf * 0.15 }
            } else {
                score = match * 0.7 + (bothConf ? conf * 0.3 : 0.15)
            }
            if best == nil || score > best!.1 { best = (HeardTurn(text: text, language: l.lang, confidence: Float(conf)), score) }
        }
        return best?.0
    }

    /// Kelimelerin ne kadarı o dilin sözlüğünde var (0…1).
    static func dictionaryRatio(_ text: String, lang: DetectedLanguage) -> Double {
        let code = lang == .tr ? "tr_TR" : "en_US"
        guard UITextChecker.availableLanguages.contains(code) else { return 0.5 }
        let words = text.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 2 }
        guard !words.isEmpty else { return 0 }
        let checker = UITextChecker()
        var ok = 0
        for w in words {
            let r = checker.rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: (w as NSString).length),
                                                  startingAt: 0, wrap: false, language: code)
            if r.location == NSNotFound { ok += 1 }
        }
        return Double(ok) / Double(words.count)
    }
}
