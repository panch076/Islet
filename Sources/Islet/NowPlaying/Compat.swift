import AppKit
import SwiftUI

// Liquid Glass is macOS 26+. These wrappers mirror its API so call sites stay
// the same, and fall back to native vibrancy materials on Sonoma and Sequoia.

/// A description of a glass surface that maps onto `Glass` on macOS 26 and a
/// material + highlight treatment on earlier systems.
struct GlassSpec {
    enum Kind { case regular, clear }

    var kind: Kind = .regular
    var tintColor: Color?
    var isInteractive = false

    static let regular = GlassSpec()
    static let clear = GlassSpec(kind: .clear)

    func tint(_ color: Color) -> GlassSpec {
        var copy = self
        copy.tintColor = color
        return copy
    }

    func interactive() -> GlassSpec {
        var copy = self
        copy.isInteractive = true
        return copy
    }

    @available(macOS 26, *)
    var glass: Glass {
        var glass: Glass = kind == .clear ? .clear : .regular
        if let tintColor { glass = glass.tint(tintColor) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Liquid Glass on macOS 26; a frosted material with a specular edge before that.
    @ViewBuilder
    func adaptiveGlass(_ spec: GlassSpec = .regular, in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(spec.glass, in: shape)
        } else {
            modifier(MaterialGlass(spec: spec, shape: shape))
        }
    }
}

/// Groups glass shapes so they blend and morph together on macOS 26; a plain
/// pass-through on earlier systems.
struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// In-window fallback: SwiftUI material plus a soft top highlight, which reads
/// as glass on Sonoma/Sequoia.
private struct MaterialGlass<S: Shape>: ViewModifier {
    let spec: GlassSpec
    let shape: S

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if spec.kind == .clear {
                        shape.fill(.ultraThinMaterial)
                    } else {
                        shape.fill(.regularMaterial)
                    }
                    if let tint = spec.tintColor {
                        shape.fill(tint.opacity(0.35))
                    }
                    if spec.isInteractive {
                        shape.fill(.white.opacity(hovering ? 0.12 : 0))
                    }
                    shape.stroke(Self.highlight, lineWidth: 0.75)
                }
            }
            .contentShape(shape)
            .onHover { inside in
                guard spec.isInteractive else { return }
                withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            }
    }

    static var highlight: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08), .white.opacity(0.18)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Desktop-overlay fallback for the floating panel: blurs whatever is behind
/// the window (wallpaper, other apps), which SwiftUI materials can't do.
struct DesktopMaterial<S: Shape>: ViewModifier {
    let style: PanelGlass
    let accent: Color
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    VisualEffectBackground(material: style == .clear ? .hudWindow : .popover)
                        .opacity(style == .clear ? 0.75 : 1)
                    if style == .tinted {
                        accent.opacity(0.35)
                    }
                }
                .clipShape(shape)
                .overlay(shape.stroke(MaterialGlass<S>.highlight, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
