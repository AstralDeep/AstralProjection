// Draws one chat turn and the one-line status under a conversation, shared by the mesh chat screens.
// ChatBubble renders markdown and ComponentView payloads from the ChatTurn shape that MeshChatMapping produces.

import AstralCore
import SwiftUI

struct StatusLine: View {
    @Environment(ThemeStore.self) var theme
    let text: String
    let showsActivity: Bool
    var body: some View {
        HStack(spacing: 6) {
            if showsActivity {
                if ContinuousActivityPresentation.allowsAnimatedIndicators {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis")
                        .font(ConsoleTypography.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            Text(text).font(ConsoleTypography.caption).foregroundStyle(theme.palette.muted)
        }
    }
}

struct ChatBubble: View {
    @Environment(ThemeStore.self) var theme
    let turn: AppModel.ChatTurn
    private var p: AstralPalette { theme.palette }
    var body: some View {
        if turn.role == "reasoning" {
            ReasoningSnippet(text: turn.text)
        } else {
            let isUser = turn.role == "user"
            let isSteer = turn.role == "steer"
            let isOwner = isUser || isSteer
            HStack {
                if isOwner { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 8) {
                    if isSteer {
                        Text("Steer").font(ConsoleTypography.caption2.weight(.semibold))
                            .foregroundStyle(p.primary)
                            .accessibilityIdentifier("transcript-steer-label")
                    }
                    if !turn.text.isEmpty {
                        if isOwner {
                            Text(turn.text).foregroundStyle(p.text)
                        } else {
                            MarkdownBlockView(source: turn.text).foregroundStyle(p.text)
                        }
                    }
                    ForEach(Array(turn.components.enumerated()), id: \.offset) { _, component in
                        ComponentView(component: component)
                            .environment(\.astralNavigationTranscript, turn.id)
                    }
                }
                .font(ConsoleTypography.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(
                    isOwner ? AnyShapeStyle(p.primary.opacity(0.20)) : AnyShapeStyle(p.surface2),
                    in: RoundedRectangle(cornerRadius: AstralRadius.md)
                )
                .astralChartBackdrop(p, color: isOwner ? p.primary : p.surface2, opacity: isOwner ? 0.20 : 1)
                .overlay(
                    RoundedRectangle(cornerRadius: AstralRadius.md)
                        .stroke(isOwner ? p.primary.opacity(0.30) : .clear)
                )
                .frame(maxWidth: isOwner ? 300 : .infinity, alignment: isOwner ? .trailing : .leading)
                if !isOwner { Spacer(minLength: 20) }
            }
            .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
        }
    }
}

struct ReasoningSnippet: View {
    @Environment(ThemeStore.self) var theme
    let text: String
    @State private var expanded = false
    private var p: AstralPalette { theme.palette }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(expanded ? "▼" : "▶").font(ConsoleTypography.caption2).foregroundStyle(p.muted)
                    Text("Reasoning").font(ConsoleTypography.caption.weight(.medium)).foregroundStyle(p.muted)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text).font(ConsoleTypography.caption).foregroundStyle(p.text)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

enum ContinuousActivityPresentation {
    static var allowsAnimatedIndicators: Bool {
        #if os(macOS)
            false
        #else
            true
        #endif
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
