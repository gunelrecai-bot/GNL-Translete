import Foundation
import AVFoundation
import Speech
import AppKit

// MARK: - Ayarlar
setvbuf(stdout, nil, _IONBF, 0)
let work = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tts")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

// MARK: - Sözlük (NSSpellChecker)
let spellLangs = NSSpellChecker.shared.availableLanguages
print("Sözlük dilleri:", spellLangs.filter { $0.hasPrefix("tr") || $0.hasPrefix("en") })
let trCode = spellLangs.first { $0.hasPrefix("tr") }
let enCode = spellLangs.first { $0 == "en" || $0.hasPrefix("en_US") } ?? spellLangs.first { $0.hasPrefix("en") }
Spell.available = trCode != nil && enCode != nil
Spell.isWord = { w, l in
    guard let code = (l == .tr ? trCode : enCode) else { return true }
    let r = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: code, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
    return r.location == NSNotFound
}

// MARK: - Sesli okuma (say)
func run(_ cmd: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: cmd); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}
print("Başlıyor…")
let voices = run("/usr/bin/say", ["-v", "?"])
func voice(_ prefix: String, prefer: [String]) -> String? {
    let lines = voices.split(separator: "\n").map(String.init).filter { $0.contains(prefix) }
    for p in prefer { if let l = lines.first(where: { $0.hasPrefix(p) }) { return String(l.split(separator: " ").first!) } }
    return lines.first.map { String($0.split(separator: " ").first!) }
}
let trVoice = voice("tr_TR", prefer: ["Yelda"])
let enVoice = voice("en_US", prefer: ["Samantha", "Alex"])
print("Türkçe ses:", trVoice ?? "YOK", "· İngilizce ses:", enVoice ?? "YOK")

let fmt16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
var ttsCache: [String: [Float]] = [:]
func speak(_ text: String, _ lang: DetectedLanguage) -> [Float] {
    if let c = ttsCache[text] { return c }
    guard let v = (lang == .tr ? trVoice : enVoice) else { return [] }
    let url = work.appendingPathComponent("\(abs(text.hashValue)).aiff")
    _ = run("/usr/bin/say", ["-v", v, "-o", url.path, text])
    guard let f = try? AVAudioFile(forReading: url),
          let src = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return [] }
    try? f.read(into: src)
    guard let conv = AVAudioConverter(from: f.processingFormat, to: fmt16),
          let out = AVAudioPCMBuffer(pcmFormat: fmt16, frameCapacity: AVAudioFrameCount(Double(f.length) * 16000 / f.processingFormat.sampleRate + 1024)) else { return [] }
    var fed = false
    conv.convert(to: out, error: nil) { _, st in if fed { st.pointee = .endOfStream; return nil }; fed = true; st.pointee = .haveData; return src }
    let s = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    ttsCache[text] = s
    return s
}

// MARK: - Senaryolar
struct Seg { let text: String; let lang: DetectedLanguage; let gap: Double }
struct Expect { let lang: DetectedLanguage; let keywords: [String] }
struct Scenario { let name: String; let segs: [Seg]; let expect: [Expect]; var flexible = false }

let scenarios: [Scenario] = [
    .init(name: "1 Türkçe tanışma", segs: [.init(text: "Merhaba, benim adım Recai.", lang: .tr, gap: 1.6)],
          expect: [.init(lang: .tr, keywords: ["merhaba", "adım"])]),
    .init(name: "2 İngilizce tanışma", segs: [.init(text: "Hello, my name is Recai.", lang: .en, gap: 1.6)],
          expect: [.init(lang: .en, keywords: ["hello", "name"])]),
    .init(name: "3 Türkçe + İngilizce arka arkaya (kısa ara)",
          segs: [.init(text: "Merhaba, benim adım Recai.", lang: .tr, gap: 0.3), .init(text: "Hello, my name is Recai.", lang: .en, gap: 1.6)],
          expect: [.init(lang: .tr, keywords: ["merhaba"]), .init(lang: .en, keywords: ["hello"])]),
    .init(name: "4 İki Türkçe cümle (tekrar olmamalı)",
          segs: [.init(text: "Bugün hava çok güzel.", lang: .tr, gap: 1.6), .init(text: "Akşam yemeğe çıkalım mı?", lang: .tr, gap: 1.6)],
          expect: [.init(lang: .tr, keywords: ["hava"]), .init(lang: .tr, keywords: ["akşam"])]),
    .init(name: "5 İki İngilizce cümle (tekrar olmamalı)",
          segs: [.init(text: "The weather is very nice today.", lang: .en, gap: 1.6), .init(text: "Shall we go out for dinner?", lang: .en, gap: 1.6)],
          expect: [.init(lang: .en, keywords: ["weather"]), .init(lang: .en, keywords: ["dinner"])]),
    .init(name: "6 İngilizce soru", segs: [.init(text: "Would you like a window seat?", lang: .en, gap: 1.6)],
          expect: [.init(lang: .en, keywords: ["window", "seat"])]),
    .init(name: "7 Türkçe günlük cümle", segs: [.init(text: "Okula gidiyorum, akşam görüşürüz.", lang: .tr, gap: 1.6)],
          expect: [.init(lang: .tr, keywords: ["okula", "akşam"])]),
    .init(name: "8 Restoranda hesap", segs: [.init(text: "Can I have the bill, please?", lang: .en, gap: 1.6)],
          expect: [.init(lang: .en, keywords: ["bill"])]),
    .init(name: "9 Tek kelime: Okay", segs: [.init(text: "Okay.", lang: .en, gap: 1.6)],
          expect: [.init(lang: .en, keywords: ["ok|okay"])]),
    .init(name: "10 Türkçe, İngilizce, Türkçe sırayla",
          segs: [.init(text: "Taksi çağırabilir misiniz?", lang: .tr, gap: 1.6),
                 .init(text: "Where is the train station?", lang: .en, gap: 1.6),
                 .init(text: "Teşekkür ederim, iyi günler.", lang: .tr, gap: 1.6)],
          expect: [.init(lang: .tr, keywords: ["taksi"]), .init(lang: .en, keywords: ["station"]), .init(lang: .tr, keywords: ["teşekkür"])]),
    .init(name: "11 Susmadan uzun İngilizce konuşma (nefes aralarında bölünmeli)",
          segs: [.init(text: "I arrived at the airport very early this morning.", lang: .en, gap: 0.5),
                 .init(text: "Then I took a taxi to the hotel near the beach.", lang: .en, gap: 0.5),
                 .init(text: "After lunch we visited the old town.", lang: .en, gap: 1.6)],
          expect: [.init(lang: .en, keywords: ["airport"]), .init(lang: .en, keywords: ["taxi"]), .init(lang: .en, keywords: ["lunch"])]),
    .init(name: "12 Susmadan uzun Türkçe konuşma (nefes aralarında bölünmeli)",
          segs: [.init(text: "Bu sabah çok erken saatte havalimanına vardım.", lang: .tr, gap: 0.5),
                 .init(text: "Sonra taksiyle sahildeki otele doğru gittik.", lang: .tr, gap: 0.5),
                 .init(text: "Öğle yemeğinden sonra eski şehri gezdik.", lang: .tr, gap: 1.6)],
          expect: [.init(lang: .tr, keywords: ["havalimanı"]), .init(lang: .tr, keywords: ["taksi"]), .init(lang: .tr, keywords: ["öğle"])]),
    .init(name: "13 Hiç es vermeden 4 cümle (cümle sonlarında bölünmeli, kayıp/tekrar yok)",
          segs: [.init(text: "I arrived at the airport very early this morning. Then I took a taxi to the hotel near the beach. After lunch we visited the old town. In the evening we had dinner by the sea.", lang: .en, gap: 1.6)],
          expect: [.init(lang: .en, keywords: ["airport"]), .init(lang: .en, keywords: ["taxi"]), .init(lang: .en, keywords: ["lunch", "old town"]), .init(lang: .en, keywords: ["evening", "dinner"])],
          flexible: true),
    .init(name: "14 Cümle ortasında duraklama (bölünmemeli, tek kart)",
          segs: [.init(text: "Yesterday afternoon my wife and I went together to the", lang: .en, gap: 0.55),
                 .init(text: "big shopping mall with my family.", lang: .en, gap: 1.6)],
          expect: [.init(lang: .en, keywords: ["went", "mall"])]),
]

// MARK: - Motorlar
let trLoc = Locale(identifier: "tr-TR"), enLoc = Locale(identifier: "en-US")
let stSupported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
// Bu Mac sunucusunda Apple'ın yeni motoru yoksa (sanal makine) iki dil de Dikte motoruyla test edilir;
// test edilen asıl şey uygulamanın karar/ayıklama/bölme mantığıdır.
let newEngine = SpeechTranscriber.isAvailable
let trViaDictation = !newEngine || !stSupported.contains { $0.hasPrefix("tr") }
let enViaDictation = !newEngine
print("Türkçe motoru:", trViaDictation ? "Dikte" : "Yeni motor", "· İngilizce motoru:", enViaDictation ? "Dikte" : "Yeni motor")

func module(_ l: DetectedLanguage) -> any SpeechModule {
    if (l == .tr && trViaDictation) || (l == .en && enViaDictation) {
        return DictationTranscriber(locale: l == .tr ? trLoc : enLoc, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults], attributeOptions: [.transcriptionConfidence])
    }
    return SpeechTranscriber(locale: l == .tr ? trLoc : enLoc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.transcriptionConfidence])
}
for l in [DetectedLanguage.tr, .en] {
    do {
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module(l)]) {
            print("Dil dosyası indiriliyor:", l.rawValue); try await req.downloadAndInstall()
        }
    } catch { print("Dil dosyası hatası \(l.rawValue):", error) }
}

/// Takılmaya karşı: işlem süreyi aşarsa beklemeyi bırak
func withTimeout(_ seconds: Double, _ label: String, _ op: @escaping () async -> Void) async {
    // Takılan motor çağrısını beklemeden devam et (görev grubu takılanı da beklerdi)
    final class Once: @unchecked Sendable { var done = false; let l = NSLock()
        func fire() -> Bool { l.lock(); defer { l.unlock() }; if done { return false }; done = true; return true } }
    let once = Once()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        Task { await op(); if once.fire() { c.resume() } }
        Task { try? await Task.sleep(for: .seconds(seconds)); if once.fire() { print("⏱ zaman aşımı:", label); c.resume() } }
    }
}

func confidence(_ s: AttributedString) -> Double? {
    var sum = 0.0, n = 0
    for run in s.runs { if let c = run.transcriptionConfidence { sum += c; n += 1 } }
    return n > 0 ? sum / Double(n) : nil
}

// MARK: - Bir senaryoyu çalıştır (uygulamadaki akışın aynısı: VAD → finalize → TurnAssembler.finish)
func runScenario(_ sc: Scenario) async -> [HeardTurn] {
    print("▶︎", sc.name)
    var audio: [Float] = Array(repeating: 0, count: 8000)
    for s in sc.segs {
        let v = speak(s.text, s.lang)
        print("   ses:", s.text, "→", String(format: "%.1f sn", Double(v.count) / 16000))
        audio += v; audio += Array(repeating: 0, count: Int(s.gap * 16000))
    }

    let langs: [DetectedLanguage] = [.tr, .en]
    let asm = TurnAssembler(langs: langs)
    var analyzers: [SpeechAnalyzer] = []
    var conts: [AsyncStream<AnalyzerInput>.Continuation] = []
    var tasks: [Task<Void, Never>] = []
    var mods: [any SpeechModule] = []
    for (i, l) in langs.enumerated() {
        let m = module(l); mods.append(m)
        if let t = m as? SpeechTranscriber {
            tasks.append(Task { do { for try await r in t.results { asm.receive(lane: i, text: String(r.text.characters), isFinal: r.isFinal, conf: confidence(r.text)) } } catch {} })
        } else if let t = m as? DictationTranscriber {
            tasks.append(Task { do { for try await r in t.results { asm.receive(lane: i, text: String(r.text.characters), isFinal: r.isFinal, conf: confidence(r.text)) } } catch {} })
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let a = SpeechAnalyzer(modules: [m])
        await withTimeout(20, "analyzer start") { do { try await a.start(inputSequence: stream) } catch { print("Analyzer başlatılamadı:", error) } }
        analyzers.append(a); conts.append(cont)
    }
    let ctx = AnalysisContext(); ctx.contextualStrings[.general] = ["Recai"]
    await withTimeout(10, "setContext") { for a in analyzers { try? await a.setContext(ctx) } }
    var afmtOpt: AVAudioFormat?
    await withTimeout(10, "format") { afmtOpt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: mods) }
    let afmt = afmtOpt ?? fmt16
    print("   motor biçimi:", afmt.sampleRate, "Hz")
    guard let conv = AVAudioConverter(from: fmt16, to: afmt) else { print("Dönüştürücü yok"); return [] }

    var turns: [HeardTurn] = []
    let chunk = 1600
    var pos = 0
    while pos < audio.count {
        let n = min(chunk, audio.count - pos)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt16, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        audio.withUnsafeBufferPointer { p in buf.floatChannelData![0].update(from: p.baseAddress! + pos, count: n) }
        var sum: Float = 0
        for k in 0..<n { sum += audio[pos + k] * audio[pos + k] }
        let rms = sqrt(sum / Float(n))
        let dip = audio.withUnsafeBufferPointer { minWindowRms($0.baseAddress! + pos, n, 16000) }
        let v = asm.vad(rms: rms, duration: Double(n) / 16000, muted: false, dipRms: dip)

        guard let out = AVAudioPCMBuffer(pcmFormat: afmt, frameCapacity: AVAudioFrameCount(Double(n) * afmt.sampleRate / 16000 + 64)) else { pos += n; continue }
        var fed = false
        conv.convert(to: out, error: nil) { _, st in if fed { st.pointee = .noDataNow; return nil }; fed = true; st.pointee = .haveData; return buf }
        if out.frameLength > 0 { for c in conts { c.yield(AnalyzerInput(buffer: out)) } }

        try? await Task.sleep(for: .milliseconds(100))   // gerçek zamanlı besle (telefondaki gibi)
        if v.midSegment {
            await withTimeout(20, "finalize") { for a in analyzers { try? await a.finalize(through: nil) } }
            try? await Task.sleep(for: .milliseconds(300))
            if let t = asm.finish(spoken: 1.0, carryTail: v.carryTail, forceCut: v.forceCut) { turns += LanguageSplitter.split(t) }
        }
        if v.endTurn {
            await withTimeout(20, "finalize") { for a in analyzers { try? await a.finalize(through: nil) } }
            try? await Task.sleep(for: .milliseconds(400))
            if let t = asm.finish(spoken: v.spoken) { turns += LanguageSplitter.split(t) }
        }
        pos += n
    }
    for c in conts { c.finish() }
    await withTimeout(10, "kapat") { for a in analyzers { await a.cancelAndFinishNow() } }
    tasks.forEach { $0.cancel() }
    return turns
}

func normalize(_ s: String) -> String { s.lowercased(with: Locale(identifier: "tr")).filter { $0.isLetter || $0 == " " } }

// MARK: - Çalıştır ve raporla
var passed = 0
var report = "## Konuşma testleri\n\n| # | Senaryo | Sonuç | Kartlar |\n|---|---|---|---|\n"
for sc in scenarios {
    let turns = await runScenario(sc)
    var problems: [String] = []
    if sc.flexible {
        // kart sayısı serbest (en az 2); tüm anahtar kelimeler sırayla ve birer kez geçmeli, hepsi doğru dilde
        if turns.count < 2 { problems.append("hiç bölünmedi (\(turns.count) kart)") }
        if let bad = turns.first(where: { $0.language != sc.expect[0].lang }) { problems.append("yanlış dil: \(bad.text)") }
        let all = normalize(turns.map(\.text).joined(separator: " "))
        var from = all.startIndex
        for k in sc.expect.flatMap(\.keywords) {
            let nk = normalize(k)
            let count = all.components(separatedBy: nk).count - 1
            if count == 0 { problems.append("kayıp: \(k)") } else if count > 1 { problems.append("tekrar: \(k)") }
            if let r = all.range(of: nk, range: from..<all.endIndex) { from = r.upperBound } else if count > 0 { problems.append("sıra bozuk: \(k)") }
        }
    } else if turns.count != sc.expect.count { problems.append("beklenen \(sc.expect.count) kart, çıkan \(turns.count)") }
    for (i, e) in sc.expect.enumerated() where i < turns.count && !sc.flexible {
        let t = turns[i]
        if t.language != e.lang { problems.append("kart \(i + 1) dili \(t.language.rawValue), olması gereken \(e.lang.rawValue)") }
        let txt = normalize(t.text)
        // "a|b" → ikisinden biri yeterli (ör. "OK" ve "Okay" aynı şey)
        let missing = e.keywords.filter { k in !k.split(separator: "|").contains { txt.contains(normalize(String($0))) } }
        if !missing.isEmpty { problems.append("kart \(i + 1)'de eksik: \(missing.joined(separator: ","))") }
        if i > 0 {   // tekrar kontrolü: önceki cümlenin anahtar kelimesi sonraki kartta olmamalı
            for k in sc.expect[i - 1].keywords where txt.contains(normalize(k)) && !e.keywords.contains(k) {
                problems.append("kart \(i + 1)'de önceki cümle tekrarı (\(k))")
            }
        }
    }
    let ok = problems.isEmpty
    if ok { passed += 1 }
    let cards = turns.map { "[\($0.language.rawValue)] \($0.text)" }.joined(separator: " ‖ ")
    print("\(ok ? "✅" : "❌") \(sc.name) → \(cards)\(ok ? "" : "  ⚠️ " + problems.joined(separator: "; "))")
    report += "| \(sc.name.split(separator: " ").first!) | \(sc.name) | \(ok ? "✅" : "❌ " + problems.joined(separator: "; ")) | \(cards) |\n"
}
// Soru algılama denetimi
let qCases: [(String, DetectedLanguage, Bool)] = [
    ("Where are you from?", .en, true), ("where are you from", .en, true), ("How long are you staying", .en, true),
    ("Thanks for joining.", .en, false), ("I like this hotel", .en, false),
    ("Nereden geliyorsunuz", .tr, true), ("Çay ister misiniz", .tr, true), ("Bugün hava güzel.", .tr, false)]
let qBad = qCases.filter { QuestionDetector.isQuestion($0.0, $0.1) != $0.2 }
print(qBad.isEmpty ? "✅ Soru algılama 8/8" : "❌ Soru algılama hatalı: \(qBad.map(\.0))")
report += qBad.isEmpty ? "\n✅ Soru algılama 8/8\n" : "\n❌ Soru algılama: \(qBad.map(\.0))\n"
if !qBad.isEmpty { passed -= 1 }
print("SONUÇ: \(passed)/\(scenarios.count) geçti")
report += "\n**Sonuç: \(passed)/\(scenarios.count)**\n"
if let path = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"] {
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(report.data(using: .utf8)!); h.closeFile() }
}
try? report.write(toFile: "test-report.md", atomically: true, encoding: .utf8)
exit(passed == scenarios.count ? 0 : 1)
