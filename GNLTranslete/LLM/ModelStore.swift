import Foundation
import Observation
import UIKit

enum ModelTier: String, Codable, CaseIterable {
    case fast, quality
    var title: String { self == .fast ? "Hızlı" : "Kaliteli" }
}

/// Cevap üretim modelleri (GGUF Q4_K_M). İnternet yalnızca ilk indirme için kullanılır.
struct LLMModelInfo {
    let tier: ModelTier
    let name: String
    let license: String
    let fileName: String
    let url: URL
    let approxBytes: Int64
    let note: String

    static let fast = LLMModelInfo(
        tier: .fast,
        name: "Qwen3-1.7B",
        license: "Apache 2.0",
        fileName: "Qwen3-1.7B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!,
        approxBytes: 1_100_000_000,
        note: "~1,1 GB · hızlı cevap")

    static let quality = LLMModelInfo(
        tier: .quality,
        name: "Qwen3-4B",
        license: "Apache 2.0",
        fileName: "Qwen3-4B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!,
        approxBytes: 2_400_000_000,
        note: "~2,5 GB · en isabetli cevap, biraz daha yavaş")

    static func of(_ t: ModelTier) -> LLMModelInfo { t == .fast ? fast : quality }
}

@Observable
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    enum State: Equatable { case missing, downloading(Double), ready, failed(String) }
    private(set) var states: [ModelTier: State] = [.fast: .missing, .quality: .missing]
    private var session: URLSession!
    private var taskTier: [Int: ModelTier] = [:]
    private var retries: [ModelTier: Int] = [:]

    /// Seçili katman; seçili model yoksa indirilmiş olan kullanılır.
    var activeTier: ModelTier {
        let wanted = AppSettings.shared.modelTier
        if states[wanted] == .ready { return wanted }
        let other: ModelTier = wanted == .fast ? .quality : .fast
        return states[other] == .ready ? other : wanted
    }
    var info: LLMModelInfo { .of(activeTier) }
    var state: State { states[activeTier] ?? .missing }
    var fileURL: URL { fileURL(activeTier) }

    func fileURL(_ t: ModelTier) -> URL {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        return dir.appendingPathComponent(LLMModelInfo.of(t).fileName)
    }

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180          // yavaş bağlantıda kopmasın
        cfg.timeoutIntervalForResource = 6 * 3600
        cfg.waitsForConnectivity = true              // bağlantı gidip gelirse bekle
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        removeOldModels()
        refresh()
    }

    /// Eski sürümlerin (Qwen2.5) model dosyalarını sil: yer kaplamasın.
    private func removeOldModels() {
        let dir = fileURL(.fast).deletingLastPathComponent()
        let keep = Set(ModelTier.allCases.map { LLMModelInfo.of($0).fileName })
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".gguf") && !keep.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    func refresh() {
        for t in ModelTier.allCases {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(t).path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if size > LLMModelInfo.of(t).approxBytes / 2 { states[t] = .ready }
            else if case .downloading = states[t] {} else if case .failed = states[t] {} else { states[t] = .missing }
        }
    }

    func download(_ t: ModelTier? = nil) {
        let tier = t ?? AppSettings.shared.modelTier
        if case .downloading = states[tier] { return }
        states[tier] = .downloading(0)
        retries[tier] = 0
        start(tier, resumeData: nil)
    }

    private func start(_ tier: ModelTier, resumeData: Data?) {
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: LLMModelInfo.of(tier).url)
        taskTier[task.taskIdentifier] = tier
        UIApplication.shared.isIdleTimerDisabled = true   // indirme sürerken ekran kilitlenmesin
        task.resume()
    }

    private func downloadsFinished() {
        if !states.values.contains(where: { if case .downloading = $0 { return true }; return false }) {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func delete(_ t: ModelTier) {
        try? FileManager.default.removeItem(at: fileURL(t))
        states[t] = .missing
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        guard let tier = taskTier[downloadTask.taskIdentifier] else { return }
        let total = t > 0 ? t : LLMModelInfo.of(tier).approxBytes
        states[tier] = .downloading(Double(w) / Double(total))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tier = taskTier[downloadTask.taskIdentifier] else { return }
        let dest = fileURL(tier)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            states[tier] = .ready
        } catch {
            states[tier] = .failed(error.localizedDescription)
        }
        downloadsFinished()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let tier = taskTier[task.taskIdentifier] else { return }
        taskTier[task.taskIdentifier] = nil
        guard let error = error as NSError? else { return }
        // Kopan indirmeyi kaldığı yerden otomatik sürdür (en fazla 8 deneme)
        let n = (retries[tier] ?? 0) + 1
        retries[tier] = n
        if n <= 8 {
            let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(n * 3, 15))) { [weak self] in
                self?.start(tier, resumeData: resume)
            }
        } else {
            states[tier] = .failed("\(error.localizedDescription) (kod \(error.code)). Wi-Fi'yi kontrol edip tekrar İndir'e bas; kaldığı yerden devam eder.")
            downloadsFinished()
        }
    }
}
