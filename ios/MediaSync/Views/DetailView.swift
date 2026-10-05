import SwiftData
import SwiftUI

struct DetailView: View {
    @Bindable var item: MediaItem
    @Environment(AppState.self) private var state
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""
    @State private var downloading = false
    @State private var reanalyzing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
                metadata
                tagEditor
                if let text = item.extractedText, !text.isEmpty {
                    GroupBox("Extracted text (stays on this device)") {
                        Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(item.filename)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Re-run on-device analysis", systemImage: "sparkles") {
                        reanalyzing = true
                        Task {
                            await ImportService.reanalyze(item, in: context)
                            reanalyzing = false
                            Haptics.success()
                            await state.syncNow()
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Haptics.medium()
                        item.syncState = .pendingDelete
                        try? context.save()
                        dismiss()
                        Task { await state.syncNow() }
                    }
                } label: { Image(systemName: reanalyzing ? "hourglass" : "ellipsis.circle") }
            }
        }
        .task(id: item.id) {
            // Remote-only items are fetched + decrypted on first open, then cached for offline use.
            guard !item.isAvailableOffline, item.remoteUploaded, state.isOnline else { return }
            downloading = true
            await state.download(item)
            downloading = false
        }
    }

    @ViewBuilder private var content: some View {
        if let url = item.localURL, item.isAvailableOffline {
            switch item.kind {
            case .photo:
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                }
            case .video, .audio:
                MediaPlayerView(url: url, kind: item.kind)
            case .text:
                Text((try? String(contentsOf: url, encoding: .utf8)) ?? "").font(.body)
            }
        } else if downloading {
            HStack { ProgressView(); Text("Downloading & decrypting…") }.frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ContentUnavailableView("Not available offline", systemImage: "icloud.slash",
                                   description: Text("Connect to the internet to download this item."))
        }
    }

    private var metadata: some View {
        HStack(spacing: 16) {
            Label(item.kind.rawValue.capitalized, systemImage: item.kind.systemImage)
            if let s = item.sentimentRaw { Label(s.capitalized, systemImage: "face.smiling") }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
        }
        .font(.footnote).foregroundStyle(.secondary)
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(item.tags, id: \.self) { tag in
                    Button {
                        Haptics.tap()
                        item.tags.removeAll { $0 == tag }
                        item.syncState = .pending
                        try? context.save()
                    } label: {
                        Label(tag, systemImage: "xmark").labelStyle(.titleAndIcon)
                            .font(.footnote).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color(.secondarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Add tag", text: $newTag).textInputAutocapitalization(.never).onSubmit(addTag)
                Button("Add", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty, !item.tags.contains(tag) else { return }
        item.tags.append(tag)
        item.syncState = .pending
        try? context.save()
        newTag = ""
        Haptics.success()
        Task { await state.syncNow() }
    }
}

/// Minimal wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}
