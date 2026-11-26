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
            return DictationTranscriber(locale: loc, contentHints: [], transcriptionOptions: [.punctuation],
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

/// Canlı dinleme motoru (Apple). Mikrofon sesini motorlara verir; metinden karta dönüşüm TurnAssembler'da.
final class AppleLiveTranscriber {
    private struct Lane {
        let lang: DetectedLanguage
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
    }

    private let engine = AVAudioEngine()
    private var lanes: [Lane] = []
    private var tasks: [Task<Void, Never>] = []
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private let lock = NSLock()
    private var assembler: TurnAssembler

    var langs: [DetectedLanguage]
    var endSilence: TimeInterval = 0.8 { didSet { assembler.endSilence = endSilence } }
    var isMuted: () -> Bool = { false }
    var onPartial: ((String) -> Void)?
    var onPartialTurn: ((HeardTurn) -> Void)?
    private var segmenting = false
    var onTurn: ((HeardTurn) -> Void)?
    var onLevel: ((Float, Bool) -> Void)?
    private(set) var running = false

    init(langs: [DetectedLanguage] = [.tr, .en]) {
        self.langs = langs
        assembler = TurnAssembler(langs: langs)
    }

    func start() async throws {
        guard !running else { return }
        AudioRoute.shared.configure()
        assembler = TurnAssembler(langs: langs)
        assembler.endSilence = endSilence
        var built: [Lane] = []
        var modules: [any SpeechModule] = []
        let dict = AppleSpeechSupport.shared.turkishViaDictation
        for (i, l) in langs.enumerated() {
            let m = AppleSpeechSupport.module(for: l, dictation: dict, volatile: true)
            modules.append(m)
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

    static func confidence(_ s: AttributedString) -> Double? {
        var sum = 0.0, n = 0
        for run in s.runs {
            if let c = run.transcriptionConfidence { sum += c; n += 1 }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    private func receive(lane i: Int, text: String, isFinal: Bool, conf: Double?) {
        let preview = assembler.receive(lane: i, text: text, isFinal: isFinal, conf: conf)
        let turn = assembler.lastPreview
        DispatchQueue.main.async {
            if !preview.isEmpty { self.onPartial?(preview) }
            if let turn { self.onPartialTurn?(turn) }
        }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        let muted = isMuted()
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for k in 0..<n { sum += ch[k] * ch[k] }
        let rms = sqrt(sum / Float(max(n, 1)))
        let dip = minWindowRms(ch, n, buf.format.sampleRate)   // yükseltmeden önce ölç
        // Kısık gelen sesi (uzaktaki konuşmacı, bilgisayar hoparlörü) yükselt; sessizlik kararı da yükseltilmiş sesle
        let gain = assembler.gain(for: rms)
        if gain > 1.05 { for k in 0..<n { ch[k] = max(-1, min(1, ch[k] * gain)) } }
        let v = assembler.vad(rms: rms * gain, duration: Double(n) / buf.format.sampleRate, muted: muted, dipRms: dip * gain)
        DispatchQueue.main.async { self.onLevel?(rms, v.speaking) }

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

        if v.midSegment && !segmenting {
            // Konuşmacı susmadan, nefes arasında: o ana kadarki kısmı kart yap, dinlemeye devam et
            segmenting = true
            lock.lock(); let analyzers = lanes.map(\.analyzer); lock.unlock()
            let carry = v.carryTail, force = v.forceCut
            Task { [weak self] in
                await Self.finalizeQuickly(analyzers)
                guard let self else { return }
                let turn = self.assembler.finish(spoken: 1.0, carryTail: carry, forceCut: force)
                self.segmenting = false
                DispatchQueue.main.async { if let turn { self.onTurn?(turn) } }
            }
        }
        if v.endTurn {
            // Önce motorlara "bu ana kadarki sesi kesinleştir" de, kesin sonuçlar gelsin; sonra kartı üret.
            lock.lock(); let analyzers = lanes.map(\.analyzer); lock.unlock()
            let spoken = v.spoken
            Task { [weak self] in
                await Self.finalizeQuickly(analyzers)
                guard let self else { return }
                let turn = self.assembler.finish(spoken: spoken)
                DispatchQueue.main.async { if let turn { self.onTurn?(turn) } }
            }
        }
    }

    /// Motorlara "kesinleştir" de ama en fazla 1,2 sn bekle: konuşma sürerken motor takılırsa kart üretimi durmasın.
    static func finalizeQuickly(_ analyzers: [SpeechAnalyzer]) async {
        final class Once: @unchecked Sendable { var done = false; let l = NSLock()
            func fire() -> Bool { l.lock(); defer { l.unlock() }; if done { return false }; done = true; return true } }
        let once = Once()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Task { for a in analyzers { try? await a.finalize(through: nil) }
                   try? await Task.sleep(for: .milliseconds(200)); if once.fire() { c.resume() } }
            Task { try? await Task.sleep(for: .milliseconds(1200)); if once.fire() { c.resume() } }
        }
    }
}
