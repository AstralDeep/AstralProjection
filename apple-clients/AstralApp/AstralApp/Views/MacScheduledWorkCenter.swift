// Presents an owner-scoped macOS view of durable scheduled jobs and their server-owned controls.
// Each request is tied to the current account and server so stale responses cannot cross sign-ins.

#if os(macOS)
    import AstralCore
    import CryptoKit
    import Observation
    import SwiftUI

    struct MacScheduledRunIntentStore {
        let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) { self.defaults = defaults }

        func load(jobID: String, owner: AppModel.DownloadOwner, server: URL) -> UUID? {
            guard let key = key(jobID: jobID, owner: owner, server: server),
                let value = defaults.string(forKey: key), Self.validUUID4(value)
            else { return nil }
            return UUID(uuidString: value)
        }

        func contains(jobID: String, owner: AppModel.DownloadOwner, server: URL) -> Bool {
            guard let key = key(jobID: jobID, owner: owner, server: server) else { return false }
            return defaults.object(forKey: key) != nil
        }

        func save(_ id: UUID, jobID: String, owner: AppModel.DownloadOwner, server: URL) -> Bool {
            guard let key = key(jobID: jobID, owner: owner, server: server) else { return false }
            let value = id.uuidString.lowercased()
            guard Self.validUUID4(value) else { return false }
            defaults.set(value, forKey: key)
            return defaults.synchronize() && defaults.string(forKey: key) == value
        }

        func clear(jobID: String, owner: AppModel.DownloadOwner, server: URL) -> Bool {
            guard let key = key(jobID: jobID, owner: owner, server: server) else { return false }
            defaults.removeObject(forKey: key)
            return defaults.synchronize() && defaults.object(forKey: key) == nil
        }

        private func key(jobID: String, owner: AppModel.DownloadOwner, server: URL) -> String? {
            guard let account = owner.account, Self.validUUID4(jobID) else { return nil }
            let scope = [account.issuer, account.subject, server.absoluteString, jobID]
                .joined(separator: "\u{0}")
            let digest = SHA256.hash(data: Data(scope.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return "astraldeep.schedule.run_now.v1." + digest
        }

        private static func validUUID4(_ value: String) -> Bool {
            value.range(
                of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                options: .regularExpression) != nil
        }
    }

    @MainActor @Observable
    final class MacScheduledWorkStore {
        private(set) var jobs: [ScheduledWorkJob] = []
        var selectedID: String?
        private(set) var loading = false
        private(set) var acting = false
        private(set) var error: String?
        private(set) var notice: String?

        private let model: AppModel
        private let runIntents: MacScheduledRunIntentStore
        private var updateRequired: Bool
        private var owner: AppModel.DownloadOwner
        private var server: URL
        private var generation = UUID()

        init(
            model: AppModel, updateRequired: Bool,
            runIntents: MacScheduledRunIntentStore? = nil
        ) {
            self.model = model
            self.runIntents = runIntents ?? MacScheduledRunIntentStore()
            self.updateRequired = updateRequired
            owner = model.downloadOwner
            server = model.serverBase
        }

        var selected: ScheduledWorkJob? { jobs.first { $0.id == selectedID } }
        func unresolvedRun(for job: ScheduledWorkJob) -> Bool {
            runIntents.contains(jobID: job.id, owner: owner, server: server)
        }
        var canControl: Bool {
            model.signedIn && model.connected && !updateRequired
                && owner == model.downloadOwner && server == model.serverBase
        }

        func refresh() async {
            guard currentScope(), let rest = scopedRest() else { return }
            let request = UUID()
            generation = request
            loading = true
            error = nil
            defer { if generation == request { loading = false } }
            do {
                let received = try await rest.scheduledWorkJobs()
                guard accepts(request) else { return }
                jobs = received.sorted {
                    ($0.nextRunAtMillis ?? Int64.max, $0.name, $0.id)
                        < ($1.nextRunAtMillis ?? Int64.max, $1.name, $1.id)
                }
                if let selectedID, !jobs.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            } catch {
                if accepts(request) { self.error = "Scheduled work could not be refreshed. Try again." }
            }
        }

        func control(_ action: ScheduledWorkAction, expected: ScheduledWorkJob) async {
            guard !acting, canControl, currentScope(), let current = selected,
                current == expected,
                action == .pause && current.canPause || action == .resume && current.canResume
                    || action.isRunNow && current.canRunNow,
                let rest = scopedRest()
            else { return }
            let request = generation
            acting = true
            error = nil
            notice = nil
            defer { acting = false }
            var effectiveAction = action
            if case .runNow(let proposedID) = action {
                let submissionID: UUID
                if runIntents.contains(jobID: current.id, owner: owner, server: server) {
                    guard let pending = runIntents.load(jobID: current.id, owner: owner, server: server)
                    else {
                        error = "The saved run request cannot be read. No new request was sent."
                        return
                    }
                    submissionID = pending
                } else {
                    guard runIntents.save(proposedID, jobID: current.id, owner: owner, server: server)
                    else {
                        error = "The run request could not be saved locally. Try again before sending it."
                        return
                    }
                    submissionID = proposedID
                }
                effectiveAction = .runNow(submissionId: submissionID)
            }
            do {
                try await rest.scheduledWorkAction(id: current.id, action: effectiveAction)
                guard accepts(request) else { return }
                if action.isRunNow {
                    if runIntents.clear(jobID: current.id, owner: owner, server: server) {
                        notice = "Run queued. Refresh to follow its state."
                    } else {
                        notice = "Run request confirmed. The local retry marker could not be cleared."
                    }
                }
                await refresh()
            } catch {
                guard accepts(request) else { return }
                let message =
                    action.isRunNow
                    ? "The run outcome is unknown. Retry sends the same request without queuing a second run."
                    : "The schedule could not be changed. Refresh and try again."
                await refresh()
                if canControl { self.error = message }
            }
        }

        func identityChanged() {
            guard owner != model.downloadOwner || server != model.serverBase else { return }
            owner = model.downloadOwner
            server = model.serverBase
            clear()
        }

        func signedOut() { clear() }

        func updateGateChanged(_ required: Bool) {
            updateRequired = required
            if required { clear() }
        }

        private func clear() {
            generation = UUID()
            jobs = []
            selectedID = nil
            error = nil
            notice = nil
            loading = false
            acting = false
        }

        private func currentScope() -> Bool {
            guard owner == model.downloadOwner, server == model.serverBase else {
                identityChanged()
                return false
            }
            guard model.signedIn, owner.signedIn, !updateRequired else {
                clear()
                return false
            }
            return true
        }

        private func scopedRest() -> RestClient? {
            guard owner == model.downloadOwner, server == model.serverBase, model.signedIn, owner.signedIn
            else { return nil }
            return model.scopedRest(owner: owner, server: server)
        }

        private func accepts(_ request: UUID) -> Bool {
            request == generation && owner == model.downloadOwner && server == model.serverBase
                && model.signedIn && owner.signedIn && !updateRequired
        }
    }

    extension ScheduledWorkAction {
        fileprivate var isRunNow: Bool {
            if case .runNow = self { return true }
            return false
        }
    }

    struct MacScheduledWorkCenter: View {
        @Environment(AppModel.self) private var model
        @State private var store: MacScheduledWorkStore
        @State private var runConfirmation: ScheduledWorkJob?
        let updateRequired: Bool

        init(model: AppModel, updateRequired: Bool) {
            self.updateRequired = updateRequired
            _store = State(initialValue: MacScheduledWorkStore(model: model, updateRequired: updateRequired))
        }

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Scheduled work").font(.title2.weight(.semibold))
                        Spacer()
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 32, height: 32)
                        }
                        .help("Refresh scheduled work")
                        .disabled(store.loading)
                        .accessibilityIdentifier("mac-schedule-refresh")
                    }
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                    if let notice = store.notice { Text(notice).foregroundStyle(.secondary) }
                    if store.jobs.isEmpty && !store.loading {
                        ContentUnavailableView("No scheduled work", systemImage: "calendar.badge.clock")
                    } else {
                        List(store.jobs, selection: $store.selectedID) { job in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.name).font(.headline).lineLimit(2)
                                Text(
                                    "\(job.status.capitalized) · \(job.scheduleKind.replacingOccurrences(of: "_", with: " "))"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                if let next = Self.nextRunDateText(for: job) {
                                    Text("Next \(next)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(job.id)
                            .accessibilityIdentifier("mac-schedule-job-\(job.id)")
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360).padding()
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            }
            .frame(minWidth: 760, minHeight: 480)
            .task { await store.refresh() }
            .onChange(of: updateRequired) { _, required in
                runConfirmation = nil
                store.updateGateChanged(required)
                if !required { Task { await store.refresh() } }
            }
            .onChange(of: model.downloadOwner) { _, _ in
                runConfirmation = nil
                store.identityChanged()
                Task { await store.refresh() }
            }
            .onChange(of: model.serverBaseText) { _, _ in
                runConfirmation = nil
                store.identityChanged()
                Task { await store.refresh() }
            }
            .onChange(of: model.signedIn) { _, signedIn in
                if signedIn {
                    Task { await store.refresh() }
                } else {
                    runConfirmation = nil
                    store.signedOut()
                }
            }
            .onChange(of: model.connected) { _, connected in if connected { Task { await store.refresh() } } }
            .confirmationDialog(
                store.selected.map(store.unresolvedRun(for:)) == true
                    ? "Retry this run request?" : "Run this schedule now?",
                isPresented: Binding(
                    get: { runConfirmation != nil },
                    set: { if !$0 { runConfirmation = nil } }),
                titleVisibility: .visible,
                presenting: runConfirmation
            ) { job in
                Button(store.unresolvedRun(for: job) ? "Retry request" : "Run now") {
                    runConfirmation = nil
                    Task { await store.control(.runNow(submissionId: UUID()), expected: job) }
                }
                .accessibilityIdentifier("mac-schedule-run-confirm")
                Button("Keep schedule", role: .cancel) { runConfirmation = nil }
            } message: { job in
                Text(
                    store.unresolvedRun(for: job)
                        ? "AstralDeep will replay the same request for “\(job.name)” to resolve its outcome."
                        : "AstralDeep will queue “\(job.name)” for immediate execution under its existing consent and permissions."
                )
            }
        }

        @ViewBuilder private var detail: some View {
            if let job = store.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(job.name).font(.largeTitle.weight(.semibold))
                        LabeledContent("Status", value: job.status.capitalized)
                        LabeledContent("Schedule", value: job.scheduleKind.replacingOccurrences(of: "_", with: " "))
                        LabeledContent("Expression", value: job.scheduleExpression)
                        LabeledContent("Time zone", value: job.timezone)
                        if let next = Self.nextRunDateText(for: job) { LabeledContent("Next run", value: next) }
                        if let last = job.lastRunAtMillis { LabeledContent("Last run", value: Self.date(last)) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Instruction").font(.headline)
                            Text(job.instruction).textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Granted tool scopes").font(.headline)
                            Text(job.consentedScopes.isEmpty ? "None" : job.consentedScopes.joined(separator: ", "))
                                .textSelection(.enabled)
                        }
                        HStack {
                            if job.canPause {
                                Button("Pause") { Task { await store.control(.pause, expected: job) } }
                                    .accessibilityIdentifier("mac-schedule-pause")
                            }
                            if job.canResume {
                                Button("Resume") { Task { await store.control(.resume, expected: job) } }
                                    .accessibilityIdentifier("mac-schedule-resume")
                            }
                            if job.canRunNow {
                                Button(store.unresolvedRun(for: job) ? "Retry run request" : "Run now") {
                                    runConfirmation = job
                                }
                                .accessibilityIdentifier("mac-schedule-run")
                            }
                        }
                        .disabled(!store.canControl || store.acting)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Select a schedule", systemImage: "calendar.badge.clock")
            }
        }

        static func nextRunDateText(for job: ScheduledWorkJob) -> String? {
            guard job.status == "active", let next = job.nextRunAtMillis else { return nil }
            return date(next)
        }

        private static func date(_ millis: Int64) -> String {
            Date(timeIntervalSince1970: Double(millis) / 1000)
                .formatted(date: .abbreviated, time: .shortened)
        }
    }
#endif
