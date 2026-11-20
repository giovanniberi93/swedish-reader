import PhotosUI
import SwiftData
import SwiftUI

struct StoryDetailView: View {
    @Bindable var story: Story
    @Environment(\.modelContext) private var context
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var failedImports = 0
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        let pages = story.orderedPages
        List {
            if !pages.isEmpty {
                Section {
                    NavigationLink {
                        ReaderView(story: story, startIndex: 0)
                    } label: {
                        Label("Read from the start", systemImage: "play.fill")
                    }
                }
            }
            Section(pages.isEmpty ? "" : "Pages") {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    NavigationLink {
                        ReaderView(story: story, startIndex: index)
                    } label: {
                        PageRow(page: page, number: index + 1)
                    }
                }
                .onMove(perform: movePages)
                .onDelete(perform: deletePages)
            }
        }
        .overlay {
            if isImporting {
                ProgressView("Adding pages…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if pages.isEmpty {
                ContentUnavailableView {
                    Label("No pages", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Add photos of the book's pages. They're sorted by when they were taken, and you can reorder them afterwards.")
                } actions: {
                    photoPicker.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(story.title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !pages.isEmpty { EditButton() }
                Menu {
                    photoPicker
                    Button("Rename", systemImage: "pencil") {
                        renameText = story.title
                        isRenaming = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .onChange(of: pickerItems) {
            guard !pickerItems.isEmpty else { return }
            Task { await importPhotos() }
        }
        .alert("Rename story", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
            Button("Save") {
                let title = renameText.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { story.title = title }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "^[\(failedImports) photo](inflect: true) couldn't be added",
            isPresented: Binding(get: { failedImports > 0 }, set: { if !$0 { failedImports = 0 } })
        ) {
            Button("OK") {}
        }
    }

    private var photoPicker: some View {
        PhotosPicker(
            selection: $pickerItems,
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .current
        ) {
            Label("Add pages", systemImage: "photo.badge.plus")
        }
    }

    private func importPhotos() async {
        let items = pickerItems
        pickerItems = []
        isImporting = true

        var photos: [ImportedPhoto] = []
        var failures = 0
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                failures += 1
                continue
            }
            let photo = await Task.detached { PhotoImport.process(data, pickIndex: index) }.value
            if let photo { photos.append(photo) } else { failures += 1 }
        }

        // New photos go after the existing pages, so a manual order isn't disturbed.
        var nextOrder = (story.pages.map(\.order).max() ?? -1) + 1
        var newPages: [Page] = []
        for photo in PhotoImport.ordered(photos) {
            let page = Page(order: nextOrder, imageData: photo.imageData, thumbnailData: photo.thumbnailData, takenAt: photo.takenAt)
            context.insert(page)
            story.pages.append(page)
            newPages.append(page)
            nextOrder += 1
        }
        isImporting = false
        failedImports = failures

        // Recognize text up front so pages are ready to read. The reader retries any that fail.
        for page in newPages {
            try? await page.recognizeTextIfNeeded()
        }
    }

    private func movePages(from source: IndexSet, to destination: Int) {
        var pages = story.orderedPages
        pages.move(fromOffsets: source, toOffset: destination)
        for (index, page) in pages.enumerated() { page.order = index }
    }

    private func deletePages(at offsets: IndexSet) {
        let pages = story.orderedPages
        for index in offsets { context.delete(pages[index]) }
    }
}

private struct PageRow: View {
    let page: Page
    let number: Int

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(data: page.thumbnailData, quarterTurns: page.quarterTurns)
            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(number)").font(.headline)
                Group {
                    switch page.text {
                    case nil: Text("Reading text…")
                    case let text? where text.isEmpty: Text("No text found")
                    case let text?: Text(text)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
    }
}
