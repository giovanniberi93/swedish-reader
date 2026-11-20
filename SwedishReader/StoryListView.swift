import SwiftData
import SwiftUI

struct StoryListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Story.createdAt, order: .reverse) private var stories: [Story]
    @State private var path: [Story] = []
    @State private var isNaming = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if stories.isEmpty {
                    ContentUnavailableView("No stories yet", systemImage: "book", description: Text("Tap + to create one."))
                }
                ForEach(stories) { story in
                    NavigationLink(value: story) { StoryRow(story: story) }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(stories[index]) }
                }
                if !Speaker.hasHighQualitySwedishVoice {
                    Section {
                        Text("For a more natural voice, download an Enhanced or Premium Swedish voice in Settings → Accessibility → Spoken Content → Voices → Swedish.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Stories")
            .toolbar {
                Button {
                    newTitle = ""
                    isNaming = true
                } label: {
                    Label("New story", systemImage: "plus")
                }
            }
            .alert("New story", isPresented: $isNaming) {
                TextField("Title", text: $newTitle)
                Button("Create") {
                    let title = newTitle.trimmingCharacters(in: .whitespaces)
                    let story = Story(title: title.isEmpty ? "Untitled" : title)
                    context.insert(story)
                    path.append(story)
                }
                Button("Cancel", role: .cancel) {}
            }
            .navigationDestination(for: Story.self) { StoryDetailView(story: $0) }
        }
    }
}

private struct StoryRow: View {
    let story: Story

    var body: some View {
        HStack(spacing: 12) {
            let cover = story.orderedPages.first
            Thumbnail(data: cover?.thumbnailData, quarterTurns: cover?.quarterTurns)
            VStack(alignment: .leading) {
                Text(story.title).font(.headline)
                Text("^[\(story.pages.count) page](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Thumbnail: View {
    let data: Data?
    var quarterTurns: Int?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image.rotated(quarterTurns: quarterTurns)).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 60)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
