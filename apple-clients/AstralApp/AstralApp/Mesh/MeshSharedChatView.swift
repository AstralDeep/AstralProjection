// A shared chat on the reader's side: the transcript with a From badge, no compose box, no action from any control and attachments fetched on demand.
// Opening it refreshes the share first, an unverified contact shows the verify prompt and fetches nothing, and a stopped share shows no content.

import SwiftUI

struct MeshSharedChatView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var model: MeshSharedChatModel
    @State private var verifying: MeshContactExchange?
    @State private var problem: String?
    private var p: AstralPalette { theme.palette }
    private let item: MeshSharedItem

    private var latest: MeshSharedItem { mesh.sharedItems.first { $0.grant == item.grant } ?? item }

    init(item: MeshSharedItem) {
        self.item = item
        _model = State(initialValue: MeshSharedChatModel(item: item, service: PlaceholderShared()))
    }

    var body: some View {
        VStack(spacing: 0) {
            MeshSharedBadge(facts: model.badge)
            Divider().overlay(p.border)
            content
        }
        .background(p.bg)
        .navigationTitle(item.title.isEmpty ? "Shared chat" : item.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier(MeshSharedID.chat)
        .task(id: latest.state) {
            let made = MeshSharedChatModel(item: latest, service: mesh)
            model = made
            await made.open()
        }
        .sheet(item: $verifying) { exchange in MeshContactCompareSheet(exchange: exchange) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading: ProgressView("Opening").frame(maxHeight: .infinity)
        case .needsVerification: needsVerification
        case .stopped: stopped
        case .failed(let message): Text(message).foregroundStyle(p.error).padding(24).frame(maxHeight: .infinity)
        case .ready(let view): transcript(view)
        }
    }

    private func transcript(_ view: MeshChatView) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let notice = model.withheldNotice {
                    Label(notice, systemImage: "eye.slash").font(ConsoleTypography.footnote)
                        .foregroundStyle(p.warning)
                        .accessibilityIdentifier(MeshSharedID.withheld)
                }
                if let problem = model.refreshProblem {
                    Text(problem).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                }
                ForEach(MeshChatMapper.rows(for: view, head: nil)) { row in
                    MeshSharedMessageRow(row: row, model: model)
                }
                Text(MeshSharedCopy.readOnly).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    .accessibilityIdentifier(MeshSharedID.readOnly)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("mesh.shared.transcript")
    }

    private var needsVerification: some View {
        VStack(spacing: 14) {
            Image(systemName: "questionmark.shield").font(.system(size: 44)).foregroundStyle(p.warning)
                .accessibilityHidden(true)
            Text(verbatim: "Verify " + model.badge.name + " to read this chat.")
                .font(ConsoleTypography.title3).multilineTextAlignment(.center)
            Text("Nothing is fetched until you do.").font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            if let problem { Text(problem).foregroundStyle(p.error) }
            Button("Verify Contact") { verify() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(MeshSharedID.verify)
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }

    private var stopped: some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle").font(.system(size: 44)).foregroundStyle(p.muted)
                .accessibilityHidden(true)
            Text(MeshSharedCopy.stopped).font(ConsoleTypography.title3)
            Text(MeshSharedCopy.stoppedDetail).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(MeshSharedID.stopped)
    }

    private func verify() {
        Task {
            do { verifying = try await mesh.startContactVerification(mesh: item.contact) } catch {
                problem = MeshRuntime.describe(error)
            }
        }
    }
}

struct MeshSharedBadge: View {
    let facts: MeshSharedBadgeFacts
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle").accessibilityHidden(true)
            Text(verbatim: facts.text).font(ConsoleTypography.subheadline)
            Spacer()
            Label(facts.stateLine, systemImage: facts.isVerified ? "checkmark.seal.fill" : "questionmark.circle")
                .font(ConsoleTypography.caption)
                .foregroundStyle(facts.isVerified ? p.success : p.warning)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(facts.text + ", " + facts.stateLine)
        .accessibilityIdentifier(MeshSharedID.badge)
    }
}

struct MeshSharedMessageRow: View {
    let row: MeshChatMapper.Row
    let model: MeshSharedChatModel
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(alignment: row.turn.role == "user" ? .trailing : .leading, spacing: 4) {
            if row.message?.text.isEmpty != true || row.message?.surfaceIds.isEmpty != true {
                ChatBubble(turn: row.turn)
                    .environment(\.astralMeshAction, { _, _, _ in })
                    .disabled(true)
            }
            if let message = row.message {
                ForEach(message.attachments) { attachment in
                    MeshSharedAttachmentView(attachment: attachment, model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: row.turn.role == "user" ? .trailing : .leading)
    }
}

struct MeshSharedAttachmentView: View {
    let attachment: MeshAttachment
    let model: MeshSharedChatModel
    @Environment(ThemeStore.self) private var theme
    @State private var fetching = false
    @State private var exporting = false
    @State private var document: MeshAttachmentDocument?
    @State private var problem: String?

    private var name: String { attachment.name.isEmpty ? "Attachment" : attachment.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "doc").foregroundStyle(theme.palette.muted).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(ConsoleTypography.subheadline).lineLimit(2)
                    Text(fetching ? "Getting file…" : size).font(ConsoleTypography.caption)
                        .foregroundStyle(theme.palette.muted)
                }
                Spacer(minLength: 6)
                Button("Get file") { Task { await save() } }
                    .meshBordered()
                    .disabled(fetching)
                    .accessibilityLabel("Get " + name)
                    .accessibilityIdentifier("mesh.shared.attachment.get." + attachment.id)
            }
            if let problem { Text(problem).font(ConsoleTypography.caption).foregroundStyle(theme.palette.warning) }
        }
        .padding(10)
        .frame(maxWidth: 480, alignment: .leading)
        .background(theme.palette.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.shared.attachment." + attachment.id)
        .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: name) {
            result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                problem = "The file couldn't be saved. Try again."
            }
            document = nil
        }
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: attachment.size), countStyle: .file)
    }

    private func save() async {
        guard !fetching else { return }
        fetching = true
        problem = nil
        defer { fetching = false }
        guard let bytes = await model.attachment(attachment) else {
            problem = model.refreshProblem ?? "The file couldn't be fetched. Try again."
            return
        }
        document = MeshAttachmentDocument(bytes: bytes)
        exporting = true
    }
}

@MainActor
private final class PlaceholderShared: MeshSharedService {
    let sharedItems: [MeshSharedItem] = []
    func refreshSharedItems() async {}
    func sharedChat(grant: String) async throws -> MeshChatView { throw MeshKernelError.notFound }
    func refreshShared(grant: String) async throws -> MeshRefreshReport { throw MeshKernelError.notFound }
    func sharedAttachment(grant: String, event: String) async throws -> Data { throw MeshKernelError.notFound }
}
