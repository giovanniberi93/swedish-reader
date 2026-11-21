import AVFoundation
import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import SwedishReader

struct PhotoImportTests {
    @Test func datedPhotosSortOldestFirstAndUndatedOnesGoLastInPickOrder() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let photos = [
            photo(pick: 0, takenAt: nil),
            photo(pick: 1, takenAt: t.addingTimeInterval(60)),
            photo(pick: 2, takenAt: t),
            photo(pick: 3, takenAt: nil),
        ]
        #expect(PhotoImport.ordered(photos).map(\.pickIndex) == [2, 1, 0, 3])
    }

    @Test func photosTakenAtTheSameTimeKeepPickOrder() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let photos = [photo(pick: 1, takenAt: t), photo(pick: 0, takenAt: t)]
        #expect(PhotoImport.ordered(photos).map(\.pickIndex) == [0, 1])
    }

    @Test func readsCaptureDateFromExif() throws {
        let processed = try #require(PhotoImport.process(try jpeg(exifDate: "2025:03:14 08:30:00"), pickIndex: 0))
        let date = try #require(processed.takenAt)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts == DateComponents(year: 2025, month: 3, day: 14, hour: 8, minute: 30))
    }

    @Test func photoWithoutExifHasNoDate() throws {
        let processed = try #require(PhotoImport.process(try jpeg(exifDate: nil), pickIndex: 0))
        #expect(processed.takenAt == nil)
    }

    private func photo(pick: Int, takenAt: Date?) -> ImportedPhoto {
        ImportedPhoto(imageData: Data(), thumbnailData: Data(), takenAt: takenAt, pickIndex: pick)
    }

    private func jpeg(exifDate: String?) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let exifDate {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate]
        }
        CGImageDestinationAddImage(destination, try #require(image.cgImage), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

struct SpeechTextTests {
    @Test func linesOfOneParagraphAreJoinedWithSpaces() {
        let lines = [line("Det var en gång", top: 0.90), line("en liten katt.", top: 0.85)]
        #expect(SpeechText.assemble(lines) == "Det var en gång en liten katt.")
    }

    @Test func lineBreakHyphenationIsUndone() {
        let lines = [line("Hela dagen lyste sol-", top: 0.90), line("skenet.", top: 0.85)]
        #expect(SpeechText.assemble(lines) == "Hela dagen lyste solskenet.")
    }

    @Test func hyphenBeforeCapitalLetterIsKept() {
        let lines = [line("Hon hette Anna-", top: 0.90), line("Karin.", top: 0.85)]
        #expect(SpeechText.assemble(lines) == "Hon hette Anna-Karin.")
    }

    @Test func largeGapStartsNewParagraph() {
        let lines = [line("Första stycket.", top: 0.90), line("Andra stycket.", top: 0.70)]
        #expect(SpeechText.assemble(lines) == "Första stycket.\n\nAndra stycket.")
    }

    @Test func jumpingBackUpThePageStartsNewParagraph() {
        let lines = [line("Längst ner.", top: 0.30), line("Högst upp.", top: 0.90)]
        #expect(SpeechText.assemble(lines) == "Längst ner.\n\nHögst upp.")
    }

    @Test func utterancesAreSentencesAndMarkParagraphEnds() {
        let utterances = SpeechText.utterances(from: "Katten sov. Hunden skällde!\n\nSlut.")
        #expect(utterances == [
            .init(text: "Katten sov.", endsParagraph: false),
            .init(text: "Hunden skällde!", endsParagraph: true),
            .init(text: "Slut.", endsParagraph: true),
        ])
    }

    @Test func paragraphsAreSplitOnBlankLinesAndJoinLineBreaks() {
        #expect(SpeechText.paragraphs(from: "Katten sov.\nHunden skällde!\n\n  \n\nSlut.\n") == [
            "Katten sov. Hunden skällde!",
            "Slut.",
        ])
    }

    @Test func singleLineBreaksInEditedTextDoNotSplitSentences() {
        #expect(SpeechText.utterances(from: "Det var\nen gång.") == [.init(text: "Det var en gång.", endsParagraph: true)])
    }

    private func line(_ text: String, top: CGFloat, height: CGFloat = 0.04) -> RecognizedLine {
        RecognizedLine(text: text, top: top, bottom: top - height)
    }
}

struct TextRecognizerTests {
    @Test func recognizesSwedishTextAndJoinsLinesOfAParagraph() async throws {
        let size = CGSize(width: 1200, height: 500)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black]
            ("Det var en gång en liten" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: attributes)
            ("katt som hette Måns." as NSString).draw(at: CGPoint(x: 40, y: 100), withAttributes: attributes)
            ("Han älskade fisk." as NSString).draw(at: CGPoint(x: 40, y: 320), withAttributes: attributes)
        }
        let text = try await TextRecognizer.recognize(try #require(image.pngData()))
        #expect(text == "Det var en gång en liten katt som hette Måns.\n\nHan älskade fisk.")
    }

    @Test func readsSidewaysPhotoOnceRotatedUpright() async throws {
        // A page photographed sideways: text running bottom-to-top, as if the phone was turned left.
        let page = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 300)).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 1200, height: 300))
            ("Det var en gång en liten katt." as NSString).draw(
                at: CGPoint(x: 40, y: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 56), .foregroundColor: UIColor.black]
            )
        }
        let sideways = try #require(page.cgImage.map { UIImage(cgImage: $0, scale: 1, orientation: .left) })
        let flattened = UIGraphicsImageRenderer(size: sideways.size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { _ in sideways.draw(at: .zero) }
        // One clockwise quarter turn puts it upright again, which is what the rotate button stores.
        let text = try await TextRecognizer.recognize(
            try #require(flattened.pngData()), orientation: CGImagePropertyOrientation(quarterTurns: 1)
        )
        #expect(text == "Det var en gång en liten katt.")
    }
}

struct MCPResponseTests {
    private let generated = #"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"data\":{\"voiceoverGenerate\":{\"id\":\"abc\",\"status\":\"GENERATING\"}}}"}]}}"#

    @Test func readsToolResultFromEventStream() throws {
        let body = Data("event: message\ndata: \(generated)\n\n".utf8)
        let result = try MCPResponse.toolResult(from: body)
        #expect(try MCPResponse.string(at: ["data", "voiceoverGenerate", "id"], in: result) == "abc")
    }

    @Test func readsToolResultFromPlainJSON() throws {
        let result = try MCPResponse.toolResult(from: Data(generated.utf8))
        #expect(try MCPResponse.string(at: ["data", "voiceoverGenerate", "status"], in: result) == "GENERATING")
    }

    @Test func jsonRPCErrorIsThrown() {
        let body = Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Invalid params"}}"#.utf8)
        #expect(throws: VoiceError.server("Invalid params")) { try MCPResponse.toolResult(from: body) }
    }

    @Test func toolErrorIsThrown() {
        let body = Data(#"{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"Voice not found"}]}}"#.utf8)
        #expect(throws: VoiceError.server("Voice not found")) { try MCPResponse.toolResult(from: body) }
    }

    @Test func graphQLErrorInsideResultIsThrown() {
        let body = Data(#"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"errors\":[{\"message\":\"Quota exceeded\"}]}"}]}}"#.utf8)
        #expect(throws: VoiceError.server("Quota exceeded")) { try MCPResponse.toolResult(from: body) }
    }

    @Test func missingFieldIsUnexpectedResponse() throws {
        let result = try MCPResponse.toolResult(from: Data(generated.utf8))
        #expect(throws: VoiceError.unexpectedResponse) { try MCPResponse.string(at: ["data", "nope"], in: result) }
    }
}

struct MyMemoryTranslatorTests {
    @Test func readsTranslatedText() throws {
        let body = Data(#"{"responseData":{"translatedText":"Gittan is not at home.","match":0.99},"responseStatus":200}"#.utf8)
        #expect(try MyMemoryTranslator.translation(from: body) == "Gittan is not at home.")
    }

    @Test func errorStatusIsThrownWithMyMemorysMessage() {
        let body = Data(#"{"responseData":{"translatedText":"QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED QUERY : 500 CHARS"},"responseStatus":"403"}"#.utf8)
        #expect(throws: TranslationFailure(message: "QUERY LENGTH LIMIT EXCEEDED. MAX ALLOWED QUERY : 500 CHARS")) {
            try MyMemoryTranslator.translation(from: body)
        }
    }

    @Test func shortPageIsOneChunkPerParagraph() {
        #expect(MyMemoryTranslator.chunks(of: "Katten sov. Hunden skällde!\n\nSlut.") == [
            .init(text: "Katten sov. Hunden skällde!", endsParagraph: true),
            .init(text: "Slut.", endsParagraph: true),
        ])
    }

    @Test func longParagraphIsSplitBetweenSentencesUnderTheLimit() {
        let chunks = MyMemoryTranslator.chunks(of: "Ett två tre. Fyra fem sex. Sju åtta nio.", limit: 26)
        #expect(chunks == [
            .init(text: "Ett två tre. Fyra fem sex.", endsParagraph: false),
            .init(text: "Sju åtta nio.", endsParagraph: true),
        ])
    }

    @Test func overlongSentenceIsSplitBetweenWords() {
        let chunks = MyMemoryTranslator.chunks(of: "ett två tre fyra fem", limit: 8)
        #expect(chunks.map(\.text) == ["ett två", "tre fyra", "fem"])
        #expect(chunks.allSatisfy { $0.text.count <= 8 })
    }
}

struct ImageRotationTests {
    private let landscape = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { _ in }

    @Test func quarterTurnSwapsWidthAndHeight() {
        #expect(landscape.rotated(quarterTurns: 1).size == CGSize(width: 20, height: 40))
        #expect(landscape.rotated(quarterTurns: 1).imageOrientation == .right)
    }

    @Test func fullTurnAndNoTurnLeaveImageUpright() {
        #expect(landscape.rotated(quarterTurns: 4).imageOrientation == .up)
        #expect(landscape.rotated(quarterTurns: nil).size == CGSize(width: 40, height: 20))
    }
}

@MainActor
struct StoryPersistenceTests {
    @Test func storyAndPageOrderSurviveSaving() throws {
        let container = try inMemoryContainer()
        let story = Story(title: "Pelle Svanslös")
        container.mainContext.insert(story)
        for order in [2, 0, 1] {
            story.pages.append(Page(order: order, imageData: Data([UInt8(order)]), thumbnailData: Data(), takenAt: nil))
        }
        try container.mainContext.save()

        let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<Story>()).first)
        #expect(fetched.title == "Pelle Svanslös")
        #expect(fetched.orderedPages.map(\.imageData) == [Data([0]), Data([1]), Data([2])])
    }

    @Test func deletingAStoryDeletesItsPages() throws {
        let container = try inMemoryContainer()
        let story = Story(title: "Test")
        container.mainContext.insert(story)
        story.pages.append(Page(order: 0, imageData: Data(), thumbnailData: Data(), takenAt: nil))
        try container.mainContext.save()

        container.mainContext.delete(story)
        try container.mainContext.save()

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Page>()) == 0)
    }

    private func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: Story.self, Page.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}

struct NarrationTests {
    @Test func clipsAreJoinedWithPausesAndSentenceStartsAreKept() throws {
        let clips = [try tone(seconds: 1.0), try tone(seconds: 0.5), try tone(seconds: 0.5)]
        let narration = try Narration.stitch(clips, pauses: [0.25, 0.6, 0.6])

        #expect(narration.starts.count == 3)
        #expect(abs(narration.starts[0]) < 0.05)
        #expect(abs(narration.starts[1] - 1.25) < 0.05)
        #expect(abs(narration.starts[2] - 2.35) < 0.05)
        // No pause after the last clip.
        #expect(abs(try AVAudioPlayer(data: narration.audio).duration - 2.85) < 0.1)
    }

    @Test func clipsInDifferentFormatsAreRejected() throws {
        let clips = [try tone(seconds: 0.2, sampleRate: 44_100), try tone(seconds: 0.2, sampleRate: 22_050)]
        #expect(throws: Narration.StitchError.self) { try Narration.stitch(clips, pauses: [0.25]) }
    }

    /// An AAC file of a sine tone. The real clips are MP3, which iOS can read but not write.
    private func tone(seconds: Double, sampleRate: Double = 44_100) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) { samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / sampleRate)) * 0.5 }
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
            )
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}
