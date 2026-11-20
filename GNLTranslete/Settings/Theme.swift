import SwiftUI

struct RGB: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init(color: Color) {
        let ui = UIColor(color)
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        ui.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        r = Double(rr); g = Double(gg); b = Double(bb)
    }
    var color: Color { Color(red: r, green: g, blue: b) }
    var luminance: Double {
        func c(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)
    }
    /// Okunaklı yazı rengi: arka plana göre koyu veya açık.
    var readableText: Color {
        let dark = RGB(0x231329), light = RGB(0xFFFFFF)
        return contrast(with: dark) >= contrast(with: light) ? dark.color : light.color
    }
    func contrast(with o: RGB) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

struct ThemePalette: Codable, Equatable, Hashable {
    var background: RGB
    var card: RGB
    var accent: RGB
}

struct ThemeDef: Identifiable, Hashable {
    let id: String
    let name: String
    let palette: ThemePalette
}

enum Themes {
    static let all: [ThemeDef] = [
        ThemeDef(id: "gnl", name: "GNL Moru", palette: .init(background: RGB(0x2A1233), card: RGB(0xD9C8F2), accent: RGB(0xF5B898))),
        ThemeDef(id: "lavender", name: "Açık Lavanta", palette: .init(background: RGB(0xF1EAFB), card: RGB(0xFFFFFF), accent: RGB(0xB892E8))),
        ThemeDef(id: "night", name: "Gece Mavisi", palette: .init(background: RGB(0x0F1B33), card: RGB(0xC9D6F0), accent: RGB(0x7FB2FF))),
        ThemeDef(id: "ocean", name: "Okyanus", palette: .init(background: RGB(0x083B4C), card: RGB(0xCFEFF3), accent: RGB(0x5FD3C4))),
        ThemeDef(id: "forest", name: "Orman", palette: .init(background: RGB(0x15301F), card: RGB(0xD5E8D4), accent: RGB(0xA9D18E))),
        ThemeDef(id: "sunset", name: "Gün Batımı", palette: .init(background: RGB(0x3B1626), card: RGB(0xFBD9C9), accent: RGB(0xFF9466))),
        ThemeDef(id: "sand", name: "Kum Beji", palette: .init(background: RGB(0xF3E9DA), card: RGB(0xFFFBF4), accent: RGB(0xD9A86C))),
        ThemeDef(id: "powder", name: "Pudra", palette: .init(background: RGB(0xF8E6EA), card: RGB(0xFFFFFF), accent: RGB(0xE7A3B3))),
        ThemeDef(id: "ice", name: "Buz Mavisi", palette: .init(background: RGB(0xE6F2FA), card: RGB(0xFFFFFF), accent: RGB(0x8CC4E8))),
        ThemeDef(id: "blackgold", name: "Siyah & Altın", palette: .init(background: RGB(0x0D0D0D), card: RGB(0x2A2620), accent: RGB(0xD4AF37)))
    ]
    static func palette(_ id: String) -> ThemePalette { (all.first { $0.id == id } ?? all[0]).palette }
}

/// Ekranda kullanılan çözümlenmiş renkler.
struct ResolvedTheme {
    let p: ThemePalette
    var bg: Color { p.background.color }
    var card: Color { p.card.color }
    var accent: Color { p.accent.color }
    var onBg: Color { p.background.readableText }
    var onCard: Color { p.card.readableText }
    var onAccent: Color { p.accent.readableText }
    var cardInner: Color { p.card.color.opacity(0.75) }
    var bgIsDark: Bool { p.background.luminance < 0.3 }
    var chrome: Color { bgIsDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06) }
}
