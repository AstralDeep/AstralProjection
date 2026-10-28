// One quiet status line under the Mac workbench composer: connection, model, token use, waiting approvals, this
// Mac's computer-host state and a bypassed-approvals warning, each with a glyph and words. MacWorkbenchView places
// it and supplies the actions.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct MacStatusItem: Identifiable, Equatable {
        enum Kind: String { case connection, model, tokens, approvals, computer, bypass }

        let kind: Kind
        let symbol: String
        let text: String
        let label: String
        let value: String
        let tone: Tone
        var id: String { kind.rawValue }
        var attention: Bool { tone == .warning || tone == .error }

        enum Tone { case neutral, success, info, warning, error }
    }

    enum MacStatusFooterModel {
        enum Connection { case connected, connecting, reconnecting, offline }

        struct Computer: Equatable {
            let enabled: Bool
            let sessionState: String?
            let statusLabel: String
            var bypass = false
        }

        static func connection(connected: Bool, everConnected: Bool, failed: Bool) -> Connection {
            connected ? .connected : everConnected ? .reconnecting : failed ? .offline : .connecting
        }

        static func items(
            connection: Connection, usage: LLMUsageTally, approvals: Int, computer: Computer?
        ) -> [MacStatusItem] {
            var items = [connectionItem(connection)]
            if let model = usage.model {
                items.append(
                    MacStatusItem(
                        kind: .model, symbol: "cpu", text: model, label: "Model", value: model, tone: .neutral))
            }
            if usage.sessionTokens > 0 || usage.contextTokens != nil {
                let session = "\(usage.sessionTokens.formatted()) tokens this session"
                let text: String
                let value: String
                if let context = usage.contextTokens {
                    text = "\(compact(context)) context · \(compact(usage.sessionTokens)) total"
                    value = "Context \(context.formatted()) tokens, \(session)"
                } else {
                    text = "\(compact(usage.sessionTokens)) tokens"
                    value = session
                }
                items.append(
                    MacStatusItem(
                        kind: .tokens, symbol: "gauge.with.dots.needle.33percent", text: text, label: "Tokens",
                        value: value, tone: .neutral))
            }
            if approvals > 0 {
                let text = approvals == 1 ? "1 approval waiting" : "\(approvals) approvals waiting"
                items.append(
                    MacStatusItem(
                        kind: .approvals, symbol: "hand.raised.fill", text: text, label: "Approvals", value: text,
                        tone: .warning))
            }
            if let computer { items.append(computerItem(computer)) }
            if computer?.bypass == true {
                items.append(
                    MacStatusItem(
                        kind: .bypass, symbol: "exclamationmark.shield.fill", text: "Approvals bypassed",
                        label: "Approval bypass", value: "Approvals bypassed on this Mac", tone: .warning))
            }
            return items
        }

        static func compact(_ tokens: Int) -> String {
            switch tokens {
            case ..<1_000: return "\(tokens)"
            case ..<10_000: return trimmed(Double(tokens) / 1_000) + "k"
            case ..<1_000_000: return "\(tokens / 1_000)k"
            default: return trimmed(Double(tokens) / 1_000_000) + "M"
            }
        }

        private static func trimmed(_ value: Double) -> String {
            let text = String(format: "%.1f", (value * 10).rounded(.down) / 10)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }

        private static func connectionItem(_ connection: Connection) -> MacStatusItem {
            let (symbol, text, tone): (String, String, MacStatusItem.Tone) =
                switch connection {
                case .connected: ("circle.fill", "Connected", .success)
                case .connecting: ("circle.dotted", "Connecting…", .neutral)
                case .reconnecting: ("arrow.triangle.2.circlepath", "Reconnecting…", .warning)
                case .offline: ("exclamationmark.triangle.fill", "Offline", .error)
                }
            return MacStatusItem(
                kind: .connection, symbol: symbol, text: text, label: "Connection", value: text, tone: tone)
        }

        private static func computerItem(_ computer: Computer) -> MacStatusItem {
            let (symbol, text, tone): (String, String, MacStatusItem.Tone) =
                switch (computer.sessionState, computer.enabled) {
                case ("paused", _): ("pause.circle.fill", "Computer paused", .warning)
                case (.some, _): ("record.circle", "Computer active", .info)
                case (nil, true): ("desktopcomputer", "Computer on", .neutral)
                case (nil, false): ("desktopcomputer.trianglebadge.exclamationmark", "Computer off", .neutral)
                }
            return MacStatusItem(
                kind: .computer, symbol: symbol, text: text, label: "This Mac", value: computer.statusLabel, tone: tone)
        }
    }

    struct MacStatusFooter: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let showActivity: () -> Void

        private var items: [MacStatusItem] {
            let host = model.macComputerHost
            return MacStatusFooterModel.items(
                connection: MacStatusFooterModel.connection(
                    connected: model.connected, everConnected: model.everConnected,
                    failed: model.initialConnectionFailed),
                usage: model.llmUsage,
                approvals: model.waitingApprovals,
                computer: host.available
                    ? MacStatusFooterModel.Computer(
                        enabled: host.enabled, sessionState: host.session?.state, statusLabel: host.statusLabel,
                        bypass: host.bypass)
                    : nil)
        }

        var body: some View {
            HStack(spacing: 16) {
                ForEach(items) { item in
                    switch item.kind {
                    case .approvals: button(item, action: showActivity)
                    case .computer, .bypass: button(item) { model.macComputerHost.showControls() }
                    default: label(item, identifier: "workbench-status-\(item.id)")
                    }
                }
                Spacer(minLength: 0)
            }
            .font(ConsoleTypography.caption).lineLimit(1)
            .padding(.horizontal, 16).frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading).clipped()
            .background(theme.palette.bg)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Status")
            .accessibilityIdentifier("workbench-status-footer")
        }

        private func label(_ item: MacStatusItem, identifier: String? = nil) -> some View {
            HStack(spacing: 5) {
                Image(systemName: item.symbol).imageScale(.small).accessibilityHidden(true)
                    .foregroundStyle(color(item.tone))
                Text(item.text).truncationMode(.middle)
                    .foregroundStyle(item.attention ? theme.palette.text : theme.palette.muted)
                    .accessibilityLabel(item.label).accessibilityValue(item.value)
                    .accessibilityIdentifier(identifier ?? "")
            }
            .help(item.value)
        }

        private func color(_ tone: MacStatusItem.Tone) -> Color {
            switch tone {
            case .neutral: theme.palette.muted
            case .success: theme.palette.success
            case .info: theme.palette.info
            case .warning: theme.palette.warning
            case .error: theme.palette.error
            }
        }

        private func button(_ item: MacStatusItem, action: @escaping () -> Void) -> some View {
            Button(action: action) { label(item).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label).accessibilityValue(item.value)
                .accessibilityIdentifier("workbench-status-\(item.id)")
        }
    }
#endif
