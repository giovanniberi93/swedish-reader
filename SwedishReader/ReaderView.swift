import AVFoundation
import SwiftUI

struct ReaderView: View {
    let story: Story
    @State private var currentIndex: Int
    @Environment(Speaker.self) private var speaker
    @AppStorage("showSwedishText") private var showSwedish = true
    @AppStorage("showEnglishText") private var showEnglish = false

    init(story: Story, startIndex: Int) {
        self.story = story
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        let pages = story.orderedPages
        TabView(selection: $currentIndex) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                ReaderPageView(page: page, showSwedish: showSwedish, showEnglish: showEnglish)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .navigationTitle("\(currentIndex + 1) / \(pages.count)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Toggle("Show Swedish text", isOn: $showSwedish)
                Toggle("Show English translation", isOn: $showEnglish)
            } label: {
                Label("Text options", systemImage: "text.bubble")
            }
        }
        .onChange(of: currentIndex) { speaker.stop() }
        .onDisappear { speaker.stop() }
    }
}

private struct ReaderPageView: View {
    @Bindable var page: Page
    let showSwedish: Bool
    let showEnglish: Bool

    @Environment(Speaker.self) private var speaker
    @State private var image: UIImage?
    @State private var recognitionFailed = false
    @State private var translationError: String?
    /// Length of the page's saved Epidemic Sound audio, 0 if it has none yet.
    @State private var savedAudioDuration: TimeInterval = 0
    @State private var isEditing = false

    private var hasText: Bool { !(page.text ?? "").isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            pageImage
            if showSwedish || showEnglish {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if showSwedish { swedishText }
                        if showEnglish { englishText }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            if let reason = speaker.fallbackReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            // Hidden while the device voice reads: it can't seek.
            if savedAudioDuration > 0, speaker.state == .idle || speaker.hasAudioFile {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    SeekBar(
                        currentTime: speaker.hasAudioFile ? speaker.currentTime : 0,
                        duration: speaker.hasAudioFile ? speaker.duration : savedAudioDuration,
                        onSeek: seek
                    )
                }
            }
            HStack {
                Button(action: playOrPause) {
                    Group {
                        switch speaker.state {
                        case .preparing: HStack { ProgressView(); Text("Preparing…") }
                        case .playing: Label("Pause", systemImage: "pause.fill")
                        case .idle, .paused: Label("Play", systemImage: "play.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasText || speaker.state == .preparing)

                Button("Stop", systemImage: "stop.fill") { speaker.stop() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(speaker.state == .idle)

                Button("Rotate photo", systemImage: "rotate.right") {
                    page.quarterTurns = ((page.quarterTurns ?? 0) + 1) % 4
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Edit text", systemImage: "pencil") { isEditing = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(page.text == nil)
            }
        }
        .padding()
        .task {
            image = UIImage(data: page.imageData)
            await recognize()
        }
        .task(id: page.audioData?.count) {
            savedAudioDuration = page.audioData.flatMap { try? AVAudioPlayer(data: $0) }?.duration ?? 0
        }
        // Reruns when the toggle is switched on or the text is edited.
        .task(id: "\(showEnglish)|\(page.text ?? "")") { await translateIfNeeded() }
        .sheet(isPresented: $isEditing) { EditTextView(page: page) }
    }

    private var pageImage: some View {
        Group {
            if let image {
                Image(uiImage: image.rotated(quarterTurns: page.quarterTurns)).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: playOrPause)
        .overlay(alignment: .topTrailing) {
            if speaker.state == .playing {
                Image(systemName: "speaker.wave.2.fill")
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
                    .padding(8)
            }
        }
    }

    @ViewBuilder private var swedishText: some View {
        if let text = page.text {
            Text(text.isEmpty ? "No text found on this page." : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
        } else if recognitionFailed {
            HStack {
                Text("Couldn't read the text.").foregroundStyle(.secondary)
                Button("Try again") { Task { await recognize() } }
            }
        } else {
            Label("Reading text…", systemImage: "text.viewfinder").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var englishText: some View {
        if let translation = page.translation {
            Text(translation).italic().foregroundStyle(.secondary)
        } else if let translationError {
            Text("Translation failed: \(translationError)").font(.footnote).foregroundStyle(.secondary)
        } else if hasText {
            Label("Translating…", systemImage: "globe").foregroundStyle(.secondary)
        }
    }

    /// Seeking before playing starts the page's audio from that point.
    private func seek(to time: TimeInterval) {
        if !speaker.hasAudioFile { speaker.read(page) }
        speaker.seek(to: time)
    }

    private func playOrPause() {
        switch speaker.state {
        case .idle: speaker.read(page)
        case .playing: speaker.pause()
        case .paused: speaker.resume()
        case .preparing: break
        }
    }

    private func recognize() async {
        recognitionFailed = false
        do {
            try await page.recognizeTextIfNeeded()
        } catch {
            recognitionFailed = true
        }
    }

    private func translateIfNeeded() async {
        guard showEnglish, page.translation == nil, let text = page.text, !text.isEmpty else { return }
        translationError = nil
        do {
            let english = try await MyMemoryTranslator.translate(text)
            // Don't keep a translation of text that was edited in the meantime.
            if page.text == text { page.translation = english }
        } catch is CancellationError {
        } catch {
            translationError = error.localizedDescription
        }
    }
}

private struct EditTextView: View {
    @Bindable var page: Page
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var isScanning = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .padding()
                .disabled(isScanning)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 6) {
                        Button(action: { Task { await rescan() } }) {
                            if isScanning {
                                HStack { ProgressView(); Text("Scanning…") }
                            } else {
                                Label("Re-scan photo", systemImage: "text.viewfinder")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isScanning)
                        Text(scanError.map { "Scan failed: \($0)" }
                             ?? "Replaces the text above with a fresh reading of the photo. Tap Save to keep it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
                .navigationTitle("Edit text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if draft != page.text {
                                page.text = draft
                                page.translation = nil
                                page.audioData = nil
                            }
                            dismiss()
                        }
                    }
                }
        }
        .onAppear { draft = page.text ?? "" }
    }

    private func rescan() async {
        isScanning = true
        scanError = nil
        do {
            draft = try await TextRecognizer.recognize(
                page.imageData, orientation: CGImagePropertyOrientation(quarterTurns: page.quarterTurns)
            )
        } catch {
            scanError = error.localizedDescription
        }
        isScanning = false
    }
}
