import Foundation

/// Swedish → English with MyMemory's free API (no key or account; about 5,000 characters a day).
/// Apple's on-device Translation framework doesn't support Swedish.
enum MyMemoryTranslator {
    /// MyMemory rejects longer queries ("MAX ALLOWED QUERY : 500 CHARS").
    static let maxQueryLength = 500

    struct Chunk: Equatable {
        var text: String
        var endsParagraph: Bool
    }

    static func translate(_ text: String) async throws -> String {
        var result = ""
        for chunk in chunks(of: text) {
            result += try await translateChunk(chunk.text)
            result += chunk.endsParagraph ? "\n\n" : " "
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Packs whole sentences into chunks under the query limit, never across a paragraph break.
    static func chunks(of text: String, limit: Int = maxQueryLength) -> [Chunk] {
        var chunks: [Chunk] = []
        var current = ""
        func flush(endsParagraph: Bool) {
            if !current.isEmpty { chunks.append(Chunk(text: current, endsParagraph: endsParagraph)) }
            current = ""
        }
        for sentence in SpeechText.utterances(from: text) {
            // A single sentence over the limit (unlikely in a picture book) is split between words.
            for piece in pieces(of: sentence.text, limit: limit) {
                let joined = current.isEmpty ? piece : current + " " + piece
                if joined.count > limit { flush(endsParagraph: false) }
                current = current.isEmpty ? piece : current + " " + piece
            }
            if sentence.endsParagraph { flush(endsParagraph: true) }
        }
        flush(endsParagraph: true)
        return chunks
    }

    private static func pieces(of sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(separator: " ") {
            if !current.isEmpty, current.count + 1 + word.count > limit {
                pieces.append(current)
                current = ""
            }
            current = current.isEmpty ? String(word) : current + " " + word
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func translateChunk(_ text: String) async throws -> String {
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "sv|en"),
        ]
        let (body, _) = try await URLSession.shared.data(from: components.url!)
        return try translation(from: body)
    }

    static func translation(from body: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = (json["responseData"] as? [String: Any])?["translatedText"] as? String
        else { throw TranslationFailure(message: "unexpected response") }
        // `responseStatus` is a number on success, sometimes a string on errors.
        let status = (json["responseStatus"] as? Int) ?? Int(json["responseStatus"] as? String ?? "") ?? 0
        // On errors MyMemory puts the error message in `translatedText`.
        guard status == 200 else { throw TranslationFailure(message: text) }
        return text
    }
}

struct TranslationFailure: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}
