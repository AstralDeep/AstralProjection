// Request screens for mesh mode: the request cards shown in a chat and on the devices screen, and the form that sends a request to another member.
// Answering claims the request and runs a turn through MeshRuntime, and refusing sends one of a few reasons, so both stay deliberate owner actions.

import SwiftUI

struct MeshRequestRow: View {
    let request: MeshRequest
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var refusing = false
    private var p: AstralPalette { theme.palette }

    private var forThisDevice: Bool { request.toMember == mesh.status.deviceId }
    private var open: Bool { request.state == .pending || request.state == .claimed }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: forThisDevice ? "tray.and.arrow.down" : "paperplane").foregroundStyle(p.accent)
                    .accessibilityHidden(true)
                Text(forThisDevice ? "From " + mesh.memberLabel(request.fromMember) : "To " + mesh.memberLabel(request.toMember))
                    .font(ConsoleTypography.headline)
                Spacer()
                Text(MeshPresentation.requestState(request.state))
                    .font(ConsoleTypography.caption).foregroundStyle(stateColor)
                    .accessibilityIdentifier("mesh.request.state.\(request.requestId.suffix(8))")
            }
            Text(request.text).font(ConsoleTypography.body)
            if let tool = request.tool {
                Text("Uses " + tool).font(ConsoleTypography.caption).foregroundStyle(p.muted)
            }
            if request.state == .refused {
                Text(MeshPresentation.requestRefusal(request.refusalCode))
                    .font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                    .accessibilityIdentifier("mesh.request.reason.\(request.requestId.suffix(8))")
            }
            if forThisDevice && open {
                HStack {
                    Button("Answer") { Task { await mesh.answer(request) } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mesh.request.answer.\(request.requestId.suffix(8))")
                    Button("Refuse") { refusing = true }
                        .meshBordered()
                        .accessibilityIdentifier("mesh.request.refuse.\(request.requestId.suffix(8))")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.sm))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.request.\(request.requestId.suffix(8))")
        .confirmationDialog("Refuse this request?", isPresented: $refusing, titleVisibility: .visible) {
            ForEach(MeshRequestRefusal.allCases, id: \.self) { reason in
                Button(reason.title) { Task { await mesh.refuse(request, because: reason) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The sender sees the reason you choose.")
        }
    }

    private var stateColor: Color {
        switch request.state {
        case .pending, .claimed: return p.warning
        case .answered: return p.success
        case .refused: return p.error
        case .cancelled: return p.muted
        }
    }
}

struct MeshChatRequestList: View {
    @Environment(MeshRuntime.self) private var mesh

    var body: some View {
        if !mesh.chatRequests.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Requests").font(ConsoleTypography.caption).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(mesh.chatRequests) { MeshRequestRow(request: $0) }
            }
            .accessibilityIdentifier("mesh.chat.requests")
        }
    }
}

struct MeshSendRequestView: View {
    let member: MeshMember
    var initialText = ""
    @Environment(MeshRuntime.self) private var mesh
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var chatId: String?
    @State private var sending = false

    var body: some View {
        Form {
            Section("To " + member.label) {
                TextField("What should it do?", text: $text, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("mesh.sendrequest.text")
            }
            Section {
                Picker("Chat", selection: $chatId) {
                    Text("New chat").tag(String?.none)
                    ForEach(mesh.chats) { Text($0.title).tag(Optional($0.chatId)) }
                }
                .accessibilityIdentifier("mesh.sendrequest.chat")
            } footer: {
                Text("The device answers in the chat when it is online.")
            }
            Section {
                Button {
                    Task {
                        sending = true
                        if await mesh.sendRequest(text, to: member, in: chatId) { dismiss() }
                        sending = false
                    }
                } label: {
                    Text("Send request").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .accessibilityIdentifier("mesh.sendrequest.send")
            }
        }
        .navigationTitle("Send a request")
        .onAppear {
            chatId = mesh.currentChatId
            if text.isEmpty { text = initialText }
        }
    }
}
