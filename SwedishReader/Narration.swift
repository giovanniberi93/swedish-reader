import AVFoundation

/// Joins a page's per-paragraph voice clips into one audio file, so it plays and seeks like a
/// single recording while the app still knows where each paragraph starts.
enum Narration {
    enum StitchError: Error {
        case clipsDiffer
    }

    /// - Parameters:
    ///   - clips: One audio file per paragraph, in order.
    ///   - pauses: Silence to put after each clip (the last one is ignored).
    /// - Returns: The joined audio (AAC in an `.m4a` file) and the start time of each clip in it.
    static func stitch(_ clips: [Data], pauses: [TimeInterval]) throws -> (audio: Data, starts: [TimeInterval]) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let outputURL = folder.appending(path: "page.m4a")
        var output: AVAudioFile?
        var starts: [TimeInterval] = []
        var framesWritten: AVAudioFramePosition = 0
        for (index, clip) in clips.enumerated() {
            let clipURL = folder.appending(path: "\(index)")
            try clip.write(to: clipURL)
            let input = try AVAudioFile(forReading: clipURL)
            let format = input.processingFormat
            let writer = try output ?? AVAudioFile(
                forWriting: outputURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                ],
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            output = writer
            // Writing a buffer in another format raises an Objective-C exception rather than throwing.
            guard format == writer.processingFormat else { throw StitchError.clipsDiffer }

            starts.append(Double(framesWritten) / format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)) else {
                throw StitchError.clipsDiffer
            }
            try input.read(into: buffer)
            try writer.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)

            if index < clips.count - 1, index < pauses.count {
                let gap = try silence(pauses[index], format: format)
                try writer.write(from: gap)
                framesWritten += AVAudioFramePosition(gap.frameLength)
            }
        }
        // The file is finalized when the writer is released.
        output = nil
        return (try Data(contentsOf: outputURL), starts)
    }

    private static func silence(_ duration: TimeInterval, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(max(duration, 0) * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)) else {
            throw StitchError.clipsDiffer
        }
        buffer.frameLength = frames
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
        }
        return buffer
    }
}
