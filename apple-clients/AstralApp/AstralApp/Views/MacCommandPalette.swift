// Command search for the Mac workbench: the shared search field used by the palette, the agent directory and the
// chat list. MacWorkbenchView presents the palette and runs a chosen command after the sheet closes.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct MacSearchField: View {
        @Environment(ThemeStore.self) private var theme
        let prompt: String
        @Binding var text: String
        var focused: FocusState<Bool>.Binding
        let identifier: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.palette.muted).accessibilityHidden(true)
                TextField(prompt, text: $text).textFieldStyle(.plain).focused(focused)
                    .foregroundStyle(theme.palette.text)
                    .accessibilityLabel(prompt).accessibilityIdentifier(identifier)
            }
            .font(ConsoleTypography.subheadline)
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(theme.palette.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: AstralRadius.sm))
            .overlay(RoundedRectangle(cornerRadius: AstralRadius.sm).stroke(theme.palette.border))
        }
    }
#endif
