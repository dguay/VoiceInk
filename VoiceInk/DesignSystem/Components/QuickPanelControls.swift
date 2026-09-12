import SwiftUI

enum QuickPanelEdge {
    case top
    case bottom
}

struct QuickPanelScrollEdge<Content: View>: View {
    let edge: QuickPanelEdge
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: edge == .top ? .top : .bottom) {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .mask(edgeMask)
                .allowsHitTesting(false)

            content()
                .padding(edge == .top ? .top : .bottom, 8)
        }
        .frame(height: edge == .top ? 72 : 64)
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: edge == .top
                ? [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.92), location: 0.60),
                    .init(color: .clear, location: 1),
                ]
                : [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.92), location: 0.40),
                    .init(color: .black, location: 1),
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct QuickPanelButtonBackground: View {
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
            .fill(AppTheme.Surface.control)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(AppTheme.Selection.fill)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .strokeBorder(
                        isSelected ? AppTheme.Selection.border : AppTheme.Border.card,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
    }
}

struct QuickPanelEscapeButton: View {
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("esc")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Text.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(AppTheme.Surface.controlActive, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Escape")
        .accessibilityHint(help)
    }
}
