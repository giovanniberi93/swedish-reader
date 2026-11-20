import Foundation
import Vision

/// On-device Swedish text recognition with Apple's Vision framework.
enum TextRecognizer {
    /// `orientation` says how the photo is displayed, so text in a rotated photo is read upright.
    static func recognize(_ imageData: Data, orientation: CGImagePropertyOrientation = .up) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "sv-SE")]
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: imageData, orientation: orientation)
        let lines = observations.compactMap { observation -> RecognizedLine? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return RecognizedLine(text: text, top: CGFloat(observation.topLeft.y), bottom: CGFloat(observation.bottomLeft.y))
        }
        return SpeechText.assemble(lines)
    }
}
