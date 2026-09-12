#if DEBUG
    import AstralCore
    import Foundation

    /// Deterministic UI-test transport for the first-login provider surface.
    ///
    /// The fixture is compiled out of release builds. It feeds the production
    /// reducer canonical server frames and deliberately never reads or records the
    /// submitted `fields`, so a UI test credential cannot enter diagnostics.
    enum FirstLoginUITestFixture {
        enum Scenario: String {
            case slowSuccess = "slow-success"
            case invalidCredentials = "invalid-credentials"
            case providerUnavailable = "provider-unavailable"
            case clientWatchdog = "client-watchdog"
            case chatComposer = "chat-composer"
            case workspaceStart = "workspace-start"
            case workspaceCanvas = "workspace-canvas"
            case workspaceStyles = "workspace-styles"
            case voiceComposer = "voice-composer"
            case voiceTerminal = "voice-terminal"
            case continuitySeed = "continuity-seed"
            case continuityResume = "continuity-resume"
        }

        private static let launchFlag = "--astral-ui-test-first-login"
        private static let connectionGeneration = "11111111-1111-4111-8111-111111111111"
        private static let operationId = "22222222-2222-4222-8222-222222222222"

        static func requestedScenario(
            arguments: [String] = ProcessInfo.processInfo.arguments
        ) -> Scenario? {
            guard let flagIndex = arguments.firstIndex(of: launchFlag),
                arguments.indices.contains(flagIndex + 1)
            else { return nil }
            return Scenario(rawValue: arguments[flagIndex + 1])
        }

        @MainActor
        static func install(_ scenario: Scenario, on model: AppModel) {
            model.signedIn = true
            model.accountName = "Release Verification"
            model.connected = true
            model.everConnected = true

            switch scenario {
            case .continuitySeed, .continuityResume:
                installContinuity(scenario, on: model)
                return
            case .voiceComposer, .voiceTerminal:
                installVoiceComposer(on: model)
                if scenario == .voiceTerminal { installVoiceTerminalNotice(on: model) }
                return
            default:
                break
            }

            if scenario == .workspaceStart {
                installWorkspace(on: model)
                return
            }
            if scenario == .workspaceCanvas {
                installWorkspaceCanvas(on: model)
                return
            }
            if scenario == .workspaceStyles {
                installWorkspaceStyles(on: model)
                return
            }
            _ = model.beginConversationConnection(connectionGeneration)

            if scenario == .chatComposer {
                model.screen = .chat
                model.turns = (1...16).map { index in
                    AppModel.ChatTurn(
                        id: "ui-keyboard-\(index)",
                        role: index.isMultiple(of: 2) ? "assistant" : "user",
                        text: "Runtime keyboard message \(index)")
                }
                return
            }

            model.screen = .surface
            model.handleFrame(firstLoginSurface)
            model.llmOperationReconciler = { _, _ in .unavailable }

            model.outboundTap = { [weak model] text in
                guard scenario != .clientWatchdog,
                    let event = try? JSONValue.parse(Data(text.utf8)),
                    event["action"]?.stringValue == "chrome_llm_save",
                    let payload = event["payload"],
                    let submissionId = payload["submission_id"]?.stringValue,
                    let requestGeneration = payload["request_generation"]?.stringValue
                else { return }

                // Intentionally do not inspect payload["fields"].
                Task { @MainActor [weak model] in
                    guard let model else { return }
                    await respond(
                        to: scenario,
                        submissionId: submissionId,
                        requestGeneration: requestGeneration,
                        model: model)
                }
            }
        }

        @MainActor
        private static func respond(
            to scenario: Scenario,
            submissionId: String,
            requestGeneration: String,
            model: AppModel
        ) async {
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard model.llmFirstLoginOperation?.submissionId == submissionId else { return }
            model.handleFrame(
                status(
                    requestGeneration: requestGeneration,
                    sequence: 0,
                    state: "accepted",
                    phase: "accepted",
                    label: "Accepted"))

            switch scenario {
            case .slowSuccess:
                // Keep the validating phase visible long enough for deterministic
                // one-second UI assertions, while leaving enough headroom for
                // scene-background/foreground automation inside the five-second bound.
                try? await Task.sleep(nanoseconds: 800_000_000)
                model.handleFrame(
                    status(
                        requestGeneration: requestGeneration,
                        sequence: 1,
                        state: "validating",
                        phase: "validating_credentials",
                        label: "Checking your provider credentials…"))
                try? await Task.sleep(nanoseconds: 800_000_000)
                model.handleFrame(
                    status(
                        requestGeneration: requestGeneration,
                        sequence: 2,
                        state: "persisting",
                        phase: "saving_credentials",
                        label: "Saving credentials…"))
                try? await Task.sleep(nanoseconds: 100_000_000)
                model.handleFrame(
                    status(
                        requestGeneration: requestGeneration,
                        sequence: 3,
                        state: "completed",
                        phase: "completed",
                        label: "Provider setup complete"))
            case .invalidCredentials:
                // Keep a retry active long enough for UI automation to observe
                // the duplicate-control disabled state through accessibility.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                model.handleFrame(
                    status(
                        requestGeneration: requestGeneration,
                        sequence: 1,
                        state: "failed",
                        phase: "validation_failed",
                        label: "Check your provider credentials",
                        errorCode: "validation_failed",
                        errorMessage: "The provider rejected these credentials."))
            case .providerUnavailable:
                try? await Task.sleep(nanoseconds: 180_000_000)
                model.handleFrame(
                    status(
                        requestGeneration: requestGeneration,
                        sequence: 1,
                        state: "retryable",
                        phase: "provider_unavailable",
                        label: "Provider unavailable. Try again.",
                        errorCode: "provider_unavailable",
                        errorMessage: "The provider is temporarily unavailable."))
            case .clientWatchdog:
                break
            case .chatComposer, .workspaceStart, .workspaceCanvas, .workspaceStyles:
                break
            case .voiceComposer:
                break
            case .voiceTerminal:
                break
            case .continuitySeed, .continuityResume:
                break
            }
        }

        @MainActor
        private static func installWorkspace(on model: AppModel) {
            let welcome = InboundFrame.parse(
                #"{"type":"ui_render","target":"canvas","components":[{"type":"hero","title":"How can I help?","variant":"subtle","badges":[],"data-welcome":"intro","id":"wel_hero","component_id":"wel_hero"},{"type":"card","title":"🔌 Agents are off for this account","content":[{"type":"text","content":"Replies will be plain text until agents are enabled. Enabling grants read-only permissions for the built-in public agents — search, data, file and system reads, never write access — and each agent can be adjusted or turned off any time.","variant":"caption"},{"type":"button","label":"Enable recommended agents","action":"enable_recommended_agents","payload":{"source":"welcome"},"variant":"primary"},{"type":"button","label":"Choose agents individually","action":"chrome_open","payload":{"surface":"agents"},"variant":"secondary"}],"variant":"default","data-welcome":"permission","id":"wel_enable","component_id":"wel_enable"},{"type":"grid","columns":3,"children":[{"type":"button","label":"Research brief","action":"chat_message","payload":{"message":"Research the latest developments in small modular reactors and give me a cited brief"},"variant":"secondary","aria-label":"Research brief","data-welcome":"example","id":"wel_ex_research_brief","component_id":"wel_ex_research_brief"},{"type":"button","label":"Summarize a page","action":"chat_message","payload":{"message":"Summarize https://en.wikipedia.org/wiki/Dog_grooming — give me a TL;DR and key points"},"variant":"secondary","aria-label":"Summarize a page","data-welcome":"example","id":"wel_ex_summarize_a_page","component_id":"wel_ex_summarize_a_page"},{"type":"button","label":"Weather outlook","action":"chat_message","payload":{"message":"What's the weather forecast for Lexington, KY this week? Show it with charts"},"variant":"secondary","aria-label":"Weather outlook","data-welcome":"example","id":"wel_ex_weather_outlook","component_id":"wel_ex_weather_outlook"}],"gap":12,"data-welcome":"examples","id":"wel_examples","component_id":"wel_examples"},{"type":"collapsible","title":"More examples","content":[{"type":"button","label":"Business dashboard","action":"chat_message","payload":{"message":"Build a rich dashboard for a dog grooming business — booking requests, monthly revenue line chart, most popular services pie chart, and today's schedule as a table"},"variant":"secondary","aria-label":"Business dashboard","data-welcome":"example","id":"wel_ex_business_dashboard","component_id":"wel_ex_business_dashboard"},{"type":"button","label":"Roll some dice","action":"chat_message","payload":{"message":"Roll exactly six six-sided dice and show the normalized results."},"variant":"secondary","aria-label":"Roll some dice","data-welcome":"example","id":"wel_ex_roll_some_dice","component_id":"wel_ex_roll_some_dice"},{"type":"button","label":"System status","action":"chat_message","payload":{"message":"Show current system status with CPU and memory metrics"},"variant":"secondary","aria-label":"System status","data-welcome":"example","id":"wel_ex_system_status","component_id":"wel_ex_system_status"}],"default_open":false,"data-welcome":"more","id":"wel_more","component_id":"wel_more"}]}"#
            )!
            model.screen = .chat
            model.composerDraft = "First line\n"
            model.handleFrame(welcome)
            model.outboundTap = { [weak model] text in
                guard let model, let event = try? JSONValue.parse(Data(text.utf8)) else { return }
                if event["action"]?.stringValue == "new_chat" {
                    model.handleFrame(welcome)
                } else if event["action"]?.stringValue == "chat_message" {
                    model.pendingReplace = false
                    model.turnActive = false
                    model.canvas = [
                        AstralComponent(
                            type: "text",
                            raw: .object([
                                "content": .string("Workspace result"), "component_id": .string("result_088"),
                            ]))
                    ]
                }
            }
        }

        @MainActor
        private static func installWorkspaceStyles(on model: AppModel) {
            installWorkspace(on: model)
            model.composerDraft = ""
            model.turns = [AppModel.ChatTurn(id: "style-result", role: "assistant", text: "Synthetic style result")]
            model.canvas =
                InboundFrame.parse(
                    #"{"type":"ui_render","target":"canvas","components":[{"type":"card","component_id":"style-card","title":"Roll Summary","content":[{"type":"metric","title":"Total","value":18,"subtitle":"Six dice","progress":0.5},{"type":"metric","title":"Completed","value":"6 / 6","variant":"success","progress":1}]}]}"#
                )!.renderComponents
        }

        @MainActor
        private static func installWorkspaceCanvas(on model: AppModel) {
            model.screen = .chat
            model.turns = (1...7).map { index in
                AppModel.ChatTurn(
                    id: "workspace-layout-\(index)",
                    role: index.isMultiple(of: 2) ? "assistant" : "user",
                    text: "Canvas layout check \(index). Six dice produced 6, 1, 2, 1, 3, 5 for a total of 18.")
            }
            let result = InboundFrame.parse(
                #"{"type":"ui_render","target":"canvas","components":[{"type":"hero","component_id":"layout_hero","title":"Dice layout regression","subtitle":"Six results and a total"},{"type":"grid","component_id":"layout_grid","columns":2,"children":[{"type":"card","title":"Roll Summary","content":[{"type":"metric","title":"Total","value":18},{"type":"text","content":"Six dice produced 6, 1, 2, 1, 3, 5."}]},{"type":"card","title":"Results Table","content":[{"type":"table","headers":["Die","Result"],"rows":[["Die 1",6],["Die 2",1],["Die 3",2],["Die 4",1],["Die 5",3],["Die 6",5],["Total",18]]}]}]},{"type":"text","component_id":"layout_end","content":"Canvas layout end"}]}"#
            )!
            model.canvas = result.renderComponents
        }

        /// Drives the production strict voice reducer so UI automation can
        /// inspect the server-owned composer affordance without microphone,
        /// network, credential, or synthetic audio access.
        @MainActor
        private static func installVoiceComposer(on model: AppModel) {
            model.screen = .chat
            let registration = model.registrationFrame(token: "ui-test-token", resumed: false)
            guard let payload = try? JSONValue.parse(Data(registration.utf8)),
                let connection = payload["connection_generation"]?.stringValue
            else { return }
            let composer =
                """
                {"type":"composer_state","schema_version":"1","revision":7,
                 "connection_generation":"\(connection)","voice":{
                   "available":true,"state":"off","speech_muted":false,
                   "microphone_enabled":false,"foreground_active":false,"reason":"ready",
                   "output_locale":"en-US","chat_context_revision":null,
                   "applied_chat_context_revision":null,"chat_context_synced":false,
                   "session_id":null,"generation":null,"media_grant_revision":null,
                   "visible_chat_id":null,"foreground_turn_id":null,"owner_device":null,
                   "idle_expires_at":null,"controls":[
                     {"key":"voice-start","action":"voice_session_start",
                      "label":"Start voice conversation","icon":"microphone",
                      "visible":true,"enabled":true,"pressed":false,"busy":false}
                   ]}}
                """
            if let frame = InboundFrame.parse(composer) { model.handleFrame(frame) }
        }

        /// Feeds a canonical terminal turn through the shared production
        /// notice reducer. Session correlation is covered by controller tests;
        /// this DEBUG-only seam exists solely for visual/accessibility UI QA.
        @MainActor
        private static func installVoiceTerminalNotice(on model: AppModel) {
            let terminalTurn =
                """
                {"type":"voice_turn_state","schema_version":"1",
                 "session_id":"00000000-0000-4000-8000-000000000003",
                 "connection_generation":"00000000-0000-4000-8000-000000000002",
                 "generation":1,"media_grant_revision":2,
                 "turn_id":"00000000-0000-4000-8000-000000000005",
                 "client_turn_id":"00000000-0000-4000-8000-000000000006",
                 "submission_id":"00000000-0000-4000-8000-000000000007",
                 "request_generation":"00000000-0000-4000-8000-000000000008",
                 "chat_id":"00000000-0000-4000-8000-000000000004",
                 "chat_context_revision":3,"detected_language":"en-US",
                 "spoken_output_policy":"full_recap","output_reason":"ready",
                 "state":"failed","foreground":true,"sensitive_result_pending":false,
                 "sequence":1,"message":"The provider could not complete this request.",
                 "occurred_at":"2099-07-31T12:00:00Z"}
                """
            guard let frame = InboundFrame.parse(terminalTurn),
                let turn = VoiceTurnState(frame: frame)
            else { return }
            model.voice.installTerminalNoticeForUITesting(turn)
        }

        /// Recreates an authenticated native process around the production
        /// account-scoped locator and snapshot reducer. Frames remain a DEBUG
        /// fixture, so this proves process persistence and semantic rendering,
        /// not backend transport availability.
        @MainActor
        private static func installContinuity(_ scenario: Scenario, on model: AppModel) {
            guard
                let account = ConversationAccount(
                    issuer: "https://id.example.test/realms/astral",
                    subject: "ui-continuity-user")
            else { return }

            let chatId = "66666666-6666-4666-8666-666666666666"
            let connection = "77777777-7777-4777-8777-777777777777"
            let request = "88888888-8888-4888-8888-888888888888"

            model.screen = .chat
            model.bindConversationAccount(account)
            if scenario == .continuitySeed {
                model.newChat()
            } else if model.activeChatId != chatId {
                model.errorBanner = "Deterministic continuity locator was not restored."
                return
            }

            guard model.beginConversationConnection(connection),
                model.openConversationRequest(
                    chatId: chatId,
                    requestGeneration: request,
                    purpose: .hydration),
                let snapshot = InboundFrame.parse(
                    """
                    {"type":"conversation_snapshot","schema_version":1,
                     "snapshot_id":"99999999-9999-4999-8999-999999999999",
                     "chat_id":"\(chatId)",
                     "connection_generation":"\(connection)",
                     "request_generation":"\(request)",
                     "snapshot_purpose":"hydration","render_revision":7,
                     "committed_at":"2026-07-16T16:00:00Z",
                     "transcript":[
                       {"message_id":"continuity-user","role":"user",
                        "created_at":"2026-07-16T15:59:00Z",
                        "parts":[{"type":"text","text":"Continuity question"}],
                        "attachments":[{"filename":"continuity.pdf"}]},
                       {"message_id":"continuity-assistant","role":"assistant",
                        "created_at":"2026-07-16T15:59:30Z",
                        "parts":[
                          {"type":"structured","value":{"total":21},
                           "plain_text":"Continuity total: 21"},
                          {"type":"components","components":[
                            {"type":"text","content":"Continuity component answer"}
                          ]}
                        ],"attachments":[]}
                     ],
                     "canvas":{"target":"canvas","components":[
                       {"type":"text","content":"Restored continuity canvas"}
                     ]}}
                    """)
            else {
                model.errorBanner = "Deterministic continuity snapshot could not be installed."
                return
            }
            model.handleFrame(snapshot)
        }

        private static func status(
            requestGeneration: String,
            sequence: UInt64,
            state: String,
            phase: String,
            label: String,
            errorCode: String? = nil,
            errorMessage: String? = nil
        ) -> InboundFrame {
            let terminalStates = Set(["completed", "failed", "cancelled", "retryable"])
            let terminal = terminalStates.contains(state)
            let error: JSONValue
            if let errorCode, let errorMessage {
                error = .object([
                    "code": .string(errorCode),
                    "message": .string(errorMessage),
                ])
            } else {
                error = .null
            }
            return InboundFrame(
                name: "operation_status",
                payload: .object([
                    "type": .string("operation_status"),
                    "operation_id": .string(operationId),
                    "action": .string("chrome_llm_save"),
                    "surface": .string("llm_settings"),
                    "chat_id": .null,
                    "connection_generation": .string(connectionGeneration),
                    "request_generation": .string(requestGeneration),
                    "sequence": .number(Double(sequence)),
                    "state": .string(state),
                    "phase": .string(phase),
                    "label": .string(label),
                    "terminal": .bool(terminal),
                    "retryable": .bool(state == "retryable"),
                    "error": error,
                    "retry_after_ms": state == "retryable" ? .number(250) : .null,
                    "updated_at": .string("2026-07-15T18:41:00Z"),
                ]))
        }

        private static var firstLoginSurface: InboundFrame {
            InboundFrame(
                name: "chrome_surface",
                payload: .object([
                    "type": .string("chrome_surface"),
                    "mode": .string("mandatory"),
                    "surface_key": .string("llm"),
                    "title": .string("Connect your AI provider"),
                    "components": .array([
                        .object([
                            "type": .string("param_picker"),
                            "title": .string("Provider settings"),
                            "description": .string(
                                "Choose a provider, enter its credential, and save to continue."),
                            "fields": .array([
                                .object([
                                    "name": .string("provider"),
                                    "label": .string("Provider"),
                                    "kind": .string("select"),
                                    "default": .string("openai"),
                                    "options": .array([.string("openai"), .string("custom")]),
                                ]),
                                .object([
                                    "name": .string("base_url"),
                                    "label": .string("Endpoint (Base URL)"),
                                    "kind": .string("text"),
                                    "default": .string("https://api.openai.com/v1"),
                                ]),
                                .object([
                                    "name": .string("api_key"),
                                    "label": .string("API key"),
                                    "kind": .string("password"),
                                    "help": .string("Stored encrypted for your account."),
                                ]),
                                .object([
                                    "name": .string("model"),
                                    "label": .string("Model"),
                                    "kind": .string("text"),
                                    "default": .string("gpt-4o-mini"),
                                ]),
                            ]),
                            "actions": .array([
                                .object([
                                    "label": .string("Load models"),
                                    "action": .string("chrome_llm_models"),
                                ]),
                                .object([
                                    "label": .string("Test connection"),
                                    "action": .string("chrome_llm_test"),
                                ]),
                                .object([
                                    "label": .string("Save"),
                                    "action": .string("chrome_llm_save"),
                                    "variant": .string("primary"),
                                ]),
                            ]),
                        ])
                    ]),
                ]))
        }
    }
#endif
