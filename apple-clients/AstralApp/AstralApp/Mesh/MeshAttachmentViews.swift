// Shows pending and received mesh files without following a filename or resource handle as a URL.
// Saving fetches verified bytes through the kernel and presents the system export picker without a plaintext cache.

import SwiftUI
import UniformTypeIdentifiers

struct MeshAttachmentDrafts: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(mesh.draftAttachments) { attachment in
                        HStack(spacing: 8) {
                            Label(attachment.name, systemImage: "doc")
                                .font(ConsoleTypography.footnote).lineLimit(1)
                            Button {
                                mesh.removeDraftAttachment(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill").frame(minWidth: 32, minHeight: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove " + attachment.name)
                            .accessibilityIdentifier("mesh.attachment.remove." + attachment.id)
                        }
                        .padding(.leading, 10).padding(.trailing, 3)
                        .background(theme.palette.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.md))
                        .accessibilityIdentifier("mesh.attachment.draft." + attachment.id)
                    }
                }
            }
            Text(
                "The assistant can read UTF-8 text, Markdown, CSV and JSON files up to 64 KiB each (256 KiB total). Other files sync between your devices."
            )
            .font(ConsoleTypography.caption).foregroundStyle(theme.palette.muted)
            .accessibilityIdentifier("mesh.attachments.notice")
        }
    }
}

struct MeshAttachmentView: View {
    let attachment: MeshAttachment
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var fetching = false
    @State private var exporting = false
    @State private var document: MeshAttachmentDocument?
    @State private var problem: String?

    private var name: String { attachment.name.isEmpty ? "Attachment" : attachment.name }
    private var contentType: UTType { UTType(mimeType: attachment.mime) ?? .data }
    private var state: String {
        switch attachment.availability {
        case .withheldPhi: return "Held on approved devices"
        case .keyUnknown: return "Waiting for its key"
        case .corrupt: return "File integrity check failed"
        case .absent: return "Waiting for file details"
        case .present:
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: attachment.size), countStyle: .file)
            if attachment.complete { return size }
            return size + " · " + String(attachment.chunksHeld) + " of " + String(attachment.chunks)
                + " chunks on this device"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: attachment.mime.hasPrefix("image/") ? "photo" : "doc")
                    .foregroundStyle(theme.palette.muted).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(ConsoleTypography.subheadline).lineLimit(2)
                    Text(fetching ? "Getting file…" : state)
                        .font(ConsoleTypography.caption).foregroundStyle(theme.palette.muted)
                }
                Spacer(minLength: 6)
                if attachment.availability == .present {
                    if attachment.complete {
                        Button("Save…") {
                            Task { await save() }
                        }
                        .meshBordered()
                        .disabled(fetching)
                        .accessibilityLabel("Save " + name)
                        .accessibilityIdentifier("mesh.attachment.save." + attachment.id)
                    } else {
                        Button("Get file") {
                            Task { await retrieve() }
                        }
                        .meshBordered()
                        .disabled(fetching)
                        .accessibilityLabel("Get " + name)
                        .accessibilityIdentifier("mesh.attachment.fetch." + attachment.id)
                    }
                }
            }
            if let problem {
                Text(problem).font(ConsoleTypography.caption).foregroundStyle(theme.palette.warning)
                    .accessibilityIdentifier("mesh.attachment.error." + attachment.id)
            }
        }
        .padding(10)
        .frame(maxWidth: 480, alignment: .leading)
        .background(theme.palette.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.attachment." + attachment.id)
        .fileExporter(
            isPresented: $exporting, document: document, contentType: contentType, defaultFilename: name
        ) { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                problem = "The file could not be saved. Try again."
            }
            document = nil
        }
    }

    private func retrieve() async {
        guard !fetching else { return }
        fetching = true
        problem = nil
        defer { fetching = false }
        if await mesh.attachmentBytes(attachment) == nil {
            problem = mesh.notice ?? "The file could not be fetched. Try when its device reconnects."
        }
    }

    private func save() async {
        guard !fetching else { return }
        fetching = true
        problem = nil
        defer { fetching = false }
        guard let bytes = await mesh.attachmentBytes(attachment) else {
            problem = mesh.notice ?? "The file could not be fetched. Try when its device reconnects."
            return
        }
        document = MeshAttachmentDocument(bytes: bytes)
        exporting = true
    }
}

struct MeshAttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}
