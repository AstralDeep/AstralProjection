// Server-owned private-notes (guidance) surface for the watch, including full-form editing on the wrist;
// presented from WatchHomeView, and its response state survives being briefly covered by a picker or field
// editor.

import AstralCore
import SwiftUI

struct WatchGuidanceSurfaceView: View {
    @Environment(WatchModel.self) var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let update = model.guidanceUpdate {
                    Text(verbatim: update.title).font(ConsoleTypography.headline)
                    ForEach(Array(update.components.enumerated()), id: \.offset) { _, component in
                        WatchComponentView(component: component, guidance: true)
                            .id(update.generation)
                    }
                } else if model.guidanceFailed || !model.connected {
                    Text("This view is unavailable. Reconnect and retry.")
                    Button("Retry") { model.retryGuidance() }.disabled(!model.connected)
                } else {
                    ProgressView("Loading…")
                }
            }.padding(model.consoleContentInsets)
        }
        .task(id: model.guidanceState.generation) {
            guard let generation = model.guidanceState.generation else { return }
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard !Task.isCancelled, model.guidanceUpdate == nil else { return }
            model.failGuidanceRequest(generation: generation)
        }
    }
}

struct WatchGuidanceFormView: View {
    let form: GuidanceForm
    @Environment(WatchModel.self) var model
    @State private var values: [String: JSONValue] = [:]
    private func current(_ name: String) -> JSONValue { values[name] ?? form.defaults[name] ?? .null }
    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { current(name).stringValue ?? "" }, set: { values[name] = .string($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = form.component.title, !title.isEmpty { Text(verbatim: title).font(.headline) }
            if let description = form.component.raw["description"]?.stringValue, !description.isEmpty {
                Text(verbatim: description)
            }
            ForEach(Array(form.fields.enumerated()), id: \.offset) { _, field in
                if form.visible(field, values: values) {
                    let name = field["name"]!.stringValue!
                    let label = field["label"]!.stringValue!
                    VStack(alignment: .leading, spacing: 4) {
                        if field["kind"]?.stringValue == "boolean" {
                            Toggle(
                                label,
                                isOn: Binding(
                                    get: { current(name).boolValue ?? false }, set: { values[name] = .bool($0) })
                            )
                            .accessibilityIdentifier("note-field-\(name)")
                        } else if field["kind"]?.stringValue == "select" {
                            Picker(label, selection: binding(name)) {
                                ForEach(field["options"]!.arrayValue!.compactMap(\.stringValue), id: \.self) { option in
                                    Text(verbatim: option).tag(option)
                                }
                            }.pickerStyle(.navigationLink)
                                .accessibilityIdentifier("note-field-\(name)")
                        } else {
                            TextField(label, text: binding(name))
                                .accessibilityIdentifier("note-field-\(name)")
                                .accessibilityLabel(label)
                            if name == "value", let text = current(name).stringValue, !text.isEmpty {
                                Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let help = field["help"]?.stringValue {
                            Text(verbatim: help).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button(form.component.raw["submit_label"]!.stringValue!) {
                guard let request = form.request(values: values) else { return }
                values.removeAll()
                _ = model.sendGuidanceRequest(action: request.action, payload: request.payload)
            }
            .disabled(!model.connected || model.guidanceUpdate == nil || form.request(values: values) == nil)
            .accessibilityIdentifier("note-submit")
        }
    }
}
