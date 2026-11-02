// Shows the agent's pointer, click, drag, scroll and key cues on click-through screen panels plus one control banner.
// MacComputerHost presents the banner state and MacComputerDriver sends cues; captures exclude every overlay window.

#if os(macOS)
    import AppKit
    import AstralCore
    import QuartzCore
    import SwiftUI

    nonisolated enum MacComputerOverlayIdentity {
        static let title = "AstralDeep agent overlay"
    }

    nonisolated enum MacComputerOverlayMode: String, Equatable, Sendable {
        case driving, paused, approval
    }

    nonisolated enum MacComputerOverlayCue: Equatable, Sendable {
        case app(String)
        case point(CGPoint, label: String?)
        case click(CGPoint)
        case drag(CGPoint, CGPoint)
        case scroll(CGPoint, dx: Int, dy: Int)
        case chord(String)

        static func chordLabel(_ chord: ComputerHostChord) -> String {
            let modifiers = [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
            let keys = [
                "enter": "↩", "escape": "⎋", "tab": "⇥", "space": "Space", "backspace": "⌫", "delete": "⌦",
                "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "↖", "end": "↘", "pageup": "⇞",
                "pagedown": "⇟",
            ]
            return modifiers.filter { chord.modifiers.contains($0.0) }.map(\.1).joined()
                + (keys[chord.key] ?? chord.key.uppercased())
        }
    }

    @MainActor
    protocol MacComputerOverlayPresenting: AnyObject, Sendable {
        func attach(_ host: MacComputerHost)
        func show(_ mode: MacComputerOverlayMode) -> Bool
        func hide()
        func cue(_ cue: MacComputerOverlayCue)
    }

    @MainActor
    final class MacComputerHostLink: Sendable {
        weak var host: MacComputerHost?
        func bypass() -> Bool { host?.bypass == true }
    }

    @MainActor @Observable
    final class MacComputerOverlayModel {
        var mode: MacComputerOverlayMode = .driving
        var app: String?
    }

    final class MacComputerOverlayGlyphPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    final class MacComputerOverlayBannerPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    final class MacComputerOverlayHostingView: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    @MainActor
    final class MacComputerOverlay: NSObject, MacComputerOverlayPresenting {
        static let bannerSize = NSSize(width: 500, height: 44)
        static let glideSeconds: CFTimeInterval = 0.15
        static let labelSeconds: CFTimeInterval = 1.2
        let model = MacComputerOverlayModel()
        private(set) var glyphPanels: [NSPanel] = []
        private(set) var banner: NSPanel?
        private(set) var mode: MacComputerOverlayMode?
        private weak var host: MacComputerHost?
        private let present: @MainActor (NSPanel) -> Void
        private let screens: @MainActor () -> [NSScreen]

        init(
            present: @escaping @MainActor (NSPanel) -> Void = { $0.orderFrontRegardless() },
            screens: @escaping @MainActor () -> [NSScreen] = { NSScreen.screens }
        ) {
            self.present = present
            self.screens = screens
            super.init()
            NotificationCenter.default.addObserver(
                self, selector: #selector(screensChanged(_:)),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }

        var windowIDs: Set<CGWindowID> {
            Set(glyphPanels.map(\.windowNumber).filter { $0 > 0 }.map { CGWindowID($0) })
        }

        static func tint(_ mode: MacComputerOverlayMode) -> Color {
            switch mode {
            case .driving: return AstralPalette.graphite.primary
            case .paused: return AstralPalette.graphite.secondary
            case .approval: return AstralPalette.graphite.warning
            }
        }

        func attach(_ host: MacComputerHost) { self.host = host }

        func show(_ mode: MacComputerOverlayMode) -> Bool {
            guard let host else { return false }
            if glyphPanels.isEmpty { glyphPanels = screens().map(makeGlyphPanel) }
            guard !glyphPanels.isEmpty else { return false }
            if banner == nil { banner = makeBanner(host) }
            guard let banner else { return false }
            let first = self.mode == nil
            self.mode = mode
            model.mode = mode
            let color = NSColor(Self.tint(mode))
            for panel in glyphPanels {
                (panel.contentView as? MacComputerOverlayCanvas)?.tint = color
                present(panel)
            }
            if first { place(banner, top: true) }
            present(banner)
            return true
        }

        func hide() {
            mode = nil
            model.app = nil
            for panel in glyphPanels {
                (panel.contentView as? MacComputerOverlayCanvas)?.clear()
                panel.orderOut(nil)
            }
            banner?.orderOut(nil)
        }

        func cue(_ cue: MacComputerOverlayCue) {
            guard mode != nil else { return }
            switch cue {
            case .app(let name):
                model.app = MacComputerAccessibility.bounded(MacComputerAccessibility.clean(name), 60)
            case .point(let point, let label):
                avoid(appKit(point))
                guard case let (canvas, local)? = locate(point) else { return }
                for panel in glyphPanels where panel.contentView !== canvas {
                    (panel.contentView as? MacComputerOverlayCanvas)?.hidePointer()
                }
                canvas.glide(to: local, label: label.map { MacComputerAccessibility.bounded($0, 80) })
            case .click(let point):
                guard case let (canvas, local)? = locate(point) else { return }
                canvas.ripple(at: local)
            case .drag(let start, let end):
                if case let (canvas, from)? = locate(start), case let (other, to)? = locate(end), canvas === other {
                    canvas.path(from: from, to: to)
                } else {
                    if case let (canvas, local)? = locate(start) { canvas.ripple(at: local) }
                    if case let (canvas, local)? = locate(end) { canvas.ripple(at: local) }
                }
            case .scroll(let point, let dx, let dy):
                guard case let (canvas, local)? = locate(point) else { return }
                canvas.scroll(at: local, dx: dx, dy: dy)
            case .chord(let text):
                let screen = banner?.screen ?? screens().first
                let panel = glyphPanels.first { $0.frame == screen?.frame } ?? glyphPanels.first
                (panel?.contentView as? MacComputerOverlayCanvas)?.toast(MacComputerAccessibility.bounded(text, 40))
            }
        }

        private func appKit(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: (screens().first?.frame.height ?? 0) - point.y)
        }

        private func locate(_ point: CGPoint) -> (MacComputerOverlayCanvas, CGPoint)? {
            let target = appKit(point)
            for panel in glyphPanels where panel.frame.contains(target) {
                guard let canvas = panel.contentView as? MacComputerOverlayCanvas else { continue }
                return (canvas, CGPoint(x: target.x - panel.frame.minX, y: target.y - panel.frame.minY))
            }
            return nil
        }

        private func avoid(_ point: CGPoint) {
            guard mode != nil, let banner, banner.frame.insetBy(dx: -24, dy: -24).contains(point) else { return }
            place(banner, top: banner.frame.midY < (banner.screen ?? screens().first)?.frame.midY ?? 0)
        }

        private func place(_ banner: NSPanel, top: Bool) {
            guard let screen = screens().first else { return }
            let visible = screen.visibleFrame
            let size = Self.bannerSize
            let y = top ? visible.maxY - size.height - 8 : visible.minY + 8
            banner.setFrame(
                NSRect(x: visible.midX - size.width / 2, y: y, width: size.width, height: size.height), display: false)
        }

        private func makeGlyphPanel(_ screen: NSScreen) -> NSPanel {
            let panel = MacComputerOverlayGlyphPanel(
                contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.title = MacComputerOverlayIdentity.title
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.hasShadow = false
            panel.backgroundColor = .clear
            panel.isExcludedFromWindowsMenu = true
            panel.animationBehavior = .none
            let canvas = MacComputerOverlayCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
            canvas.scale = screen.backingScaleFactor
            panel.contentView = canvas
            return panel
        }

        private func makeBanner(_ host: MacComputerHost) -> NSPanel {
            let panel = MacComputerOverlayBannerPanel(
                contentRect: NSRect(origin: .zero, size: Self.bannerSize),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = MacComputerPanelIdentity.title
            panel.becomesKeyOnlyIfNeeded = true
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.hasShadow = true
            panel.backgroundColor = .clear
            panel.isMovableByWindowBackground = true
            panel.isExcludedFromWindowsMenu = true
            panel.animationBehavior = .none
            panel.contentView = MacComputerOverlayHostingView(
                rootView: AnyView(MacComputerOverlayBanner(host: host, model: model)))
            return panel
        }

        @objc private func screensChanged(_ notification: Notification) {
            for panel in glyphPanels { panel.orderOut(nil) }
            glyphPanels = []
            guard let mode else { return }
            self.mode = nil
            _ = show(mode)
        }
    }

    struct MacComputerOverlayBanner: View {
        @Bindable var host: MacComputerHost
        let model: MacComputerOverlayModel
        private var palette: AstralPalette { .graphite }
        private var headline: String {
            switch model.mode {
            case .driving: return "AstralDeep is controlling \(model.app ?? "this Mac")"
            case .paused: return "Computer task paused"
            case .approval: return "Approval waiting"
            }
        }
        var body: some View {
            let tint = MacComputerOverlay.tint(model.mode)
            HStack(spacing: 10) {
                Circle().fill(tint).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(headline).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("mac-computer-overlay-status")
                if host.bypass {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(palette.warning)
                        .accessibilityLabel("Bypass on").accessibilityIdentifier("mac-computer-bypass-on")
                }
                Spacer(minLength: 8)
                if model.mode == .approval {
                    Button("Open Astral", action: host.bringAstralForward)
                        .accessibilityIdentifier("mac-computer-open-astral")
                }
                if host.session?.state == "paused" {
                    Button("Resume", action: host.resume).disabled(!host.canResume)
                        .accessibilityIdentifier("mac-computer-resume")
                } else {
                    Button("Pause", action: host.pause).accessibilityIdentifier("mac-computer-pause")
                }
                Button("Stop", role: .destructive, action: host.stop).accessibilityIdentifier("mac-computer-stop")
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(width: MacComputerOverlay.bannerSize.width, height: MacComputerOverlay.bannerSize.height)
            .foregroundStyle(palette.text)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint, lineWidth: 1.5))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mac-computer-overlay-banner")
        }
    }

    final class MacComputerOverlayCanvas: NSView {
        var tint = NSColor(AstralPalette.graphite.primary) {
            didSet { pointer.fillColor = tint.cgColor }
        }
        var scale: CGFloat = 2
        private let pointer = CAShapeLayer()
        private var pointerShown = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = .clear
            let path = CGMutablePath()
            path.addLines(between: [
                CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -19), CGPoint(x: 5, y: -14.5), CGPoint(x: 8.5, y: -22),
                CGPoint(x: 11.5, y: -20.5), CGPoint(x: 8, y: -13.5), CGPoint(x: 14, y: -13.5),
            ])
            path.closeSubpath()
            pointer.path = path
            pointer.fillColor = tint.cgColor
            pointer.strokeColor = NSColor.white.cgColor
            pointer.lineWidth = 1.5
            pointer.shadowOpacity = 0.35
            pointer.shadowRadius = 2
            pointer.shadowOffset = CGSize(width: 0, height: -1)
            pointer.isHidden = true
            pointer.name = "pointer"
            layer?.addSublayer(pointer)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        var cueNames: [String] { (layer?.sublayers ?? []).compactMap(\.name) }
        var pointerPosition: CGPoint? { pointerShown ? pointer.position : nil }

        func clear() {
            for sublayer in layer?.sublayers ?? [] where sublayer !== pointer { sublayer.removeFromSuperlayer() }
            hidePointer()
        }

        func hidePointer() {
            pointer.isHidden = true
            pointerShown = false
        }

        func glide(to point: CGPoint, label: String?) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let from = pointer.presentation()?.position ?? pointer.position
            pointer.position = point
            pointer.isHidden = false
            CATransaction.commit()
            if pointerShown {
                let animation = CABasicAnimation(keyPath: "position")
                animation.fromValue = NSValue(point: from)
                animation.toValue = NSValue(point: point)
                animation.duration = MacComputerOverlay.glideSeconds
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pointer.add(animation, forKey: "glide")
            }
            pointerShown = true
            if let label, !label.isEmpty { self.label(label, at: point) }
        }

        func ripple(at point: CGPoint) {
            let ring = CAShapeLayer()
            ring.name = "ripple"
            ring.path = CGPath(ellipseIn: CGRect(x: -18, y: -18, width: 36, height: 36), transform: nil)
            ring.position = point
            ring.fillColor = tint.withAlphaComponent(0.18).cgColor
            ring.strokeColor = tint.cgColor
            ring.lineWidth = 3
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.4
            grow.toValue = 1.6
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            flash(ring, duration: 0.45, [grow, fade])
        }

        func path(from start: CGPoint, to end: CGPoint) {
            let line = CAShapeLayer()
            line.name = "drag"
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            line.path = path
            line.strokeColor = tint.cgColor
            line.fillColor = nil
            line.lineWidth = 3
            line.lineCap = .round
            line.lineDashPattern = [7, 5]
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.3
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.7, 1]
            flash(line, duration: 0.9, [draw, fade])
            ripple(at: end)
        }

        func scroll(at point: CGPoint, dx: Int, dy: Int) {
            let badge = CAShapeLayer()
            badge.name = "scroll"
            badge.path = CGPath(
                roundedRect: CGRect(x: -14, y: -22, width: 28, height: 44), cornerWidth: 14, cornerHeight: 14,
                transform: nil)
            badge.position = point
            badge.fillColor = tint.withAlphaComponent(0.85).cgColor
            badge.strokeColor = NSColor.white.cgColor
            badge.lineWidth = 1.5
            let arrow = CAShapeLayer()
            let chevron = CGMutablePath()
            chevron.move(to: CGPoint(x: -6, y: 3))
            chevron.addLine(to: CGPoint(x: 0, y: -3))
            chevron.addLine(to: CGPoint(x: 6, y: 3))
            arrow.path = chevron
            arrow.strokeColor = NSColor.white.cgColor
            arrow.fillColor = nil
            arrow.lineWidth = 2.5
            arrow.lineCap = .round
            let angle: CGFloat
            if abs(dx) > abs(dy) {
                angle = dx > 0 ? .pi / 2 : -.pi / 2
            } else {
                angle = dy > 0 ? .pi : 0
            }
            arrow.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            badge.addSublayer(arrow)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.6, 1]
            flash(badge, duration: 0.7, [fade])
        }

        func toast(_ text: String) {
            let card = textCard(text, size: 22, name: "toast")
            card.position = CGPoint(x: bounds.midX, y: 96)
            linger(card)
        }

        private func label(_ text: String, at point: CGPoint) {
            for sublayer in layer?.sublayers ?? [] where sublayer.name == "label" { sublayer.removeFromSuperlayer() }
            let card = textCard(text, size: 12, name: "label")
            let half = CGSize(width: card.bounds.width / 2 + 4, height: card.bounds.height / 2 + 4)
            let x = min(max(point.x + 14 + half.width, half.width), bounds.width - half.width)
            let y = min(max(point.y - 30, half.height), bounds.height - half.height)
            card.position = CGPoint(x: x, y: y)
            linger(card)
        }

        private func textCard(_ text: String, size: CGFloat, name: String) -> CALayer {
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            let measured = string.size()
            let padding = CGSize(width: size * 0.7, height: size * 0.35)
            let card = CALayer()
            card.name = name
            card.bounds = CGRect(
                x: 0, y: 0, width: ceil(measured.width) + padding.width * 2,
                height: ceil(measured.height) + padding.height * 2)
            card.backgroundColor = tint.withAlphaComponent(0.92).cgColor
            card.cornerRadius = min(10, card.bounds.height / 2)
            card.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
            card.borderWidth = 1
            let caption = CATextLayer()
            caption.string = string
            caption.contentsScale = scale
            caption.alignmentMode = .center
            caption.frame = card.bounds.insetBy(dx: padding.width, dy: padding.height)
            card.addSublayer(caption)
            return card
        }

        private func linger(_ layer: CALayer) {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.08, 0.82, 1]
            flash(layer, duration: MacComputerOverlay.labelSeconds, [fade])
        }

        private func flash(_ layer: CALayer, duration: CFTimeInterval, _ animations: [CAAnimation]) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer?.addSublayer(layer)
            CATransaction.commit()
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = duration
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak layer] in layer?.removeFromSuperlayer() }
            layer.add(group, forKey: "cue")
            CATransaction.commit()
        }
    }
#endif
