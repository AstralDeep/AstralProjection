// Presents owner-scoped Work operations in a native Mac inbox using the authenticated REST client.
// The server remains authoritative for operation state, revision fencing, results, and controls.

#if os(macOS)
    import AstralCore
    import Observation
    import SwiftUI

    struct MacWorkOperation: Identifiable, Equatable, Sendable {
        static let dispositions: Set<String> = [
            "queued", "active", "awaiting_approval", "awaiting_authority", "budget_blocked",
            "reconciliation_required", "paused", "awaiting_event", "retry_eligible", "completed",
            "failed", "cancelled", "unsupported_version",
        ]
        let id: String
        let revision: Int
        let title: String
        let disposition: String
        let phase: String
        let createdAt: String?
        let updatedAt: String?
        let nextWakeAt: String?
        let safeErrorCode: String?
        let usage: JSONValue

        init?(json: JSONValue) {
            guard let fields = json.objectValue,
                let id = fields["id"]?.stringValue, Self.validID(id),
                let revision = fields["revision"]?.numberValue, revision >= 1,
                revision.rounded() == revision, revision <= 9_007_199_254_740_991,
                let title = fields["title"]?.stringValue, title.utf8.count <= 4096,
                let disposition = fields["disposition"]?.stringValue,
                let phase = fields["phase"]?.stringValue, phase.utf8.count <= 256,
                let usage = fields["usage"]
            else { return nil }
            self.id = id
            self.revision = Int(revision)
            self.title = title
            self.disposition = disposition
            self.phase = phase
            createdAt = fields["created_at"]?.stringValue
            updatedAt = fields["updated_at"]?.stringValue
            nextWakeAt = fields["next_wake_at"]?.stringValue
            safeErrorCode = fields["safe_error_code"]?.stringValue
            self.usage = usage
        }

        static func validID(_ value: String) -> Bool {
            value.range(
                of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                options: .regularExpression) != nil
        }

        var canPause: Bool {
            [
                "queued", "active", "awaiting_approval", "awaiting_authority", "budget_blocked",
                "reconciliation_required", "awaiting_event", "retry_eligible",
            ].contains(disposition)
        }
        var canResume: Bool { disposition == "paused" }
        var canCancel: Bool {
            Self.dispositions.contains(disposition)
                && !["completed", "failed", "cancelled", "unsupported_version"].contains(disposition)
        }
    }

    enum MacWorkFilter: String, CaseIterable, Identifiable, Hashable {
        case all = "All"
        case active = "In progress"
        case paused = "Paused"
        case completed = "Completed"
        case attention = "Needs attention"

        var id: String { rawValue }

        func includes(_ operation: MacWorkOperation) -> Bool {
            switch self {
            case .all: true
            case .active:
                ["queued", "active", "awaiting_approval", "awaiting_authority", "awaiting_event", "retry_eligible"]
                    .contains(operation.disposition)
            case .paused: operation.disposition == "paused"
            case .completed: ["completed", "failed", "cancelled"].contains(operation.disposition)
            case .attention:
                ["budget_blocked", "reconciliation_required", "unsupported_version"].contains(operation.disposition)
            }
        }
    }

    struct MacWorkResultField: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    struct MacWorkResultPresentation: Equatable {
        let operationId: String
        let revision: Int
        let fields: [MacWorkResultField]

        init?(json: JSONValue, operationId expectedId: String, minimumRevision: Int) {
            guard let encoded = try? json.encoded(), encoded.count <= 16_384,
                let response = json.objectValue, response["id"]?.stringValue == expectedId,
                let revisionValue = response["revision"]?.numberValue, revisionValue.rounded() == revisionValue,
                revisionValue >= Double(minimumRevision), revisionValue <= 9_007_199_254_740_991,
                let envelope = response["result"]?.objectValue, envelope["version"]?.numberValue == 1,
                envelope["available"]?.boolValue == true,
                let content = envelope["content"]?.objectValue,
                content["scope"]?.stringValue == "one_page_excerpts",
                let title = content["source"]?["title"]?.stringValue,
                let requestedURL = content["source"]?["requested_url"]?.stringValue,
                let passages = content["passages"]?.arrayValue, passages.count <= 8
            else { return nil }
            var fields = [
                MacWorkResultField(label: "Summary", value: Self.dispositionLabel(content["disposition"]?.stringValue))
            ]
            if !title.isEmpty { fields.append(MacWorkResultField(label: "Source", value: String(title.prefix(512)))) }
            fields.append(MacWorkResultField(label: "URL", value: String(requestedURL.prefix(2048))))
            for (index, passage) in passages.enumerated() {
                guard let id = passage["id"]?.stringValue, let text = passage["text"]?.stringValue,
                    id.utf8.count <= 128, text.utf8.count <= 8192
                else { return nil }
                fields.append(
                    MacWorkResultField(label: "Excerpt \(index + 1) · \(id)", value: String(text.prefix(4000))))
            }
            guard fields.count <= 10, fields.reduce(0, { $0 + $1.value.utf8.count }) <= 12_000 else { return nil }
            operationId = expectedId
            revision = Int(revisionValue)
            self.fields = fields
        }

        private static func dispositionLabel(_ value: String?) -> String {
            switch value {
            case "evidence": "Evidence found"
            case "insufficient_evidence": "No passages selected"
            default: "Result available"
            }
        }
    }

    struct MacWorkControlReceipt: Equatable {
        let operation: MacWorkOperation
        let applied: Bool

        init?(json: JSONValue, expectedId: String, expectedRevision: Int) {
            guard let fields = json.objectValue, Set(fields.keys) == ["operation", "applied"],
                let applied = fields["applied"]?.boolValue,
                let operation = MacWorkOperation(json: fields["operation"] ?? .null),
                operation.id == expectedId, operation.revision >= expectedRevision,
                !applied || operation.revision > expectedRevision
            else { return nil }
            self.operation = operation
            self.applied = applied
        }
    }

    @MainActor @Observable
    final class MacWorkCenterStore {
        private(set) var operations: [MacWorkOperation] = []
        private(set) var selected: MacWorkOperation?
        private(set) var result: MacWorkResultPresentation?
        private(set) var loading = false
        private(set) var acting = false
        private(set) var error: String?
        var filter = MacWorkFilter.all
        var visibleOperations: [MacWorkOperation] { operations.filter(filter.includes) }
        private let model: AppModel
        private var owner: AppModel.DownloadOwner
        private var server: URL
        private var generation = UUID()

        init(model: AppModel) {
            self.model = model
            owner = model.downloadOwner
            server = model.serverBase
        }

        func refresh() async {
            guard captureCurrentScope(), let rest = scopedRest() else { return }
            let requestGeneration = UUID()
            generation = requestGeneration
            loading = true
            error = nil
            defer { if generation == requestGeneration { loading = false } }
            do {
                let (status, json) = try await rest.workOperationsRequest("GET")
                guard accepts(requestGeneration) else { return }
                guard status == 200, let rows = json["operations"]?.arrayValue else {
                    throw MacWorkCenterError.response
                }
                let parsed = rows.compactMap(MacWorkOperation.init(json:))
                guard parsed.count == rows.count else { throw MacWorkCenterError.response }
                operations = parsed
                if let selected, let refreshed = parsed.first(where: { $0.id == selected.id }) {
                    await select(refreshed)
                } else if let selected, !parsed.contains(where: { $0.id == selected.id }) {
                    self.selected = nil
                    result = nil
                }
            } catch {
                if accepts(requestGeneration) { self.error = Self.safeError(error) }
            }
        }

        func select(_ operation: MacWorkOperation) async {
            guard MacWorkOperation.validID(operation.id),
                operations.contains(where: { $0.id == operation.id && $0.revision == operation.revision }),
                captureCurrentScope(), let rest = scopedRest()
            else { return }
            selected = operation
            result = nil
            error = nil
            let requestGeneration = generation
            do {
                async let detailResponse = rest.workOperationsRequest("GET", operation.id)
                async let resultResponse = rest.workOperationsRequest("GET", operation.id + "/result")
                let (detailStatus, detailJSON) = try await detailResponse
                let (resultStatus, resultJSON) = try await resultResponse
                guard accepts(requestGeneration), selected?.id == operation.id else { return }
                guard detailStatus == 200, let fresh = MacWorkOperation(json: detailJSON["operation"] ?? .null),
                    fresh.id == operation.id
                else { throw MacWorkCenterError.response }
                selected = fresh
                if resultStatus == 200,
                    let presentation = MacWorkResultPresentation(
                        json: resultJSON, operationId: operation.id, minimumRevision: fresh.revision)
                {
                    result = presentation
                }
            } catch {
                if accepts(requestGeneration) { self.error = Self.safeError(error) }
            }
        }

        func control(_ action: String, expected: MacWorkOperation? = nil) async {
            guard let current = selected, !acting, captureCurrentScope(),
                expected == nil || expected == current,
                action == "pause" && current.canPause || action == "resume" && current.canResume
                    || action == "cancel" && current.canCancel
            else { return }
            guard let rest = scopedRest() else { return }
            acting = true
            error = nil
            defer { acting = false }
            let capturedGeneration = generation
            let capturedOwner = owner
            let body: JSONValue = .object([
                "expected_revision": .number(Double(current.revision)),
                "submission_id": .string(UUID().uuidString.lowercased()),
            ])
            do {
                let (status, response) = try await rest.workOperationsRequest(
                    "POST", current.id + "/" + action, body: body)
                guard accepts(capturedGeneration), owner == capturedOwner else { return }
                guard status == 200 else {
                    if status == 409 {
                        await refresh()
                        if let latest = operations.first(where: { $0.id == current.id }) { await select(latest) }
                        error = "Work changed before the control was applied. Review the latest status."
                    } else {
                        throw MacWorkCenterError.response
                    }
                    return
                }
                guard status == 200,
                    MacWorkControlReceipt(json: response, expectedId: current.id, expectedRevision: current.revision)
                        != nil
                else { throw MacWorkCenterError.response }
                await refresh()
                if let latest = operations.first(where: { $0.id == current.id }) { await select(latest) }
            } catch {
                if accepts(capturedGeneration) {
                    let message = Self.safeError(error)
                    await refresh()
                    if let latest = operations.first(where: { $0.id == current.id }) { await select(latest) }
                    self.error = message
                }
            }
        }

        func identityChanged() {
            guard owner != model.downloadOwner || server != model.serverBase else { return }
            owner = model.downloadOwner
            server = model.serverBase
            generation = UUID()
            operations = []
            selected = nil
            result = nil
            error = nil
            loading = false
            acting = false
        }

        func signedOut() {
            generation = UUID()
            operations = []
            selected = nil
            result = nil
            error = nil
            loading = false
            acting = false
        }

        private func captureCurrentScope() -> Bool {
            guard owner == model.downloadOwner, server == model.serverBase else {
                identityChanged()
                return false
            }
            guard model.signedIn, owner.signedIn else {
                operations = []
                selected = nil
                result = nil
                return false
            }
            return true
        }

        private func scopedRest() -> RestClient? {
            guard owner == model.downloadOwner, server == model.serverBase,
                model.signedIn, owner.signedIn
            else { return nil }
            return model.scopedRest(owner: owner, server: server)
        }

        private func accepts(_ requestGeneration: UUID) -> Bool {
            requestGeneration == generation && owner == model.downloadOwner && server == model.serverBase
        }

        private static func safeError(_ error: Error) -> String {
            if let error = error as? MacWorkCenterError { return error.localizedDescription }
            if let url = error as? URLError, url.code == .userAuthenticationRequired { return "Sign in to view Work." }
            return "Work could not be refreshed. Try again."
        }
    }

    private enum MacWorkCenterError: LocalizedError {
        case response
        var errorDescription: String? { "The Work service returned an unavailable or invalid response." }
    }

    struct MacWorkCenterView: View {
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss
        @State private var store: MacWorkCenterStore
        @State private var cancelConfirmation: MacWorkOperation?
        @Environment(AppModel.self) private var model

        init(model: AppModel) { _store = State(initialValue: MacWorkCenterStore(model: model)) }

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Work").font(.title2.weight(.semibold))
                        Spacer()
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 32, height: 32)
                        }
                        .disabled(store.loading).help("Refresh Work")
                        .accessibilityIdentifier("mac-work-refresh")
                    }
                    if let error = store.error {
                        Text(error).foregroundStyle(theme.palette.error).accessibilityAddTraits(.isHeader)
                    }
                    HStack {
                        Text("Status")
                        Picker("Status", selection: $store.filter) {
                            ForEach(MacWorkFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                        }
                        .labelsHidden().accessibilityIdentifier("mac-work-status-filter")
                    }
                    if store.visibleOperations.isEmpty && !store.loading {
                        ContentUnavailableView(
                            store.operations.isEmpty ? "No recent work" : "No work matches this filter",
                            systemImage: "tray")
                    } else {
                        List(
                            store.visibleOperations,
                            selection: Binding(
                                get: { store.selected?.id },
                                set: { id in
                                    cancelConfirmation = nil
                                    if let item = store.visibleOperations.first(where: { $0.id == id }) {
                                        Task { await store.select(item) }
                                    }
                                }
                            )
                        ) { operation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(operation.title).font(.headline).lineLimit(2)
                                HStack {
                                    Text(operation.disposition.replacingOccurrences(of: "_", with: " ").capitalized)
                                    if let wake = operation.nextWakeAt { Text("· wakes \(wake)") }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(operation.id)
                            .accessibilityIdentifier("mac-work-operation-\(operation.id)")
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
            .onChange(of: model.connected) { _, connected in if connected { Task { await store.refresh() } } }
            .onChange(of: model.downloadOwner) { _, _ in
                cancelConfirmation = nil
                store.identityChanged()
                Task { await store.refresh() }
            }
            .onChange(of: model.serverBaseText) { _, _ in
                cancelConfirmation = nil
                store.identityChanged()
                Task { await store.refresh() }
            }
            .onChange(of: store.selected) { _, selected in
                if cancelConfirmation != selected { cancelConfirmation = nil }
            }
            .onChange(of: model.signedIn) { _, signedIn in
                if signedIn {
                    Task { await store.refresh() }
                } else {
                    cancelConfirmation = nil
                    store.signedOut()
                }
            }
            .confirmationDialog(
                "Cancel this work?",
                isPresented: Binding(
                    get: { cancelConfirmation != nil },
                    set: { if !$0 { cancelConfirmation = nil } }),
                titleVisibility: .visible,
                presenting: cancelConfirmation
            ) { operation in
                Button("Cancel Work", role: .destructive) {
                    cancelConfirmation = nil
                    Task { await store.control("cancel", expected: operation) }
                }
                .accessibilityIdentifier("mac-work-cancel-confirm")
                Button("Keep Work", role: .cancel) { cancelConfirmation = nil }
                    .accessibilityIdentifier("mac-work-cancel-dismiss")
            } message: { _ in
                Text("The server will stop this operation if it is still active.")
            }
        }

        @ViewBuilder private var detail: some View {
            if let operation = store.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(operation.title).font(.largeTitle.weight(.semibold))
                        Label(
                            operation.disposition.replacingOccurrences(of: "_", with: " ").capitalized,
                            systemImage: "circle.fill")
                        LabeledContent("Phase", value: operation.phase)
                        if let wake = operation.nextWakeAt { LabeledContent("Next wake", value: wake) }
                        if let updated = operation.updatedAt { LabeledContent("Updated", value: updated) }
                        if let code = operation.safeErrorCode { LabeledContent("Issue", value: code) }
                        usage(operation.usage)
                        Button("Review steps and approvals") {
                            dismiss()
                            model.openSurface(
                                "work",
                                params: .object([
                                    "mode": .string("detail"),
                                    "operation_id": .string(operation.id),
                                ]))
                        }
                        .accessibilityIdentifier("mac-work-review-steps")
                        if let result = store.result {
                            Text("Result").font(.headline)
                            ForEach(result.fields) { field in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(field.label).font(.subheadline.weight(.semibold))
                                    Text(field.value).textSelection(.enabled).frame(
                                        maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Button("Review result and next steps") {
                                dismiss()
                                model.openSurface(
                                    "work",
                                    params: .object([
                                        "mode": .string("result"),
                                        "operation_id": .string(operation.id),
                                    ]))
                            }
                            .accessibilityIdentifier("mac-work-review-result")
                        }
                        HStack {
                            if operation.canPause {
                                Button("Pause") { Task { await store.control("pause") } }.accessibilityIdentifier(
                                    "mac-work-pause")
                            }
                            if operation.canResume {
                                Button("Resume") { Task { await store.control("resume") } }.accessibilityIdentifier(
                                    "mac-work-resume")
                            }
                            if operation.canCancel {
                                Button("Cancel", role: .destructive) { cancelConfirmation = operation }
                                    .accessibilityIdentifier("mac-work-cancel")
                            }
                        }.disabled(store.acting)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Select work", systemImage: "list.bullet.rectangle")
            }
        }

        @ViewBuilder private func usage(_ value: JSONValue) -> some View {
            if let buckets = value.objectValue, !buckets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Usage").font(.headline)
                    ForEach(["spent", "daily", "outstanding"], id: \.self) { bucket in
                        if let amounts = buckets[bucket]?.objectValue {
                            let summary = ["model_calls", "tool_calls", "tokens", "elapsed_ms", "spend_micro_units"]
                                .compactMap { key in
                                    amounts[key]?.numberValue.map {
                                        "\(key.replacingOccurrences(of: "_", with: " ")) \(Int($0))"
                                    }
                                }
                                .joined(separator: " · ")
                            if !summary.isEmpty { Text("\(bucket.capitalized): \(summary)").font(.callout) }
                        }
                    }
                }
            }
        }

    }
#endif
