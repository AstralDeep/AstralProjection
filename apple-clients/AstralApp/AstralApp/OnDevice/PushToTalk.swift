// Hold-to-talk input for the on-device voice pipeline: a pure key-state evaluator, a macOS modifier-key monitor and a SwiftUI hold button.
// Hold events drive VoicePipeline.beginPushToTalk and endPushToTalk, and a held key counts as an owner gesture.

import SwiftUI

#if os(macOS)
    import AppKit
#endif

nonisolated enum PushToTalkDecision: Equatable, Sendable {
    case press
    case release
    case none
}

nonisolated struct PushToTalkKeyEvaluator: Equatable, Sendable {
    static let rightOptionKeyCode: UInt16 = 61

    let keyCode: UInt16
    private(set) var held = false

    init(keyCode: UInt16 = PushToTalkKeyEvaluator.rightOptionKeyCode) {
        self.keyCode = keyCode
    }

    mutating func evaluate(keyCode event: UInt16, isPressed: Bool) -> PushToTalkDecision {
        guard event == keyCode else { return .none }
        if isPressed && !held {
            held = true
            return .press
        }
        if !isPressed && held {
            held = false
            return .release
        }
        return .none
    }

    mutating func reset() -> PushToTalkDecision {
        guard held else { return .none }
        held = false
        return .release
    }
}

#if os(macOS)
    @MainActor
    final class MacPushToTalkKeyMonitor {
        private var evaluator: PushToTalkKeyEvaluator
        private var monitor: Any?
        private let onPress: () -> Void
        private let onRelease: () -> Void

        init(
            keyCode: UInt16 = PushToTalkKeyEvaluator.rightOptionKeyCode,
            onPress: @escaping () -> Void, onRelease: @escaping () -> Void
        ) {
            evaluator = PushToTalkKeyEvaluator(keyCode: keyCode)
            self.onPress = onPress
            self.onRelease = onRelease
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handle(keyCode: event.keyCode, isPressed: event.modifierFlags.contains(.option))
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if evaluator.reset() == .release { onRelease() }
        }

        func handle(keyCode: UInt16, isPressed: Bool) {
            switch evaluator.evaluate(keyCode: keyCode, isPressed: isPressed) {
            case .press: onPress()
            case .release: onRelease()
            case .none: break
            }
        }
    }
#endif

struct PushToTalkButton: View {
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: pressed ? "mic.fill" : "mic")
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
            .accessibilityLabel("Hold to talk")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("voice.pushToTalk")
    }
}
