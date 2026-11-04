// The macOS side-question sheet opened with Command-; from the composer: owner-typed questions are
// answered through the turn_steer_v1 side_question action and the answer renders only here, never
// in the transcript, canvas or history.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct SideQuestionSheet: View {
        @Environment(AppModel.self) var model
        @Environment(ThemeStore.self) var theme
        @Environment(\.dismiss) private var dismiss
        @FocusState private var focused: Bool
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Side question").font(ConsoleTypography.headline).foregroundStyle(p.text)
                    Spacer(minLength: 0)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(p.muted)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close side question")
                    .accessibilityIdentifier("side-question-close")
                }
                Text(
                    model.sideQuestionPending
                        ? "Thinking…"
                        : "Ask about the running work. This stays out of the conversation."
                )
                .font(ConsoleTypography.caption)
                .foregroundStyle(p.muted)
                .accessibilityIdentifier("side-question-status")
                if let answer = model.sideQuestionAnswer {
                    ScrollView {
                        Text(answer)
                            .font(ConsoleTypography.subheadline)
                            .foregroundStyle(p.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    .accessibilityIdentifier("side-question-answer")
                }
                TextField("Ask a side question", text: Binding(
                    get: { model.sideQuestionDraft }, set: { model.sideQuestionDraft = $0 }
                ), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(8)
                .background(p.surface2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                .focused($focused)
                .onSubmit(ask)
                .accessibilityIdentifier("side-question-input")
                HStack {
                    Spacer()
                    Button {
                        ask()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Ask").font(ConsoleTypography.subheadline.weight(.semibold))
                            Image(systemName: "arrow.up")
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            canAsk ? AnyShapeStyle(p.primary) : AnyShapeStyle(p.surface2),
                            in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAsk)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Ask side question")
                    .accessibilityIdentifier("side-question-send")
                }
            }
            .padding(16)
            .frame(width: 420)
            .background(p.surface)
            .onAppear { focused = true }
            .accessibilityIdentifier("side-question-sheet")
        }

        private var canAsk: Bool {
            !model.sideQuestionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !model.sideQuestionPending
        }

        private func ask() {
            guard canAsk else { return }
            model.askSideQuestion(model.sideQuestionDraft)
            model.sideQuestionDraft = ""
        }
    }
#endif
