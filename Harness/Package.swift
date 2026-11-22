// swift-tools-version:5.10
import PackageDescription

// Mac'te çalışan otomatik konuşma testi. Uygulamanın paylaşılan mantığı (GNLTranslete/Shared) CI'da buraya kopyalanır.
let package = Package(
    name: "Harness",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Harness", path: "Sources/Harness",
                          swiftSettings: [.unsafeFlags(["-swift-version", "5"])])
    ]
)
