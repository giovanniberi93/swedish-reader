import AVFoundation
import Observation

/// Reads a page aloud.
///
/// With an Epidemic Sound API key, the page's audio is generated once with the Helen voice,
/// stored on the page, and played from there afterwards. Without a key, or if generation
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

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var queued: Set<ObjectIdentifier> = []
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var preparation: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        // Configured once, before any audio plays: `.playback` keeps speech audible when the
        // silent switch is on. The synthesizer and player activate the session themselves.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }

    func read(_ page: Page) {
        stop()
        fallbackReason = nil
        guard let text = page.text, !text.isEmpty else { return }
        if let audio = page.audioData {
            play(audio, orSpeak: text)
            return
        }
        guard let apiKey = Secrets.epidemicApiKey else {
            fallbackReason = "No Epidemic Sound key in this build (Config/Secrets.xcconfig), using the phone's voice."
            speakWithDeviceVoice(text)
            return
        }
        state = .preparing
        preparation = Task {
            do {
                let audio = try await EpidemicVoiceClient(apiKey: apiKey).narrate(text)
                guard !Task.isCancelled else { return }
                // Don't keep audio for text that was edited while it was being generated.
                if page.text == text { page.audioData = audio }
                play(audio, orSpeak: text)
            } catch {
                guard !Task.isCancelled else { return }
                state = .idle
                fallbackReason = "Epidemic Sound voice unavailable (\(error.localizedDescription)), using the phone's voice."
                speakWithDeviceVoice(text)
            }
        }
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
        queued.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        state = .idle
    }

    /// True when an Enhanced or Premium Swedish voice is installed. The default one sounds flat.
    static var hasHighQualitySwedishVoice: Bool {
        (bestSwedishVoice()?.quality ?? .default) != .default
    }

    private func play(_ audio: Data, orSpeak text: String) {
        do {
            let player = try AVAudioPlayer(data: audio)
            player.delegate = self
            player.play()
            self.player = player
            state = .playing
        } catch {
            fallbackReason = "Couldn't play the saved audio, using the phone's voice."
            speakWithDeviceVoice(text)
        }
    }

    private func speakWithDeviceVoice(_ text: String) {
        let chunks = SpeechText.utterances(from: text)
        guard !chunks.isEmpty else {
            state = .idle
            return
        }
        let voice = Self.bestSwedishVoice()
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk.text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
            utterance.postUtteranceDelay = chunk.endsParagraph ? 0.6 : 0.25
            queued.insert(ObjectIdentifier(utterance))
            synthesizer.speak(utterance)
        }
        state = .playing
    }

    private static func bestSwedishVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "sv-SE" }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "sv-SE")
    }

    private func utteranceFinished(_ id: ObjectIdentifier) {
        // Utterances cancelled by `stop()` were already removed, so they can't end a newer reading.
        guard queued.remove(id) != nil, queued.isEmpty else { return }
        state = .idle
    }

    private func playerFinished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        state = .idle
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
