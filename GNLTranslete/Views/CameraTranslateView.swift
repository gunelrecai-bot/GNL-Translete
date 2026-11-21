import SwiftUI
import VisionKit

/// Canlı kamera çevirisi: İngilizce yazıyı tanır, Türkçesini yazının üzerine yerleştirir.
/// Fotoğraf çekme ve sesli okuma yok.
struct CameraTranslateView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                LiveTextScanner().ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.badge.ellipsis").font(.largeTitle)
                    Text(DataScannerViewController.isSupported
                         ? "Kamera izni gerekli: Ayarlar → GNL-Canlı Çeviri → Kamera"
                         : "Bu cihazda canlı yazı tanıma desteklenmiyor.")
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title2.bold()).padding(14)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
    }
}

struct LiveTextScanner: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.text(languages: ["en-US"])],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: false)
        vc.delegate = context.coordinator
        context.coordinator.vc = vc
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        weak var vc: DataScannerViewController?
        private var labels: [RecognizedItem.ID: UILabel] = [:]
        private var cache: [String: String] = [:]
        private var pending: Set<String> = []

        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) { sync(allItems) }
        func dataScanner(_ s: DataScannerViewController, didUpdate items: [RecognizedItem], allItems: [RecognizedItem]) { sync(allItems) }
        func dataScanner(_ s: DataScannerViewController, didRemove items: [RecognizedItem], allItems: [RecognizedItem]) {
            for i in items { labels[i.id]?.removeFromSuperview(); labels[i.id] = nil }
        }

        private func sync(_ items: [RecognizedItem]) {
            guard let overlay = vc?.overlayContainerView else { return }
            for item in items {
                guard case .text(let t) = item else { continue }
                let source = t.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard source.count > 1 else { continue }
                let b = item.bounds
                let xs = [b.topLeft.x, b.topRight.x, b.bottomLeft.x, b.bottomRight.x]
                let ys = [b.topLeft.y, b.topRight.y, b.bottomLeft.y, b.bottomRight.y]
                let frame = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)

                let label = labels[item.id] ?? {
                    let l = UILabel()
                    l.numberOfLines = 0
                    l.adjustsFontSizeToFitWidth = true
                    l.minimumScaleFactor = 0.4
                    l.textAlignment = .center
                    l.textColor = UIColor(red: 0.16, green: 0.07, blue: 0.2, alpha: 1)
                    l.backgroundColor = UIColor(red: 0.96, green: 0.93, blue: 1.0, alpha: 0.93)
                    l.layer.cornerRadius = 6
                    l.clipsToBounds = true
                    l.font = .systemFont(ofSize: 22, weight: .semibold)
                    overlay.addSubview(l)
                    labels[item.id] = l
                    return l
                }()
                // titremeyi azaltmak için yumuşak konum güncellemesi
                let target = frame.insetBy(dx: -4, dy: -3)
                if label.frame == .zero { label.frame = target }
                else { UIView.animate(withDuration: 0.12) { label.frame = target } }

                if let tr = cache[source] {
                    if label.text != tr { label.text = tr }
                } else if !pending.contains(source) {
                    pending.insert(source)
                    if label.text == nil { label.text = "…" }
                    Task { @MainActor in
                        let tr = (try? await Translator.shared.translate(source, .enToTr)) ?? source
                        self.cache[source] = tr
                        self.pending.remove(source)
                        self.labels[item.id]?.text = tr
                    }
                }
            }
        }
    }
}
