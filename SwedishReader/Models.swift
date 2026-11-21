import Foundation
import SwiftData

@Model
final class Story {
    var title: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Page.story) var pages: [Page] = []

    init(title: String) {
        self.title = title
        self.createdAt = .now
    }

    var orderedPages: [Page] { pages.sorted { $0.order < $1.order } }
}

@Model
final class Page {
    var order: Int
    @Attribute(.externalStorage) var imageData: Data
    var thumbnailData: Data
    var takenAt: Date?
    /// Recognized Swedish text. `nil` means recognition hasn't run yet; empty means no text was found.
    var text: String?
    /// English translation of `text`. `nil` means not translated yet.
    var translation: String?
    /// Epidemic Sound narration of `text` (AAC, one clip per paragraph joined together). `nil` means not generated yet.
    @Attribute(.externalStorage) var audioData: Data?
    /// Where each paragraph of `text` starts in `audioData`, in seconds. `nil` for audio saved before
    /// paragraphs were tracked, which is regenerated.
    var paragraphStarts: [Double]?
    /// Clockwise quarter turns the user applied to the photo. Optional so existing pages migrate without a default.
    var quarterTurns: Int?
    var story: Story?

    init(order: Int, imageData: Data, thumbnailData: Data, takenAt: Date?) {
        self.order = order
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.takenAt = takenAt
    }

    /// Runs text recognition once and stores the result.
    @MainActor
    func recognizeTextIfNeeded() async throws {
        guard text == nil else { return }
        let result = try await TextRecognizer.recognize(imageData)
        if text == nil { text = result }
    }
}
