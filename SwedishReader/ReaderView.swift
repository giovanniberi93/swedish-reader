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
        // Keep the screen on for as long as a story is open, playing or not, so it doesn't
        // dim and auto-lock while listening or between pages.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            speaker.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if showSwedish { swedishText(scrollingWith: proxy) }
                            if showEnglish { englishText }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
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

    @ViewBuilder private func swedishText(scrollingWith proxy: ScrollViewProxy) -> some View {
        if let text = page.text, !text.isEmpty {
            let paragraphs = SpeechText.paragraphs(from: text)
            // The current paragraph follows the playback position, which isn't observable.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                ParagraphList(
                    paragraphs: paragraphs,
                    current: speaker.currentParagraph,
                    proxy: proxy,
                    onTap: { index in
                        guard speaker.state != .preparing else { return }
                        speaker.read(page, fromParagraph: index)
                    }
                )
            }
        } else if page.text != nil {
            Text("No text found on this page.").foregroundStyle(.secondary)
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

/// The page's text by paragraph. The paragraph being read is highlighted and kept in view;
/// tapping a paragraph reads from there.
private struct ParagraphList: View {
    let paragraphs: [String]
    let current: Int?
    let proxy: ScrollViewProxy
    let onTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                Text(paragraph)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        index == current ? Color.accentColor.opacity(0.2) : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(index) }
                    .id(index)
            }
        }
        .onChange(of: current) { _, current in
            guard let current else { return }
            withAnimation { proxy.scrollTo(current, anchor: .center) }
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
                                page.paragraphStarts = nil
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
