import AstralCore
import SwiftUI

/// Centered, wrapping native equivalents of the server welcome flex rows.
struct WelcomeExamplesLayout: Layout {
    var spacing: CGFloat = 12

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var result: [[(Int, CGSize)]] = []
        var row: [(Int, CGSize)] = []
        var used: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if !row.isEmpty && used + spacing + size.width > width {
                result.append(row)
                row = []
                used = 0
            }
            used += (row.isEmpty ? 0 : spacing) + size.width
            row.append((index, size))
        }
        if !row.isEmpty { result.append(row) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 704)
        let rows = rows(subviews, width: width)
        let height = rows.reduce(CGFloat.zero) { $0 + ($1.map { $0.1.height }.max() ?? 0) }
        return CGSize(width: width, height: height + CGFloat(max(0, rows.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let width = row.reduce(CGFloat.zero) { $0 + $1.1.width } + CGFloat(max(0, row.count - 1)) * spacing
            let height = row.map { $0.1.height }.max() ?? 0
            var x = bounds.midX - width / 2
            for (index, size) in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }
}

struct WelcomeExampleButtonStyle: ButtonStyle {
    let palette: AstralPalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AstralTypography.subheadline)
            .foregroundStyle(palette.muted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(configuration.isPressed ? palette.text.opacity(0.04) : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(palette.text.opacity(configuration.isPressed ? 0.24 : 0.1)))
            .contentShape(Capsule())
    }
}
