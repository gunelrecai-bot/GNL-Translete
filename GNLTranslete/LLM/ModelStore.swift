import Foundation
import Observation

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
        name: "Qwen2.5-1.5B-Instruct",
        license: "Apache 2.0",
        fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        approxBytes: 1_120_000_000,
        note: "~1,1 GB · en hızlı cevap")

    static let quality = LLMModelInfo(
        tier: .quality,
        name: "Qwen2.5-3B-Instruct",
        license: "Qwen Research (kişisel/ticari olmayan kullanım)",
        fileName: "qwen2.5-3b-instruct-q4_k_m.gguf",
        url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
        approxBytes: 2_100_000_000,
        note: "~2,1 GB · daha isabetli cevap, 1–2 sn daha yavaş")

    static func of(_ t: ModelTier) -> LLMModelInfo { t == .fast ? fast : quality }
}

@Observable
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    enum State: Equatable { case missing, downloading(Double), ready, failed(String) }
    private(set) var states: [ModelTier: State] = [.fast: .missing, .quality: .missing]
    private var session: URLSession!
    private var taskTier: [Int: ModelTier] = [:]

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
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        refresh()
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
        let task = session.downloadTask(with: LLMModelInfo.of(tier).url)
        taskTier[task.taskIdentifier] = tier
        task.resume()
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
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let tier = taskTier[task.taskIdentifier] else { return }
        taskTier[task.taskIdentifier] = nil
        if let error { states[tier] = .failed(error.localizedDescription) }
    }
}
