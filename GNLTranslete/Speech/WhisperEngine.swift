import Foundation
import AVFoundation
import Observation
import WhisperKit
import NaturalLanguage

/// Whisper (large-v3 turbo, sıkıştırılmış ~630 MB, MIT) ile cihaz içi konuşma tanıma.
/// Türkçe/İngilizce dil ayrımı Whisper'ın kendi dil tespitiyle yapılır.
enum WhisperSize: String, CaseIterable {
    case turbo, small
    var variant: String { self == .turbo ? "openai_whisper-large-v3-v20240930_turbo_632MB" : "openai_whisper-small_216MB" }
    var title: String { self == .turbo ? "En isabetli, yavaş (Turbo, ~630 MB)" : "Hızlı (Small, ~220 MB) — önerilen" }
}

@Observable
final class WhisperEngine {
    static let shared = WhisperEngine()
    static let repo = "argmaxinc/whisperkit-coreml"

    enum State: Equatable { case missing, standby, downloading(Double), loading, ready, failed(String) }
    private(set) var state: State = .missing
    private(set) var stage = ""
    private(set) var loadStarted: Date?
    private var preparing = false
    private var pipe: WhisperKit?
    private let d = UserDefaults.standard

    var size: WhisperSize {
        get { WhisperSize(rawValue: d.string(forKey: "whisperSize") ?? "") ?? .small }
        set { d.set(newValue.rawValue, forKey: "whisperSize") }
    }
    var approxSize: String { size == .turbo ? "~630 MB" : "~220 MB" }

    /// Uygulama güncellenince kapsayıcı yolu değişir; bu yüzden göreli yol saklanır.
    private var base: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private var relKey: String { "whisperRel-\(size.rawValue)" }
    private var modelFolder: URL? {
        guard let rel = d.string(forKey: relKey) else { return nil }
        let u = base.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: u.appendingPathComponent("AudioEncoder.mlmodelc").path) ? u : nil
    }
    var isDownloaded: Bool { modelFolder != nil }

    private init() {
        state = isDownloaded ? .standby : .missing
    }

    /// Belleği boşalt (arka plan ya da Apple motoru varken). Dosya yerinde kalır.
    func unload() {
        guard pipe != nil || state == .loading else { return }
        pipe = nil
        state = isDownloaded ? .standby : .missing
    }

    /// Yalnızca indir (belleğe yükleme). Yedek olarak hazır bekler.
    @MainActor
    func downloadOnly() async {
        guard !isDownloaded else { state = .standby; return }
        await prepare()
        unload()
    }

    /// Küçük / büyük model arasında geçiş.
    @MainActor
    func switchSize(_ s: WhisperSize) async {
        size = s
        pipe = nil
        state = isDownloaded ? .standby : .missing
    }

    /// İndir (gerekirse) ve belleğe yükle.
    @MainActor
    func prepare() async {
        if preparing { return }
        if state == .ready, pipe != nil { return }
        preparing = true
        defer { preparing = false }
        do {
            var folder = modelFolder
            if folder == nil {
                state = .downloading(0)
                stage = "İndiriliyor"
                let url = try await WhisperKit.download(variant: size.variant, downloadBase: base, from: Self.repo, progressCallback: { p in
                    Task { @MainActor in WhisperEngine.shared.state = .downloading(p.fractionCompleted) }
                })
                let rel = url.path.replacingOccurrences(of: base.path + "/", with: "")
                d.set(rel, forKey: relKey)
                folder = url
            }
            state = .loading
            loadStarted = Date()
            stage = "Model dosyaları açılıyor"
            let started = loadStarted
            // 4 dakikayı geçerse takıldı say ve kullanıcıya küçük modeli öner
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(240))
                if self.state == .loading, self.loadStarted == started {
                    self.state = .failed("Hazırlama 4 dakikayı geçti (aşama: \(self.stage)). Uygulamayı kapatıp açmayı ya da Small modeli deneyin.")
                }
            }
            // Kodlayıcı GPU'da: Neural Engine'in ilk seferdeki uzun derleme beklemesine takılmasın.
            let compute = size == .turbo
                ? ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndNeuralEngine)
                : ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
            let config = WhisperKitConfig(modelFolder: folder!.path, tokenizerFolder: base, computeOptions: compute,
                                          verbose: false, prewarm: false, load: false, download: false)
            let p = try await WhisperKit(config)
            p.modelStateCallback = { _, new in
                Task { @MainActor in WhisperEngine.shared.stage = "\(new)" }
            }
            stage = "Model yükleniyor"
            try await p.loadModels()
            pipe = p
            state = .ready
            stage = "Hazır"
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 16 kHz mono ses → metin. `forced` verilirse dil zorlanır (tr / en).
    func transcribe(_ samples: [Float], forced: String? = nil) async -> HeardTurn? {
        guard let pipe else { return nil }
        guard samples.count > 16000 / 3 else { return nil }   // < 0.33 sn
        do {
            // Tek geçiş: dil tespiti yazıya dökmeyle birlikte yapılır (eskiden iki ayrı geçişti, iki kat yavaştı).
            var pass = try await run(pipe, samples, lang: forced)
            guard var text = pass.text, !text.isEmpty else { return nil }
            var lang = forced ?? Self.map(pass.lang)

            if forced == nil {
                // Metnin kendisine bak: Türkçe metin İngilizce sanıldıysa (ya da tersi) düzelt.
                let nl = NLLanguageRecognizer()
                nl.languageConstraints = [.turkish, .english]
                nl.processString(text)
                let h = nl.languageHypotheses(withMaximum: 2)
                let trP = h[.turkish] ?? 0, enP = h[.english] ?? 0
                let textLang: String? = trP > 0.8 ? "tr" : (enP > 0.8 ? "en" : nil)
                if lang == nil || (textLang != nil && textLang != lang) {
                    // Whisper başka bir dil seçti (ör. Azerice) ya da metin dile uymuyor: doğru dille bir kez daha
                    let target = textLang ?? (trP >= enP ? "tr" : "en")
                    if target != lang {
                        pass = try await run(pipe, samples, lang: target)
                        if let t = pass.text, !t.isEmpty { text = t }
                    }
                    lang = target
                }
            }
            guard !Self.isHallucination(text) else { return nil }
            return HeardTurn(text: text, language: lang == "tr" ? .tr : .en, confidence: pass.conf)
        } catch {
            return nil
        }
    }

    private func run(_ pipe: WhisperKit, _ samples: [Float], lang: String?) async throws -> (text: String?, lang: String, conf: Float) {
        let opts = DecodingOptions(task: .transcribe, language: lang, temperature: 0,
                                   usePrefillPrompt: lang != nil, detectLanguage: lang == nil,
                                   skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: opts)
        let segs = results.flatMap(\.segments).filter { $0.noSpeechProb < 0.6 }   // sessizlik/gürültü uydurmalarını at
        let text = segs.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let conf = segs.isEmpty ? 0.5 : Float(segs.map { exp($0.avgLogprob) }.reduce(0, +)) / Float(segs.count)
        return (text.isEmpty ? nil : text, results.first?.language ?? lang ?? "", conf)
    }

    /// Whisper dil kodu → tr / en (Türkçe bazen Azerice ya da Türkmence sanılır).
    static func map(_ code: String) -> String? {
        switch code {
        case "tr", "az", "tk", "ba", "tt", "uz", "kk": return "tr"
        case "en": return "en"
        default: return nil
        }
    }

    /// Dil tespiti için geçici 16 kHz WAV.
    static func writeTempWav(_ samples: [Float]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gnl-lang.wav")
        try? FileManager.default.removeItem(at: url)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        // dil tespiti için ilk 10 saniye yeterli
        let n = min(samples.count, 160_000)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return url.path }
        buf.frameLength = AVAudioFrameCount(n)
        samples.withUnsafeBufferPointer { p in buf.floatChannelData![0].update(from: p.baseAddress!, count: n) }
        try file.write(from: buf)
        return url.path
    }

    private static let junk = ["altyazı m.k", "altyazı", "izlediğiniz için teşekkürler", "abone ol", "thank you for watching",
                               "thanks for watching", "subtitles by", "♪", "[music]", "(music)", "[müzik]"]
    static func isHallucination(_ t: String) -> Bool {
        let l = t.lowercased()
        if junk.contains(where: { l.contains($0) }) { return true }
        let letters = l.filter(\.isLetter)
        return letters.count < 2
    }
}

/// Mikrofonu dinler, sesi 16 kHz'e çevirir ve enerji tabanlı VAD ile konuşma sırası bitince sesi verir.
final class UtteranceRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()

    private var current: [Float] = []
    private var preRoll: [Float] = []
    private var inSpeech = false
    private var speechFrames = 0
    private var silenceFrames = 0
    private var noiseFloor: Float = 0.006

    var isMuted: () -> Bool = { false }
    var onUtterance: (([Float]) -> Void)?
    var onLevel: ((Float, Bool) -> Void)?   // seviye, konuşma algılandı mı
    private(set) var running = false

    /// Sıra sonu için gereken sessizlik (sn) — doğal duraksamada erken bölmemek için.
    var endSilence: Double = 1.0
    var maxUtterance: Double = 28

    func start() throws {
        guard !running else { return }
        AudioRoute.shared.configure()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in self?.process(buf) }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        lock.lock(); current = []; inSpeech = false; lock.unlock()
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        handle(samples)
    }

    private func handle(_ s: [Float]) {
        let muted = isMuted()
        var sum: Float = 0
        for v in s { sum += v * v }
        let rms = sqrt(sum / Float(max(s.count, 1)))
        var utterance: [Float]?

        lock.lock()
        if muted {
            current = []; inSpeech = false; preRoll = []
        } else {
            // gürültü tabanını yavaşça izle
            if !inSpeech { noiseFloor = 0.95 * noiseFloor + 0.05 * min(rms, 0.05) }
            let threshold = max(0.02, noiseFloor * 4.0)   // ortam gürültüsü her seferinde konuşma sayılmasın
            let voiced = rms > threshold
            if inSpeech {
                current += s
                if voiced { speechFrames += s.count; silenceFrames = 0 } else { silenceFrames += s.count }
                let silence = Double(silenceFrames) / 16000
                let length = Double(current.count) / 16000
                if silence >= endSilence || length >= maxUtterance {
                    if Double(speechFrames) / 16000 >= 0.6 { utterance = current }   // çok kısa sesleri (öksürük, tık) işleme
                    current = []; inSpeech = false; speechFrames = 0; silenceFrames = 0
                }
            } else if voiced {
                inSpeech = true
                current = preRoll + s      // ilk heceyi kaçırmamak için ön-kayıt
                speechFrames = s.count; silenceFrames = 0
            }
            preRoll += s
            if preRoll.count > 8000 { preRoll.removeFirst(preRoll.count - 8000) }   // 0.5 sn
        }
        let speaking = inSpeech
        lock.unlock()

        DispatchQueue.main.async {
            self.onLevel?(rms, speaking)
            if let utterance { self.onUtterance?(utterance) }
        }
    }
}
