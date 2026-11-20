import Foundation
import Observation

/// Cevap üretim modeli: Qwen2.5-1.5B-Instruct (Apache 2.0), GGUF Q4_K_M, ~1.1 GB.
/// İnternet yalnızca bu ilk indirme için kullanılır.
struct LLMModelInfo {
    let name = "Qwen2.5-1.5B-Instruct (Q4_K_M)"
    let license = "Apache 2.0"
    let fileName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
    let url = URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!
    let approxBytes: Int64 = 1_120_000_000
}

@Observable
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()
    let info = LLMModelInfo()

    enum State: Equatable { case missing, downloading(Double), ready, failed(String) }
    private(set) var state: State = .missing
    private var session: URLSession!

    var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var u = dir.appendingPathComponent(info.fileName)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        return u
    }

    private override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        refresh()
    }

    func refresh() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size > info.approxBytes / 2 { state = .ready }
        else if case .downloading = state {} else { state = .missing }
    }

    func download() {
        if case .downloading = state { return }
        state = .downloading(0)
        session.downloadTask(with: info.url).resume()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        let total = t > 0 ? t : info.approxBytes
        state = .downloading(Double(w) / Double(total))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            try FileManager.default.moveItem(at: location, to: fileURL)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { state = .failed(error.localizedDescription) }
    }
}
