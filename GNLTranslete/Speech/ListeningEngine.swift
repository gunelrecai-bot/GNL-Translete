import AVFoundation
import Speech
import NaturalLanguage

struct DeviceSpeechStatus: Hashable { let locale: String; let ready: Bool }

/// Sürekli dinleme: Türkçe ve İngilizce cihaz içi tanıyıcılar aynı sesi paralel işler.
/// Konuşma sırasının bitişi sessizlik + metin ipuçlarıyla algılanır.
final class ListeningEngine {
    private let engine = AVAudioEngine()
    private let locales: [Locale]
    private var recognizers: [SFSpeechRecognizer] = []
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var tasks: [SFSpeechRecognitionTask] = []
    private var latest: [Int: SFSpeechRecognitionResult] = [:]
    private var finals: [Int: SFSpeechRecognitionResult] = [:]

    private var preRoll: [AVAudioPCMBuffer] = []      // ilk heceleri kaçırmamak için ~1.2 sn
    private var preRollFrames: AVAudioFrameCount = 0
    private var speechStarted = false
    private var lastVoiceAt = Date.distantPast
    private var lastTextChangeAt = Date.distantPast
    private var lastText = ""
    private var finalizing = false
    private var timer: Timer?
    private let lock = NSLock()

    var isMuted: () -> Bool = { false }
    var onPartial: ((String) -> Void)?
    var onTurn: ((HeardTurn) -> Void)?
    var onLevel: ((Float) -> Void)?
    private(set) var running = false

    init(locales: [Locale] = [Locale(identifier: "tr-TR"), Locale(identifier: "en-US")]) {
        self.locales = locales
        recognizers = locales.compactMap { SFSpeechRecognizer(locale: $0) }
    }

    static func requestAuth() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// Her dil için cihaz içi tanıma hazır mı?
    static func onDeviceStatus() -> [DeviceSpeechStatus] {
        ["tr-TR", "en-US"].map { id in
            let r = SFSpeechRecognizer(locale: Locale(identifier: id))
            return DeviceSpeechStatus(locale: id, ready: r?.supportsOnDeviceRecognition == true)
        }
    }

    func start() throws {
        guard !running else { return }
        AudioRoute.shared.configure()
        let input = engine.inputNode
        // İsteğe bağlı gürültü azaltma (telefon görüşmesindeki filtre)
        try? input.setVoiceProcessingEnabled(AppSettings.shared.noiseReduction)
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.handle(buf)
        }
        engine.prepare()
        try engine.start()
        running = true
        startRequests()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.checkEndpoint() }
    }

    func stop() {
        guard running else { return }
        timer?.invalidate(); timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        cancelRequests()
        running = false
        speechStarted = false
    }

    // MARK: İstekler
    private func startRequests() {
        lock.lock(); defer { lock.unlock() }
        latest = [:]; finals = [:]; lastText = ""; finalizing = false; speechStarted = false
        requests = []; tasks = []
        for (i, r) in recognizers.enumerated() {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true
            req.addsPunctuation = true
            req.taskHint = .dictation
            // önceki sessizlikteki sesi ekle: karşıdaki kişinin ilk sözleri kaybolmasın
            for b in preRoll { req.append(b) }
            let task = r.recognitionTask(with: req) { [weak self] res, err in
                guard let self, let res else { return }
                self.lock.lock()
                self.latest[i] = res
                if res.isFinal { self.finals[i] = res }
                self.lock.unlock()
                if !res.isFinal { DispatchQueue.main.async { self.partialUpdated() } }
            }
            requests.append(req); tasks.append(task)
        }
    }

    private func cancelRequests() {
        lock.lock(); defer { lock.unlock() }
        tasks.forEach { $0.cancel() }
        requests.forEach { $0.endAudio() }
        tasks = []; requests = []
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        let muted = isMuted()
        let level = rms(buf)
        DispatchQueue.main.async { self.onLevel?(level) }
        if level > 0.012 && !muted { lastVoiceAt = Date() }
        // ön-kayıt tamponu
        lock.lock()
        if !muted, let copy = buf.copyBuffer() {
            preRoll.append(copy); preRollFrames += copy.frameLength
            let maxFrames = AVAudioFrameCount(buf.format.sampleRate * 1.2)
            while preRollFrames > maxFrames, let f = preRoll.first { preRollFrames -= f.frameLength; preRoll.removeFirst() }
        }
        let reqs = requests; let fin = finalizing
        lock.unlock()
        if muted { return }
        if !fin { reqs.forEach { $0.append(buf) } }
    }

    private func partialUpdated() {
        let best = bestCandidate(final: false)?.text ?? ""
        if best != lastText {
            lastText = best
            lastTextChangeAt = Date()
            if !best.isEmpty { speechStarted = true; onPartial?(best) }
        }
    }

    /// Doğal duraksamada erken bölmeden sıra sonu.
    private func checkEndpoint() {
        guard running, speechStarted, !finalizing else { return }
        let silence = Date().timeIntervalSince(max(lastVoiceAt, lastTextChangeAt))
        let t = lastText.trimmingCharacters(in: .whitespaces)
        let complete = t.hasSuffix("?") || t.hasSuffix(".") || t.hasSuffix("!")
        let words = t.split(separator: " ").count
        // kısa ve bitmemiş görünen cümlelere daha uzun süre tanı
        let needed: TimeInterval = complete ? 0.9 : (words < 4 ? 1.8 : 1.4)
        if silence >= needed { finalizeTurn() }
    }

    private func finalizeTurn() {
        lock.lock(); finalizing = true; let reqs = requests
        preRoll.removeAll(); preRollFrames = 0   // biten sıranın kuyruğu yeni sıraya taşınmasın
        lock.unlock()
        reqs.forEach { $0.endAudio() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let cand = self.bestCandidate(final: true)
            self.cancelRequests()
            if self.running { self.startRequests() }
            if let cand, !cand.text.isEmpty { self.onTurn?(cand) }
        }
    }

    // MARK: Dil seçimi
    private func bestCandidate(final: Bool) -> HeardTurn? {
        lock.lock(); let src = final ? finals.merging(latest) { a, _ in a } : latest; lock.unlock()
        var best: (HeardTurn, Double)?
        var langScores: [DetectedLanguage: Double] = [:]
        for (i, res) in src {
            let text = res.bestTranscription.formattedString
            guard !text.isEmpty, i < locales.count else { continue }
            let segs = res.bestTranscription.segments
            let conf = segs.isEmpty ? 0.5 : Double(segs.map(\.confidence).reduce(0, +)) / Double(segs.count)
            let lang: DetectedLanguage = locales[i].identifier.hasPrefix("tr") ? .tr : .en
            let nl = NLLanguageRecognizer()
            nl.languageConstraints = [.turkish, .english]
            nl.processString(text)
            let hyp = nl.languageHypotheses(withMaximum: 2)
            let match = hyp[lang == .tr ? .turkish : .english] ?? 0
            langScores[lang] = match
            let score = (final && conf > 0 ? conf : 0.5) * 0.5 + match * 0.5
            if best == nil || score > best!.1 { best = (HeardTurn(text: text, language: lang, confidence: Float(conf)), score) }
        }
        guard var b = best?.0 else { return nil }
        if let tr = langScores[.tr], let en = langScores[.en], tr > 0.3, en > 0.3 {
            b = HeardTurn(text: b.text, language: .mixed, confidence: b.confidence)
        }
        return b
    }

    private func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData?[0] else { return 0 }
        let n = Int(b.frameLength); if n == 0 { return 0 }
        var s: Float = 0
        for i in 0..<n { s += ch[i] * ch[i] }
        return sqrt(s / Float(n))
    }
}

extension AVAudioPCMBuffer {
    func copyBuffer() -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        c.frameLength = frameLength
        if let s = floatChannelData, let d = c.floatChannelData {
            for ch in 0..<Int(format.channelCount) { d[ch].update(from: s[ch], count: Int(frameLength)) }
        }
        return c
    }
}
