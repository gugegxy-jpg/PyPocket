import SwiftUI

/// 独立设计的静态背景；不使用持续动画，降低脚本运行时的额外耗电。
struct PocketBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(colors: [Color.teal.opacity(scheme == .dark ? 0.22 : 0.13),
                                    .clear, Color.indigo.opacity(scheme == .dark ? 0.24 : 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.mint.opacity(0.12), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
    }
}

private struct PocketGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
        }
    }
}

extension View {
    func pocketGlass(radius: CGFloat = 26) -> some View {
        modifier(PocketGlass(radius: radius))
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .pocketGlass()
    }
}

struct StatusPill: View {
    let title: String
    var active = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(active ? Color.teal : Color.secondary).frame(width: 6, height: 6)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(.primary.opacity(0.05), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct RunButton: View {
    let active: Bool
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
    private var button: some View {
        Button(action: action) {
            Label(active ? "停止运行" : "运行脚本", systemImage: active ? "stop.fill" : "play.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .tint(active ? .orange : .teal)
        .controlSize(.large)
        .disabled(disabled)
        .accessibilityIdentifier("run-stop")
    }
}
