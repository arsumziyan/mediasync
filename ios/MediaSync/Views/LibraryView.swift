import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var context
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var items: [MediaItem]

    @State private var search = ""
    @State private var selectedTag: String?
    @State private var selectedKind: MediaKind?
    @State private var selectedSentiment: String?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var importing = 0

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    private var visibleItems: [MediaItem] {
        items.filter { $0.syncState != .pendingDelete }.filter { item in
            (selectedKind == nil || item.kind == selectedKind)
            && (selectedTag == nil || item.tags.contains(selectedTag!))
            && (selectedSentiment == nil || item.sentimentRaw == selectedSentiment)
            && (search.isEmpty
                || item.filename.localizedCaseInsensitiveContains(search)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(search) }
                || (item.extractedText?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    private var topTags: [String] {
        let counts = items.flatMap(\.tags).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.prefix(12).map(\.key)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                filterBar
                if visibleItems.isEmpty {
                    ContentUnavailableView(items.isEmpty ? "No media yet" : "No matches",
                                           systemImage: "photo.on.rectangle.angled",
                                           description: Text(items.isEmpty ? "Import photos, videos, audio or notes. They're tagged on-device and synced encrypted." : "Try a different filter."))
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(visibleItems) { item in
                            NavigationLink(value: item) { MediaCell(item: item) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { delete(item) }
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            .searchable(text: $search, prompt: "Search names, tags, text")
            .refreshable { await state.syncNow() }
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { statusBar }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio, .movie, .image, .plainText],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await importFiles(urls) }
            }
            .onChange(of: photoSelection) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task { await importPhotos(newValue); photoSelection = [] }
            }
            .sensoryFeedback(.success, trigger: importing) { old, new in new == 0 && old > 0 }
        }
    }

    // MARK: Pieces

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaKind.allCases, id: \.self) { kind in
                    chip(kind.rawValue.capitalized, systemImage: kind.systemImage, active: selectedKind == kind) {
                        selectedKind = selectedKind == kind ? nil : kind
                    }
                }
                Divider().frame(height: 18)
                ForEach(["positive", "neutral", "negative"], id: \.self) { s in
                    chip(s, active: selectedSentiment == s) { selectedSentiment = selectedSentiment == s ? nil : s }
                }
                Divider().frame(height: 18)
                ForEach(topTags, id: \.self) { tag in
                    chip("#\(tag)", active: selectedTag == tag) { selectedTag = selectedTag == tag ? nil : tag }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, systemImage: String? = nil, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(active ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
            .foregroundStyle(active ? .white : .primary)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { Task { await state.signOut() } }
            } label: { Image(systemName: "person.crop.circle") }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { Task { await state.syncNow() } } label: {
                if state.isSyncing { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
            }
            Menu {
                PhotosPicker(selection: $photoSelection, matching: .images, photoLibrary: .shared()) {
                    Label("Photos", systemImage: "photo")
                }
                Button("Files (audio, video, text)", systemImage: "folder") { showFileImporter = true }
            } label: { Image(systemName: "plus.circle.fill") }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if importing > 0 { ProgressView(); Text("Analyzing \(importing) on device…") }
            else if !state.isOnline { Image(systemName: "wifi.slash"); Text("Offline — changes will sync later") }
            else if let error = state.errorMessage { Image(systemName: "exclamationmark.triangle"); Text(error).lineLimit(1) }
            else if let last = state.lastSync { Text("Synced \(last.formatted(.relative(presentation: .named)))") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .opacity(importing > 0 || !state.isOnline || state.errorMessage != nil || state.lastSync != nil ? 1 : 0)
    }

    // MARK: Actions

    private func importPhotos(_ picks: [PhotosPickerItem]) async {
        importing += picks.count
        for pick in picks {
            if let data = try? await pick.loadTransferable(type: Data.self) {
                _ = try? await ImportService.importImageData(data, in: context)
            }
            importing -= 1
        }
        await state.syncNow()
    }

    private func importFiles(_ urls: [URL]) async {
        importing += urls.count
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            _ = try? await ImportService.importFile(at: url, contentType: nil, in: context)
            importing -= 1
        }
        await state.syncNow()
    }

    private func delete(_ item: MediaItem) {
        Haptics.medium()
        item.syncState = .pendingDelete        // tombstone locally; SyncEngine pushes it, then removes
        try? context.save()
        Task { await state.syncNow() }
    }
}

struct MediaCell: View {
    let item: MediaItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(.secondarySystemFill))
                .overlay { thumbnail }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 4) {
                Image(systemName: item.kind.systemImage)
                if let s = item.sentimentRaw { Text(emoji(s)) }
                Spacer()
                Image(systemName: icon).foregroundStyle(item.syncState == .synced ? .green : .orange)
            }
            .font(.caption2)
            .padding(6)
            .background(.ultraThinMaterial, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if item.kind == .photo, item.isAvailableOffline, let url = item.localURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            VStack(spacing: 6) {
                Image(systemName: item.kind.systemImage).font(.title)
                Text(item.filename).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary).padding(6)
        }
    }

    private var icon: String {
        if !item.isAvailableOffline { return "icloud.and.arrow.down" }
        return item.syncState == .synced ? "checkmark.icloud" : "icloud.and.arrow.up"
    }

    private func emoji(_ s: String) -> String { s == "positive" ? "🙂" : s == "negative" ? "🙁" : "😐" }
}
