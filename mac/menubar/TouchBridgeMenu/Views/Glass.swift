import SwiftUI

/// Cross-version Liquid Glass wrapper.
///
/// On macOS 26+ (Tahoe), applies the native `.glassEffect()` API.
/// On macOS 14–15, falls back to `.regularMaterial` with a subtle
/// inner stroke — visually close enough that the layout doesn't
/// read as broken, and everything uses system materials so Dark Mode,
/// Reduce Transparency, and High Contrast work without extra code.
extension View {

    /// Apply a Liquid Glass surface to the view.
    ///
    /// - Parameters:
    ///   - cornerRadius: Rounded-rectangle radius for the glass shape.
    ///   - tint: Optional tint color (`.regular.tint(...)` on 26,
    ///     opacity overlay on older macOS).
    ///   - interactive: Adds `.interactive()` glass variant on 26.
    ///     Use only on tappable elements.
    @ViewBuilder
    func glassSurface(
        cornerRadius: CGFloat = 12,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.modifier(NativeGlass(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive
            ))
        } else {
            self.modifier(FallbackGlass(
                cornerRadius: cornerRadius,
                tint: tint
            ))
        }
    }
}

// MARK: - macOS 26+ native

@available(macOS 26.0, *)
private struct NativeGlass: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let tint, interactive {
            content.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else if let tint {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else if interactive {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

// MARK: - macOS 14–15 fallback

private struct FallbackGlass: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background {
            ZStack {
                shape.fill(.regularMaterial)
                if let tint {
                    shape.fill(tint.opacity(0.22))
                }
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Glass container

/// Cross-version replacement for `GlassEffectContainer`.
///
/// On macOS 26+, groups adjacent glass siblings so they share a
/// sampling region for consistent rendering. On older macOS, it's
/// a transparent passthrough — each child renders its own material
/// card.
struct GlassContainer<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            if let spacing {
                GlassEffectContainer(spacing: spacing) { content() }
            } else {
                GlassEffectContainer { content() }
            }
        } else {
            content()
        }
    }
}
