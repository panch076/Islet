import AppKit
import SwiftUI

struct ArtworkView: View {
    var image: NSImage?
    var cornerRadius: CGFloat
    var palette: [Color] = ArtworkPalette.fallback

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        LinearGradient(colors: [palette[0], palette[8]], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note")
                            .font(.system(size: 200, weight: .semibold))
                            .minimumScaleFactor(0.05)
                            .padding(cornerRadius * 1.5)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
    }
}

/// Apple Music-style "•••" shown during instrumental breaks.
struct InstrumentalDots: View {
    var size: CGFloat
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.55) {
                ForEach(0..<3) { i in
                    let phase = sin(t * 2.4 - Double(i) * 0.7)
                    Circle()
                        .fill(color.opacity(0.45 + 0.5 * (phase + 1) / 2))
                        .frame(width: size, height: size)
                        .scaleEffect(0.82 + 0.22 * (phase + 1) / 2)
                }
            }
            .scaleEffect(1 + 0.04 * sin(t * 1.2))
        }
        .accessibilityLabel("Instrumental")
    }
}

/// A single lyric line that fills in left-to-right as it's sung.
struct SweepText: View {
    let text: String
    let progress: Double
    let font: Font

    var body: some View {
        let lead = min(max(progress * 1.12 - 0.12, 0), 1)
        let edge = min(max(progress * 1.12, 0.0001), 1)
        Text(text)
            .font(font)
            .foregroundStyle(.tertiary)
            .overlay {
                Text(text)
                    .font(font)
                    .foregroundStyle(.primary)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: lead),
                                .init(color: .clear, location: max(edge, lead + 0.0001)),
                            ],
                            startPoint: .leading, endPoint: .trailing)
                    }
            }
    }
}

/// Sweeps a highlight through wrapped text line by line: the first visual
/// line fills left to right, then the next, so multi-line lyrics light up in
/// reading order. Only `litOpacity` animates, so lines fade rather than
/// un-sweep when they finish.
@available(macOS 15, *)
struct KaraokeRenderer: TextRenderer, Animatable {
    var progress: Double
    var litOpacity: Double
    var dimOpacity: Double
    var feather: CGFloat

    var animatableData: Double {
        get { litOpacity }
        set { litOpacity = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let lines = Array(layout)
        let total = lines.reduce(0) { $0 + $1.typographicBounds.width }
        var remaining = CGFloat(min(max(progress, 0), 1)) * total

        for line in lines {
            let bounds = line.typographicBounds.rect
            var dim = context
            dim.opacity = dimOpacity
            dim.draw(line)

            let lit = min(max(remaining, 0), bounds.width)
            remaining -= bounds.width
            guard lit > 0 else { continue }

            var bright = context
            bright.opacity = litOpacity
            let solidEnd = lit / (lit + feather)
            bright.clipToLayer { layer in
                layer.fill(
                    Path(bounds.insetBy(dx: 0, dy: -bounds.height * 0.3)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: solidEnd),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: CGPoint(x: bounds.minX, y: 0),
                        endPoint: CGPoint(x: bounds.minX + lit + feather, y: 0)))
            }
            bright.draw(line)
        }
    }
}

struct SourceBadge: View {
    let source: PlaybackSource

    var body: some View {
        Label(source.title, systemImage: source.symbol)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .adaptiveGlass(.regular, in: .capsule)
    }
}

/// Full-screen backdrop: the album artwork itself, enlarged and heavily
/// blurred, drifting slowly. It's rasterised small and scaled up, which keeps
/// the very large blur cheap; the palette mesh covers tracks without artwork.
struct AnimatedArtworkBackground: View {
    var image: NSImage?
    var palette: [Color]
    var trackID: String?

    @State private var drift = false

    private static let renderSide: CGFloat = 160

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 1.3
            ZStack {
                PaletteGradient(palette: palette.count == 9 ? palette : ArtworkPalette.fallback)
                    .blur(radius: 40, opaque: true)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.renderSide, height: Self.renderSide)
                        .clipped()
                        .blur(radius: 7, opaque: true)
                        .saturation(1.3)
                        .drawingGroup()
                        .scaleEffect(side / Self.renderSide)
                        .scaleEffect(drift ? 1.1 : 1)
                        .rotationEffect(.degrees(drift ? 5 : -5))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(trackID)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(Color.black.opacity(0.32))
            .overlay(
                RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center,
                               startRadius: geo.size.width * 0.2, endRadius: geo.size.width * 0.8)
            )
        }
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: trackID)
        .onAppear {
            withAnimation(.easeInOut(duration: 28).repeatForever(autoreverses: true)) { drift = true }
        }
    }

}

/// The artwork's 3×3 colour grid as a mesh gradient (macOS 15+), or a
/// diagonal gradient through the same colours on Sonoma.
private struct PaletteGradient: View {
    let palette: [Color]

    private static let meshPoints: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.5, 0.5], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]

    var body: some View {
        if #available(macOS 15, *) {
            MeshGradient(width: 3, height: 3, points: Self.meshPoints, colors: palette)
        } else {
            LinearGradient(colors: [palette[0], palette[4], palette[8]],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

extension View {
    /// Applies the user's chosen Liquid Glass variant.
    @ViewBuilder
    func lyricalGlass(_ style: PanelGlass, accent: Color, in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            switch style {
            case .regular: glassEffect(.regular, in: shape)
            case .clear: glassEffect(.clear, in: shape)
            case .tinted: glassEffect(.regular.tint(accent.opacity(0.55)), in: shape)
            }
        } else {
            modifier(DesktopMaterial(style: style, accent: accent, shape: shape))
        }
    }
}
