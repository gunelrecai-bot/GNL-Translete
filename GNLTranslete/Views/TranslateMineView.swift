import SwiftUI

struct TranslateMineView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var speakMode = true
    @State private var text = ""
    @State private var listening = false
    @State private var result: String?
    @State private var one = OneShotListener()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("", selection: $speakMode) {
                    Text("Konuş").tag(true)
                    Text("Yaz").tag(false)
                }
                .pickerStyle(.segmented)

                if speakMode {
                    Button { Task { await listen() } } label: {
                        VStack(spacing: 8) {
                            Image(systemName: listening ? "waveform" : "mic.fill").font(.system(size: 40))
                                .symbolEffect(.variableColor, isActive: listening)
                            Text(listening ? "Dinliyorum… Bitirince kendiliğinden çevrilir." : "Türkçe söylemek için dokun")
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 20))
                        .foregroundStyle(theme.onCard)
                    }
                    .disabled(listening)
                    if !text.isEmpty { Text(text).font(.title3).foregroundStyle(theme.onBg) }
                } else {
                    TextField("Türkçe cümleni yaz", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .padding().background(theme.card, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(theme.onCard)
                    Button("Çevir") { Task { await translate() } }
                        .buttonStyle(.borderedProminent).tint(theme.accent).foregroundStyle(theme.onAccent)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let result {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("İngilizcesi").font(.subheadline.bold())
                        Text(result).font(.title2)
                        Text("Kulaklıktan okunuyor. Karşıya Oku ile hoparlörden dinletebilirsin.").font(.footnote).opacity(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(theme.accent, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(theme.onAccent)
                }
                Spacer()
            }
            .padding()
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle("Cümlemi Çevir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } } }
        }
        .onDisappear { one.cancel() }
    }

    private func listen() async {
        let c = ConversationController.shared
        c.beginOverlay()
        listening = true
        let heard = await one.listenOnce(lang: "tr")
        listening = false
        c.endOverlay(applyResumeSetting: false)
        if let heard { text = heard.text; await translate() }
    }

    private func translate() async {
        let c = ConversationController.shared
        await c.translateOwn(text)
        result = c.lastOwnEnglish
    }
}
