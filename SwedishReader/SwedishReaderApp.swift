import SwiftData
import SwiftUI

@main
struct SwedishReaderApp: App {
    @State private var speaker = Speaker()

    var body: some Scene {
        WindowGroup {
            StoryListView()
                .environment(speaker)
        }
        .modelContainer(for: [Story.self, Page.self])
    }
}
