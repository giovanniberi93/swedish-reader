import CoreGraphics
import Foundation
import NaturalLanguage

/// One line of recognized text, with the heights of its top-left and bottom-left corners
/// in Vision's normalized coordinates (origin bottom-left, so `top > bottom`).
///
/// Corners rather than a bounding box: in a tilted photo the upright box around a line is
/// much taller than the line, which hides the gaps between paragraphs.
struct RecognizedLine: Equatable {
    var text: String
    var top: CGFloat
    var bottom: CGFloat
}

/// Turns recognized lines into readable text, and readable text into chunks for the speech synthesizer.
enum SpeechText {
    /// Joins lines into paragraphs, undoing line-break hyphenation.
    static func assemble(_ lines: [RecognizedLine]) -> String {
        var paragraphs: [String] = []
        var current = ""
        var previous: RecognizedLine?
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let previous, startsNewParagraph(after: previous, next: line), !current.isEmpty {
                paragraphs.append(current)
                current = ""
            }
            current = join(current, text)
            previous = line
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    struct Utterance: Equatable {
        var text: String
        var endsParagraph: Bool
    }

    /// Splits text into sentences so the voice can pause between them, and pause longer between paragraphs.
    static func utterances(from text: String) -> [Utterance] {
        var result: [Utterance] = []
        for paragraph in text.split(separator: /\n\s*\n/) {
            let flat = paragraph.replacingOccurrences(of: "\n", with: " ")
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = flat
            tokenizer.setLanguage(.swedish)
            var sentences: [String] = []
            tokenizer.enumerateTokens(in: flat.startIndex..<flat.endIndex) { range, _ in
                let sentence = flat[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                return true
            }
            for (index, sentence) in sentences.enumerated() {
                result.append(Utterance(text: sentence, endsParagraph: index == sentences.count - 1))
            }
        }
        return result
    }

    /// A big vertical gap, or a jump back up the page (a new column or text block), starts a new paragraph.
    private static func startsNewParagraph(after previous: RecognizedLine, next: RecognizedLine) -> Bool {
        let gap = previous.bottom - next.top
        let lineHeight = max(previous.top - previous.bottom, next.top - next.bottom)
        return gap > lineHeight * 0.8 || next.bottom >= previous.top
    }

    private static func join(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return tail }
        guard head.hasSuffix("-") else { return head + " " + tail }
        // "sol-" + "skenet" → "solskenet", but "Anna-" + "Karin" → "Anna-Karin".
        if let first = tail.first, first.isLowercase {
            return String(head.dropLast()) + tail
        }
        return head + tail
    }
}
