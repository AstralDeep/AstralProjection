import AstralCore
// Feature 051 — the History screen (Android HistoryScreen parity): recent chats
// (from the server-owned history surface, with `history_list` fallback); a
// skeleton while loading; tap opens the conversation.
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Group {
            if model.historyLoading && model.history.isEmpty {
                SkeletonList()
            } else if model.history.isEmpty {
                VStack(spacing: 8) {
                    Text("💬").font(.system(size: 40))
                    Text("No conversations yet.").foregroundStyle(p.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        HistoryHeader(title: model.historyTitle, count: model.history.count)
                        ForEach(model.history) { chat in
                            Button {
                                model.openChat(chat.id)
                            } label: {
                                HistoryRow(chat: chat)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    model.deleteChat(chat.id)
                                } label: {
                                    Label("Delete conversation", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.bg)
    }

}

struct HistoryHeader: View {
    let title: String
    let count: Int
    @Environment(ThemeStore.self) var theme

    var body: some View {
        HStack {
            Text(verbatim: (title.isEmpty ? "Recent chats" : title).uppercased()).tracking(0.88)
                .foregroundStyle(theme.palette.muted)
            Spacer()
            Text("\(count)")
                .foregroundStyle(theme.palette.text.opacity(0.7))
                .padding(.horizontal, 8).padding(.vertical, 1)
                .background(theme.palette.text.opacity(0.06), in: Capsule())
        }
        .font(AstralTypography.sans(11, relativeTo: .caption).weight(.semibold))
        .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 6)
    }
}

struct HistoryRow: View {
    let chat: ChatSummary
    @Environment(ThemeStore.self) var theme
    @State private var hovered = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: chat.icon)
                .font(.system(size: 15))
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(
                        colors: chat.icon.isEmpty
                            ? [p.text.opacity(0.05), p.text.opacity(0.05)]
                            : [p.primary.opacity(0.22), p.secondary.opacity(0.14)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                        chat.icon.isEmpty ? p.text.opacity(0.08) : p.primary.opacity(0.2), lineWidth: 1)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: chat.displayTitle)
                        .font(AstralTypography.sans(13, relativeTo: .body).weight(.semibold))
                        .foregroundStyle(p.text).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let time = chat.relativeTime()
                    if !time.isEmpty {
                        Text(verbatim: time).font(AstralTypography.sans(11, relativeTo: .caption))
                            .monospacedDigit().foregroundStyle(p.muted)
                    }
                }
                if !chat.displayPreview.isEmpty {
                    Text(verbatim: chat.displayPreview).font(AstralTypography.sans(12, relativeTo: .caption))
                        .foregroundStyle(p.muted).lineLimit(1)
                }
            }
            if chat.hasSavedComponents {
                Text("★").font(AstralTypography.sans(11, relativeTo: .caption)).foregroundStyle(p.accent)
                    .accessibilityLabel("Has saved components")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(hovered ? p.text.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AstralRadius.md).strokeBorder(
                hovered ? p.primary.opacity(0.28) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
