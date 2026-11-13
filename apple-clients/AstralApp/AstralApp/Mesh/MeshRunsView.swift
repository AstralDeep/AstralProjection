// The runs and learning screen: runs with their status and executing device, hand off to another device, take over with the consent sheet, and learned items with review, adopt, decline and undo.
// Every action goes through MeshRuntime to the kernel, which authorizes it, so this view only draws state and asks.

import SwiftUI

struct MeshRunsView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var takenOver: MeshTakeOver?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        List {
            Section("Runs") {
                if mesh.runs.isEmpty {
                    Text("No runs yet.").foregroundStyle(p.muted).accessibilityIdentifier("mesh.runs.none")
                }
                ForEach(mesh.runs) { run in
                    MeshRunRow(run: run) { takenOver = $0 }
                }
            }
            Section("Learning") {
                if mesh.proposals.isEmpty {
                    Text("Nothing has been proposed to learn.").foregroundStyle(p.muted)
                        .accessibilityIdentifier("mesh.learning.none")
                }
                ForEach(mesh.proposals) { proposal in
                    MeshProposalRow(proposal: proposal)
                }
            }
        }
        .navigationTitle("Runs")
        .refreshable {
            await mesh.refreshRuns()
            await mesh.refreshProposals()
        }
        .task {
            await mesh.refreshRuns()
            await mesh.refreshProposals()
        }
        .alert(
            "Run taken over", isPresented: Binding(get: { takenOver != nil }, set: { if !$0 { takenOver = nil } })
        ) {
            Button("OK") { takenOver = nil }
        } message: {
            Text(
                (takenOver?.unknownSteps ?? 0) > 0
                    ? "\(takenOver?.unknownSteps ?? 0) earlier steps may have already run. Check them before it repeats anything."
                    : "This device is now running it.")
        }
    }
}

struct MeshRunRow: View {
    let run: MeshRun
    let onTakeOver: (MeshTakeOver) -> Void
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var confirmingTakeover = false
    private var p: AstralPalette { theme.palette }

    private var executorLabel: String? { mesh.members.first { $0.memberId == run.executor }?.label }
    private var targets: [MeshMember] { mesh.members.filter { !$0.isThisDevice && $0.memberId != run.executor } }
    private var live: Bool { run.status == .active || run.status == .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.goal).font(ConsoleTypography.headline).lineLimit(2)
                Spacer()
                Text(MeshPresentation.runStatus(run)).font(ConsoleTypography.caption)
                    .foregroundStyle(run.status == .active ? p.success : p.muted)
            }
            Text(
                MeshPresentation.runKind(run.kind) + ". " + MeshPresentation.runRole(run, executorLabel: executorLabel)
                    + ". \(run.rounds) rounds"
            )
            .font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            if let reason = run.reason, !reason.isEmpty {
                Text(reason).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            }
            if run.unknownSteps > 0 {
                Label("\(run.unknownSteps) steps with an unknown result", systemImage: "exclamationmark.triangle.fill")
                    .font(ConsoleTypography.caption).foregroundStyle(p.warning)
            }
            if live {
                HStack {
                    if run.role != .executor {
                        Button("Take over") { confirmingTakeover = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("mesh.run.takeover.\(run.runId)")
                    }
                    Menu("Hand off") {
                        ForEach(targets) { member in
                            Button(member.label) { Task { await mesh.handOff(run, to: member) } }
                        }
                    }
                    .disabled(targets.isEmpty || run.role != .executor)
                    .accessibilityIdentifier("mesh.run.handoff.\(run.runId)")
                }
                .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.run.\(run.runId)")
        .confirmationDialog("Take over this run?", isPresented: $confirmingTakeover, titleVisibility: .visible) {
            Button("Take over with biometrics") {
                Task { if let result = await mesh.takeOver(run) { onTakeOver(result) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device will run it from now on, and the other device stops.")
        }
    }
}

struct MeshProposalRow: View {
    let proposal: MeshProposal
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var result: MeshEvaluation?
    private var p: AstralPalette { theme.palette }

    private var reviewable: Bool {
        [.staged, .gated, .replayed, .waitingOwner].contains(proposal.status)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(proposal.content).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                if !proposal.tools.isEmpty {
                    Text("Tools: " + proposal.tools.joined(separator: ", ")).font(ConsoleTypography.footnote)
                }
                if proposal.untrusted {
                    Label("Learned from untrusted content", systemImage: "exclamationmark.triangle.fill")
                        .font(ConsoleTypography.caption).foregroundStyle(p.warning)
                }
                checks
                ForEach(proposal.ownerReasons + proposal.hygiene + proposal.detail, id: \.self) { reason in
                    Text(reason).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                }
                if let result {
                    Text(MeshPresentation.evaluation(result)).font(ConsoleTypography.footnote)
                        .accessibilityIdentifier("mesh.proposal.result.\(proposal.proposalId)")
                }
                actions
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(proposal.name).font(ConsoleTypography.headline)
                    Text(proposal.kind.capitalized).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                }
                Spacer()
                Text(MeshPresentation.proposalStatus(proposal.status)).font(ConsoleTypography.caption)
                    .foregroundStyle(proposal.status == .adopted ? p.success : p.muted)
            }
        }
        .accessibilityIdentifier("mesh.proposal.\(proposal.proposalId)")
    }

    @ViewBuilder private var checks: some View {
        if let gate = proposal.gatePassed {
            Label(gate ? "Safety checks passed" : "Safety checks failed", systemImage: gate ? "checkmark.shield" : "xmark.shield")
                .font(ConsoleTypography.caption).foregroundStyle(gate ? p.success : p.error)
        }
        if let replay = proposal.replayPassed {
            Label(replay ? "Replay passed" : "Replay failed", systemImage: replay ? "checkmark.circle" : "xmark.circle")
                .font(ConsoleTypography.caption).foregroundStyle(replay ? p.success : p.error)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if reviewable {
                Button("Adopt") { Task { result = await mesh.review(proposal, adopt: true) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mesh.proposal.adopt.\(proposal.proposalId)")
                Button("Decline", role: .destructive) { Task { result = await mesh.review(proposal, adopt: false) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mesh.proposal.decline.\(proposal.proposalId)")
            }
            if proposal.status == .adopted {
                Button("Undo") { Task { await mesh.undo(proposal) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mesh.proposal.undo.\(proposal.proposalId)")
            }
        }
    }
}
