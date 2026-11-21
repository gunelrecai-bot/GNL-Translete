import Foundation
import AVFoundation
import Observation
import WhisperKit

/// Whisper (large-v3 turbo, sıkıştırılmış ~630 MB, MIT) ile cihaz içi konuşma tanıma.
/// Türkçe/İngilizce dil ayrımı Whisper'ın kendi dil tespitiyle yapılır.
@Observable
final class WhisperEngine {
    static let shared = WhisperEngine()
    static let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let repo = "argmaxinc/whisperkit-coreml"
    let approxSize = "~630 MB"

    enum State: Equatable { case missing, downloading(Double), loading, ready, failed(String) }
    private(set) var state: State = .missing
    private var pipe: WhisperKit?
    private let d = UserDefaults.standard

    private var savedFolder: String? {
        get { d.string(forKey: "whisperFolder") }
        set { d.set(newValue, forKey: "whisperFolder") }
    }

    var isDownloaded: Bool {
        guard let f = savedFolder else { return false }
        return FileManager.default.fileExists(atPath: f)
    }

    private init() {
        state = isDownloaded ? .loading : .missing
    }

    /// İndir (gerekirse) ve belleğe yükle.
    @MainActor
    func prepare() async {
        if case .downloading = state { return }
        if state == .ready, pipe != nil { return }
        do {
            var folder = savedFolder
            if folder == nil || !isDownloaded {
                state = .downloading(0)
                let url = try await WhisperKit.download(variant: Self.modelName, from: Self.repo, progressCallback: { p in
                    Task { @MainActor in WhisperEngine.shared.state = .downloading(p.fractionCompleted) }
                })
                folder = url.path
                savedFolder = url.path
            }
            state = .loading
            let config = WhisperKitConfig(modelFolder: folder, verbose: false, prewarm: true, load: true, download: false)
            pipe = try await WhisperKit(config)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 16 kHz mono ses → metin. `forced` verilirse dil zorlanır (tr / en).
    func transcribe(_ samples: [Float], forced: String? = nil) async -> HeardTurn? {
        guard let pipe else { return nil }
        guard samples.count > 16000 / 3 else { return nil }   // < 0.33 sn
        do {
            var lang = forced
            if lang == nil {
                let det = try await pipe.detectLanguage(audioPath: try Self.writeTempWav(samples))
                let tr = det.langProbs["tr"] ?? 0, en = det.langProbs["en"] ?? 0
                lang = tr > en ? "tr" : "en"
            }
            let opts = DecodingOptions(task: .transcribe, language: lang, temperature: 0,
                                       usePrefillPrompt: true, skipSpecialTokens: true, withoutTimestamps: true)
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: opts)
            let segs = results.flatMap(\.segments)
            // sessizlik/gürültü kaynaklı uydurma metinleri at
            let speech = segs.filter { $0.noSpeechProb < 0.6 }
            let text = speech.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isHallucination(text) else { return nil }
            let conf = speech.isEmpty ? 0.5 : Float(speech.map { exp($0.avgLogprob) }.reduce(0, +)) / Float(speech.count)
            return HeardTurn(text: text, language: lang == "tr" ? .tr : .en, confidence: conf)
        } catch {
            return nil
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
            let threshold = max(0.012, noiseFloor * 3.0)
            let voiced = rms > threshold
            if inSpeech {
                current += s
                if voiced { speechFrames += s.count; silenceFrames = 0 } else { silenceFrames += s.count }
                let silence = Double(silenceFrames) / 16000
                let length = Double(current.count) / 16000
                if silence >= endSilence || length >= maxUtterance {
                    if Double(speechFrames) / 16000 >= 0.35 { utterance = current }
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
