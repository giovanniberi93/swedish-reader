import AVFoundation
import Observation

/// Reads a page aloud.
///
/// With an Epidemic Sound API key, the page's audio is generated once with the Helen voice,
/// one clip per paragraph joined into a single file, stored on the page, and played from there
/// afterwards. Reading can start at any paragraph. Without a key, or if generation
/// fails, it falls back to the best Swedish voice installed on the device.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    enum State {
        case idle
        /// The Epidemic Sound audio for the page is being generated.
        case preparing
        case playing
        case paused
    }

    private(set) var state: State = .idle
    /// Why the last reading fell back to the device voice, if it did.
    private(set) var fallbackReason: String?

    static let rates: [Float] = [1, 0.9, 0.8, 0.7]
    /// Playback speed of the Epidemic Sound audio, remembered across launches. Changes apply
    /// immediately and keep the voice's pitch. The device voice ignores it.
    var rate: Float = UserDefaults.standard.object(forKey: "playbackRate") as? Float ?? 1 {
        didSet {
            player?.rate = rate
            UserDefaults.standard.set(rate, forKey: "playbackRate")
        }
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// Looked up once here: creating voices from async code (the fallback after a failed
    /// generation) logs "unsafeForcedSync called from Swift Concurrent context".
    @ObservationIgnored private let deviceVoice = Speaker.bestSwedishVoice()
    /// Paragraph the device voice is speaking.
    private var spokenParagraph: Int?

    /// Device voice utterances (one per sentence) still to finish, and the paragraph each one is in.
    @ObservationIgnored private var queued: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var player: AVAudioPlayer?
    /// Where each paragraph starts in the loaded audio file.
    @ObservationIgnored private var paragraphStarts: [TimeInterval] = []
    @ObservationIgnored private var preparation: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        // Configured once, before any audio plays: `.playback` keeps speech audible when the
        // silent switch is on. The synthesizer and player activate the session themselves.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }

    /// Reads the page, starting at the given paragraph of `SpeechText.paragraphs(from:)`.
    func read(_ page: Page, fromParagraph first: Int = 0) {
        stop()
        fallbackReason = nil
        guard let text = page.text else { return }
        let paragraphs = SpeechText.paragraphs(from: text)
        guard !paragraphs.isEmpty else { return }
        let first = min(max(first, 0), paragraphs.count - 1)
        // Audio saved before paragraphs were tracked has no starts, so it's regenerated.
        if let audio = page.audioData, let starts = page.paragraphStarts, starts.count == paragraphs.count {
            play(audio, starts: starts, from: first, orSpeak: paragraphs)
            return
        }
        guard let apiKey = Secrets.epidemicApiKey else {
            fallbackReason = "No Epidemic Sound key in this build (Config/Secrets.xcconfig), using the phone's voice."
            speakWithDeviceVoice(paragraphs, from: first)
            return
        }
        state = .preparing
        preparation = Task {
            do {
                let clips = try await EpidemicVoiceClient(apiKey: apiKey).narrate(paragraphs)
                let pauses = Array(repeating: 0.6, count: paragraphs.count)
                let narration = try await Task.detached { try Narration.stitch(clips, pauses: pauses) }.value
                guard !Task.isCancelled else { return }
                // Don't keep audio for text that was edited while it was being generated.
                if page.text == text {
                    page.audioData = narration.audio
                    page.paragraphStarts = narration.starts
                }
                play(narration.audio, starts: narration.starts, from: first, orSpeak: paragraphs)
            } catch {
                guard !Task.isCancelled else { return }
                state = .idle
                fallbackReason = "Epidemic Sound voice unavailable (\(error.localizedDescription)), using the phone's voice."
                speakWithDeviceVoice(paragraphs, from: first)
            }
        }
    }

    /// The paragraph being read or paused on, `nil` when nothing is.
    ///
    /// Not observable while an audio file plays (it follows the playback position): views that
    /// show it refresh on a timer.
    var currentParagraph: Int? {
        guard state == .playing || state == .paused else { return nil }
        if let player {
            return paragraphStarts.lastIndex { $0 <= player.currentTime + 0.05 } ?? 0
        }
        return spokenParagraph
    }

    func pause() {
        guard state == .playing else { return }
        if let player {
            player.pause()
        } else {
            synthesizer.pauseSpeaking(at: .word)
        }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        if let player {
            player.play()
        } else {
            synthesizer.continueSpeaking()
        }
        state = .playing
    }

    /// True while an Epidemic Sound audio file is loaded (playing or paused). Only that can seek;
    /// the device voice can't.
    var hasAudioFile: Bool { player != nil }
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), player.duration)
    }

    func stop() {
        preparation?.cancel()
        preparation = nil
        player?.stop()
        player = nil
        paragraphStarts = []
        queued.removeAll()
        spokenParagraph = nil
        synthesizer.stopSpeaking(at: .immediate)
        state = .idle
    }

    /// True when an Enhanced or Premium Swedish voice is installed. The default one sounds flat.
    static var hasHighQualitySwedishVoice: Bool {
        (bestSwedishVoice()?.quality ?? .default) != .default
    }

    private func play(_ audio: Data, starts: [TimeInterval], from first: Int, orSpeak paragraphs: [String]) {
        do {
            let player = try AVAudioPlayer(data: audio)
            player.delegate = self
            player.currentTime = starts[first]
            player.enableRate = true
            player.rate = rate
            player.play()
            self.player = player
            paragraphStarts = starts
            state = .playing
        } catch {
            fallbackReason = "Couldn't play the saved audio, using the phone's voice."
            speakWithDeviceVoice(paragraphs, from: first)
        }
    }

    /// Speaks sentence by sentence, so the voice pauses between sentences and longer between paragraphs.
    private func speakWithDeviceVoice(_ paragraphs: [String], from first: Int) {
        for (index, paragraph) in paragraphs.enumerated().dropFirst(first) {
            for sentence in SpeechText.utterances(from: paragraph) {
                let utterance = AVSpeechUtterance(string: sentence.text)
                utterance.voice = deviceVoice
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
                utterance.postUtteranceDelay = sentence.endsParagraph ? 0.6 : 0.25
                queued[ObjectIdentifier(utterance)] = index
                synthesizer.speak(utterance)
            }
        }
        guard !queued.isEmpty else {
            state = .idle
            return
        }
        spokenParagraph = first
        state = .playing
    }

    private static func bestSwedishVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "sv-SE" }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "sv-SE")
    }

    private func utteranceStarted(_ id: ObjectIdentifier) {
        // Utterances cancelled by `stop()` were already removed, so they can't affect a newer reading.
        if let index = queued[id] { spokenParagraph = index }
    }

    private func utteranceFinished(_ id: ObjectIdentifier) {
        guard queued.removeValue(forKey: id) != nil, queued.isEmpty else { return }
        spokenParagraph = nil
        state = .idle
    }

    private func playerFinished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        paragraphStarts = []
        state = .idle
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceStarted(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceFinished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceFinished(id) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerFinished(id) }
    }
}
