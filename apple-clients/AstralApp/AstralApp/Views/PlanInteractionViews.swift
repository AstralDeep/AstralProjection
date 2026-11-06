// The macOS plan_interaction_v1 surfaces docked above the workbench composer: the plan proposal card with its
// three owner decisions, the ask_user question panel with numbered options and free text, and the plan-mode
// notice and blocked states; every control sends a stable owner action and renders only server-owned state.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct PlanModeBadge: View {
        @Environment(AppModel.self) var model
        @Environment(ThemeStore.self) var theme
        private var p: AstralPalette { theme.palette }

        var body: some View {
            if model.planModeActive {
                HStack(spacing: 4) {
                    Image(systemName: "list.clipboard").font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Plan").font(ConsoleTypography.caption2.weight(.bold))
                }
                .foregroundStyle(p.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(p.primary.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(p.primary.opacity(0.4)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Plan mode is on")
                .accessibilityIdentifier("chat-mode-badge")
            }
        }
    }

    struct PlanInteractionDock: View {
        @Environment(AppModel.self) var model
        @Environment(ThemeStore.self) var theme
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(spacing: 8) {
                if let notice = model.activePlanInteraction?.notice {
                    PlanNoticeRow(
                        symbol: "info.circle", text: notice, identifier: "plan-mode-notice", palette: p)
                }
                if let blocked = model.activePlanInteraction?.blocked {
                    PlanNoticeRow(
                        symbol: "exclamationmark.triangle", text: blocked, identifier: "question-blocked",
                        tone: .warning, palette: p)
                }
                if model.activePlanInteraction?.proposal != nil {
                    PlanProposalCard()
                }
                if model.activePlanInteraction?.question != nil {
                    QuestionPanel()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    struct PlanNoticeRow: View {
        enum Tone { case neutral, warning }

        let symbol: String
        let text: String
        let identifier: String
        var tone: Tone = .neutral
        let palette: AstralPalette

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tone == .warning ? palette.warning : palette.muted)
                    .accessibilityHidden(true)
                Text(text).font(ConsoleTypography.caption).foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        }
    }

    struct PlanProposalCard: View {
        @Environment(AppModel.self) var model
        @Environment(ThemeStore.self) var theme
        private var p: AstralPalette { theme.palette }
        private var proposal: PlanProposal? { model.activePlanInteraction?.proposal }
        private var approved: Bool { model.activePlanInteraction?.status == .approved }

        var body: some View {
            if let proposal {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.clipboard").foregroundStyle(p.primary)
                            .accessibilityHidden(true)
                        Text("Proposed plan").font(ConsoleTypography.subheadline.weight(.semibold))
                            .foregroundStyle(p.text)
                        Text("v\(proposal.version)").font(ConsoleTypography.caption)
                            .foregroundStyle(p.muted)
                        Spacer(minLength: 0)
                        if approved {
                            Text("Approved").font(ConsoleTypography.caption.weight(.semibold))
                                .foregroundStyle(p.success)
                                .accessibilityIdentifier("plan-status-approved")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("plan-card-title")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            section("Steps") {
                                ForEach(Array(proposal.steps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("\(index + 1).").font(ConsoleTypography.caption.weight(.semibold))
                                            .foregroundStyle(p.primary)
                                        Text(step).font(ConsoleTypography.caption).foregroundStyle(p.text)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            if !proposal.assumptions.isEmpty {
                                section("Assumptions") {
                                    ForEach(proposal.assumptions, id: \.self) { assumption in
                                        bullet(assumption)
                                    }
                                }
                            }
                            if !proposal.files.isEmpty {
                                section("Files it expects to touch") {
                                    ForEach(proposal.files, id: \.self) { file in
                                        bullet(file)
                                    }
                                }
                            }
                            if !proposal.apps.isEmpty {
                                section("Apps it expects to drive") {
                                    ForEach(proposal.apps, id: \.self) { app in
                                        bullet(app)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .accessibilityIdentifier("plan-card-details")
                    if model.activePlanInteraction?.reviseActive == true {
                        planRevisionField
                    } else {
                        planActions
                    }
                }
                .padding(12)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.border))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Plan proposal version \(proposal.version)")
                .accessibilityIdentifier("plan-proposal-card")
            }
        }

        private var planActions: some View {
            HStack(spacing: 8) {
                Button {
                    model.approvePlan()
                } label: {
                    Text("Approve").font(ConsoleTypography.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(p.primary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Approve plan")
                .accessibilityIdentifier("plan-approve")
                .help("Approve this plan and let the agent proceed")
                Button {
                    model.beginPlanRevision()
                } label: {
                    Text("Revise").font(ConsoleTypography.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(p.text)
                        .background(p.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Revise plan")
                .accessibilityIdentifier("plan-revise")
                .help("Send feedback and get a revised plan")
                Button {
                    model.approvePlanWithReview()
                } label: {
                    Text("Approve with manual review").font(ConsoleTypography.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(p.text)
                        .background(p.surface2, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Approve plan with manual review")
                .accessibilityIdentifier("plan-approve-review")
                .help("Approve the plan; you review each action before it runs")
                Spacer(minLength: 0)
            }
        }

        private var planRevisionField: some View {
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    "What should change in this plan?",
                    text: Binding(
                        get: { model.activePlanInteraction?.reviseDraft ?? "" },
                        set: { model.setPlanReviseDraft($0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ConsoleTypography.caption)
                    .lineLimit(2...5)
                    .padding(8)
                    .background(p.surface2, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                    .onSubmit { model.sendPlanRevision() }
                    .accessibilityLabel("Plan revision feedback")
                    .accessibilityIdentifier("plan-revise-feedback")
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button {
                        model.cancelPlanRevision()
                    } label: {
                        Text("Cancel").font(ConsoleTypography.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(p.muted)
                    .accessibilityIdentifier("plan-revise-cancel")
                    Button {
                        model.sendPlanRevision()
                    } label: {
                        Text("Send revision").font(ConsoleTypography.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(p.primary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!planRevisionSendable)
                    .accessibilityLabel("Send plan revision")
                    .accessibilityIdentifier("plan-revise-send")
                }
            }
        }

        private var planRevisionSendable: Bool {
            !(model.activePlanInteraction?.reviseDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }

        private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(ConsoleTypography.caption2.weight(.bold))
                    .foregroundStyle(p.muted)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func bullet(_ text: String) -> some View {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(p.muted)
                Text(text).font(ConsoleTypography.caption).foregroundStyle(p.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    enum QuestionPanelKeys {
        enum Route: Equatable {
            case option(Int)
            case submit
            case ignored
        }

        static func route(key: Character, complete: Bool, editingInPanel: Bool) -> Route {
            if editingInPanel { return .ignored }
            if let digit = key.wholeNumberValue, (1...9).contains(digit) {
                return .option(digit - 1)
            }
            if key == "\r" || key == "\n" {
                return complete ? .submit : .ignored
            }
            return .ignored
        }
    }

    struct QuestionPanel: View {
        @Environment(AppModel.self) var model
        @Environment(ThemeStore.self) var theme
        private var p: AstralPalette { theme.palette }
        private var request: QuestionRequest? { model.activePlanInteraction?.question }
        private var submitted: Bool { model.activePlanInteraction?.questionSubmitted == true }

        var body: some View {
            if let request {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.bubble").foregroundStyle(p.primary)
                            .accessibilityHidden(true)
                        Text("AstralDeep needs your answer").font(ConsoleTypography.subheadline.weight(.semibold))
                            .foregroundStyle(p.text)
                        Spacer(minLength: 0)
                        if submitted {
                            Text("Sent…").font(ConsoleTypography.caption).foregroundStyle(p.muted)
                                .accessibilityIdentifier("question-submitted-label")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("question-panel-title")
                    ForEach(Array(request.prompts.enumerated()), id: \.element.id) { index, prompt in
                        questionRow(index: index, prompt: prompt)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button {
                            model.skipQuestions()
                        } label: {
                            Text("Skip").font(ConsoleTypography.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(p.text)
                                .background(p.surface2, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                        }
                        .buttonStyle(.plain)
                        .disabled(submitted)
                        .accessibilityLabel("Skip questions")
                        .accessibilityIdentifier("question-skip")
                        Button {
                            model.submitQuestionAnswers()
                        } label: {
                            Text("Submit").font(ConsoleTypography.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(.white)
                                .background(
                                    model.activeQuestionComplete ? AnyShapeStyle(p.primary) : AnyShapeStyle(p.surface2),
                                    in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.activeQuestionComplete || submitted)
                        .accessibilityLabel("Submit answers")
                        .accessibilityIdentifier("question-submit")
                        .help("Return submits once every question has an answer")
                    }
                    Text(
                        submitted
                            ? "Waiting for the server to record your answers."
                            : "Press a number to answer the first open question. Return submits when every question has an answer."
                    )
                    .font(ConsoleTypography.caption2).foregroundStyle(p.muted)
                    .accessibilityIdentifier("question-panel-hint")
                }
                .padding(12)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.border))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Question panel")
                .accessibilityIdentifier("question-panel")
                .background(QuestionPanelKeyMonitor(model: model))
            }
        }

        private func questionRow(index: Int, prompt: QuestionPrompt) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.prompt).font(ConsoleTypography.caption.weight(.medium)).foregroundStyle(p.text)
                    .accessibilityIdentifier("question-prompt-\(index + 1)")
                if !prompt.options.isEmpty {
                    FlowLayoutOrRow(options: prompt.options) { optionIndex, option in
                        optionButton(index: index, prompt: prompt, optionIndex: optionIndex, option: option)
                    }
                }
                TextField(
                    "Or type your own answer",
                    text: Binding(
                        get: { freeText(for: prompt) },
                        set: { model.setQuestionFreeText(prompt, $0) }))
                    .textFieldStyle(.plain)
                    .font(ConsoleTypography.caption)
                    .padding(6)
                    .background(p.surface2, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                    .onSubmit { model.submitQuestionAnswers() }
                    .disabled(submitted)
                    .accessibilityLabel("Your own answer for question \(index + 1)")
                    .accessibilityIdentifier("question-free-text-\(index + 1)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Question \(index + 1)")
            .accessibilityIdentifier("question-row-\(index + 1)")
        }

        private func optionButton(index: Int, prompt: QuestionPrompt, optionIndex: Int, option: String) -> some View {
            let selected = model.questionAnswer(for: prompt) == option
            return Button {
                model.selectQuestionOption(prompt, optionIndex: optionIndex)
            } label: {
                HStack(spacing: 4) {
                    Text("\(optionIndex + 1)").font(ConsoleTypography.caption2.weight(.bold))
                    Text(option).font(ConsoleTypography.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(selected ? .white : p.text)
                .background(selected ? p.primary : p.surface2, in: Capsule())
                .overlay(Capsule().stroke(selected ? p.primary : p.border))
            }
            .buttonStyle(.plain)
            .disabled(submitted)
            .accessibilityLabel("Question \(index + 1) option \(optionIndex + 1): \(option)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("question-option-\(index + 1)-\(optionIndex + 1)")
        }

        private func freeText(for prompt: QuestionPrompt) -> String {
            guard let answer = model.questionAnswer(for: prompt) else { return "" }
            return prompt.options.contains(answer) ? "" : answer
        }
    }

    private struct FlowLayoutOrRow<Content: View>: View {
        let options: [String]
        @ViewBuilder let content: (Int, String) -> Content

        var body: some View {
            if options.count <= 3 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        content(index, option)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            content(index, option)
                        }
                    }
                }
            }
        }
    }

    struct QuestionPanelKeyMonitor: NSViewRepresentable {
        let model: AppModel

        static func isEditingWithin(_ view: NSView) -> Bool {
            guard let responder = view.window?.firstResponder as? NSView else { return false }
            var current: NSView? = responder
            while let node = current {
                if node === view { return true }
                current = node.superview
            }
            return false
        }

        static func firstUnanswered(model: AppModel) -> QuestionPrompt? {
            guard let state = model.activePlanInteraction, let request = state.question else { return nil }
            return request.prompts.first { prompt in
                state.questionAnswers[prompt.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            } ?? request.prompts.last
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            context.coordinator.view = view
            context.coordinator.model = model
            context.coordinator.start()
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            context.coordinator.view = view
            context.coordinator.model = model
        }

        static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

        @MainActor
        final class Coordinator {
            weak var view: NSView?
            weak var model: AppModel?
            private var monitor: Any?

            func start() {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    MainActor.assumeIsolated { self?.consume(event) ?? event }
                }
            }

            func stop() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }

            func consume(_ event: NSEvent) -> NSEvent? {
                guard let view, let model,
                    let window = view.window, event.window === window,
                    let character = event.charactersIgnoringModifiers?.first
                else { return event }
                let editing = QuestionPanelKeyMonitor.isEditingWithin(view)
                let complete =
                    model.activeQuestionComplete
                    && model.activePlanInteraction?.questionSubmitted != true
                switch QuestionPanelKeys.route(key: character, complete: complete, editingInPanel: editing) {
                case .option(let optionIndex):
                    guard let prompt = QuestionPanelKeyMonitor.firstUnanswered(model: model),
                        optionIndex < prompt.options.count
                    else { return event }
                    model.selectQuestionOption(prompt, optionIndex: optionIndex)
                    return nil
                case .submit:
                    model.submitQuestionAnswers()
                    return nil
                case .ignored:
                    return event
                }
            }
        }
    }
#endif
