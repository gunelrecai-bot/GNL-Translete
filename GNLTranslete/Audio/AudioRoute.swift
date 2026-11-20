import AVFoundation
import Observation

/// iPhone mikrofonu girişi + Bluetooth (A2DP) kulaklık çıkışı.
/// Uygulama içinde eşleştirme ekranı yok; iOS'un etkin çıkışını izler.
@Observable
final class AudioRoute {
    static let shared = AudioRoute()

    private(set) var headphonesActive = false
    private(set) var outputName = ""
    private(set) var speakerOverride = false
    var onHeadphonesChanged: ((Bool) -> Void)?

    private init() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.configure()
        }
    }

    func configure() {
        let s = AVAudioSession.sharedInstance()
        do {
            // .allowBluetooth (HFP) bilerek eklenmedi: giriş iPhone mikrofonunda kalır, çıkış A2DP ile kulaklığa gider.
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .mixWithOthers])
            try s.setActive(true)
            if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try s.setPreferredInput(mic)
            }
        } catch {
            print("AudioSession hata: \(error)")
        }
        refresh()
    }

    func refresh() {
        if speakerOverride { return }
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        let hp = outs.first { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones].contains($0.portType) }
        let active = hp != nil
        outputName = hp?.portName ?? ""
        if active != headphonesActive {
            headphonesActive = active
            onHeadphonesChanged?(active)
        }
    }

    var statusText: String {
        guard headphonesActive else { return "Kulaklık bekleniyor" }
        return outputName.localizedCaseInsensitiveContains("airpods") ? "AirPods bağlı" : "Kulaklık bağlı (\(outputName))"
    }

    /// Karşıya Oku: yalnızca tek seslendirme için hoparlöre geçer.
    func routeToSpeaker(_ on: Bool) {
        let s = AVAudioSession.sharedInstance()
        speakerOverride = on
        try? s.overrideOutputAudioPort(on ? .speaker : .none)
        if !on { refresh() }
    }
}
