// Holds the server-reported project instruction files for the Mac chat header indicator: the
// loaded paths with hashes, the read-only viewer content, and the per-project ingestion toggle.
// Everything is gated on the composer_references_v1 rote_config acknowledgment; without it the
// indicator reports the feature as unavailable and the composer behaves exactly as before.

#if os(macOS)
    import AstralCore
    import Foundation
    import Observation

    @MainActor @Observable final class MacProjectInstructions {
        enum State: Equatable {
            case idle
            case loading
            case loaded(ProjectInstructionsReport)
            case unavailable(String)
        }
        private(set) var state: State = .idle
        private(set) var working = false
        @ObservationIgnored private var client: RestClient?
        @ObservationIgnored private var acknowledgement: ComposerReferencesAcknowledgement?
        @ObservationIgnored private var project: String?
        @ObservationIgnored private var epoch = UUID()

        var negotiated: Bool { acknowledgement?.instructionsReporting == true }
        var ingestionControlled: Bool { acknowledgement?.ingestionControl == true }

        func acknowledge(_ acknowledgement: ComposerReferencesAcknowledgement?) {
            guard self.acknowledgement != acknowledgement else { return }
            let wasReporting = self.acknowledgement?.instructionsReporting == true
            self.acknowledgement = acknowledgement
            epoch = UUID()
            guard acknowledgement?.instructionsReporting == true else {
                state = .idle
                return
            }
            if !wasReporting { state = project == nil ? .idle : .loading }
        }

        func bind(scope: String?, client: RestClient?) {
            self.client = scope == nil ? nil : client
            epoch = UUID()
            if client == nil { state = .idle }
        }

        func select(project: String?) {
            guard project != self.project else { return }
            self.project = project
            epoch = UUID()
            state = negotiated && project != nil ? .loading : .idle
        }

        func refresh() async {
            guard negotiated, let client, let project else {
                state = .idle
                return
            }
            let operation = UUID()
            epoch = operation
            state = .loading
            do {
                let report = try await client.projectInstructions(id: project)
                guard epoch == operation else { return }
                state = .loaded(report)
            } catch {
                guard epoch == operation else { return }
                state = .unavailable(Self.message(error))
            }
        }

        func setEnabled(_ enabled: Bool) async {
            guard ingestionControlled, let client, let project, case .loaded(let report) = state, !working
            else { return }
            let operation = UUID()
            epoch = operation
            working = true
            defer { working = false }
            do {
                let updated = try await client.setProjectInstructions(
                    id: project, enabled: enabled, revision: report.revision)
                guard epoch == operation else { return }
                state = .loaded(updated)
            } catch {
                guard epoch == operation else { return }
                state = .unavailable(Self.message(error))
            }
        }

        private static func message(_ error: Error) -> String {
            if case ProjectAPIError.refused(_, _, let message) = error { return message }
            return (error as? LocalizedError)?.errorDescription ?? "Project instructions are unavailable."
        }
    }
#endif
