import Foundation
import llama

/// llama.cpp ile cihaz içi metin üretimi (GGUF model, Metal hızlandırma).
final class LlamaEngine {
    private var model: OpaquePointer?
    private var vocab: OpaquePointer?
    private let queue = DispatchQueue(label: "gnl.llama", qos: .userInitiated)

    struct Message { let role: String; let content: String }

    init(modelPath: String) throws {
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99
        guard let m = llama_model_load_from_file(modelPath, mp) else {
            throw NSError(domain: "LlamaEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model yüklenemedi"])
        }
        model = m
        vocab = llama_model_get_vocab(m)
    }

    deinit {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }

    func generate(_ messages: [Message], maxTokens: Int = 160, temperature: Float = 0.6) async -> String {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.run(messages, maxTokens: maxTokens, temperature: temperature)) }
        }
    }

    // Kalıcı bağlam + önek önbelleği: aynı talimatlar her seferinde yeniden işlenmez.
    private var ctx: OpaquePointer?
    private var cached: [llama_token] = []
    private let nCtx: Int32 = 2048
    private let nBatch: Int32 = 512

    private func context() -> OpaquePointer? {
        if let ctx { return ctx }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(nCtx)
        cp.n_batch = UInt32(nBatch)
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        ctx = llama_init_from_model(model, cp)
        cached = []
        return ctx
    }

    private func run(_ messages: [Message], maxTokens: Int, temperature: Float) -> String {
        guard model != nil, let vocab, let ctx = context() else { return "" }
        let mem = llama_get_memory(ctx)

        var prompt = applyTemplate(messages)
        // Qwen3: düşünme adımını atla (daha hızlı cevap)
        prompt += "<think>\n\n</think>\n\n"
        var tokens = tokenize(prompt)
        guard !tokens.isEmpty else { return "" }
        if tokens.count > Int(nCtx) - maxTokens - 8 { tokens = Array(tokens.suffix(Int(nCtx) - maxTokens - 8)); cached = [] }

        // Ortak öneki bul; yalnızca farklı kısmı işle
        var common = 0
        while common < min(cached.count, tokens.count) && cached[common] == tokens[common] { common += 1 }
        if common == tokens.count { common -= 1 }    // logit için en az bir belirteç işlenmeli
        if common <= 0 {
            llama_memory_clear(mem, true)
            common = 0
        } else {
            _ = llama_memory_seq_rm(mem, 0, Int32(common), -1)
        }
        cached = Array(tokens.prefix(common))

        var pos = common
        while pos < tokens.count {
            let n = min(Int(nBatch), tokens.count - pos)
            var chunk = Array(tokens[pos..<(pos + n)])
            let ok: Bool = chunk.withUnsafeMutableBufferPointer { p in
                llama_decode(ctx, llama_batch_get_one(p.baseAddress, Int32(n))) == 0
            }
            if !ok { llama_memory_clear(mem, true); cached = []; return "" }
            cached += chunk
            pos += n
        }

        let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        var bytes: [UInt8] = []
        for _ in 0..<maxTokens {
            var tok = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            bytes += piece(tok)
            let ok = withUnsafeMutablePointer(to: &tok) { llama_decode(ctx, llama_batch_get_one($0, 1)) == 0 }
            if !ok { break }
            cached.append(tok)
            // tek satırlık cevaplarda gereksiz devam etme
            if bytes.count > 8, let last = String(decoding: bytes.suffix(2), as: UTF8.self).last, last == "\n",
               String(decoding: bytes, as: UTF8.self).contains("REPLY:") { break }
        }
        var out = String(decoding: bytes, as: UTF8.self)
        if let r = out.range(of: "</think>") { out = String(out[r.upperBound...]) }
        out = out.replacingOccurrences(of: "<think>", with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyTemplate(_ messages: [Message]) -> String {
        let tmpl = llama_model_chat_template(model, nil)
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var chat = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }
        var buf = [CChar](repeating: 0, count: 32768)
        var n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
        }
        guard n > 0 else {
            // şablon yoksa düz metin
            return messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n") + "\nassistant:"
        }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let len = Int32(text.utf8.count)
        let cap = len + 16
        var toks = [llama_token](repeating: 0, count: Int(cap))
        let n = llama_tokenize(vocab, text, len, &toks, cap, false, true)
        return n > 0 ? Array(toks.prefix(Int(n))) : []
    }

    private func piece(_ tok: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, tok, &buf, Int32(buf.count), 0, false)
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }
}
