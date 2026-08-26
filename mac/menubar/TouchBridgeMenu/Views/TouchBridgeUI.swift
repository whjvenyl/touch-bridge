import SwiftUI

// MARK: - TBGroupBox

/// A bordered container with header, content, and footer.
///
/// Inspired by Ice's `IceGroupBox`. Uses a subtle system material fill
/// with a thin stroke — works in both Light and Dark mode, and respects
/// Reduce Transparency / High Contrast via system materials.
///
/// On macOS 26+, the fill uses `.glassEffect` for Liquid Glass; on older
/// macOS, it falls back to `.quinary` fill (matching Ice's approach).
struct TBGroupBox<Header: View, Content: View, Footer: View>: View {
    private let header: Header
    private let content: Content
    private let footer: Footer
    private let padding: CGFloat
    private let cornerRadius: CGFloat

    init(
        padding: CGFloat = 12,
        cornerRadius: CGFloat = 10,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    init(
        padding: CGFloat = 12,
        cornerRadius: CGFloat = 10,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) where Header == EmptyView {
        self.init(padding: padding, cornerRadius: cornerRadius) {
            EmptyView()
        } content: {
            content()
        } footer: {
            footer()
        }
    }

    init(
        padding: CGFloat = 12,
        cornerRadius: CGFloat = 10,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.init(padding: padding, cornerRadius: cornerRadius) {
            header()
        } content: {
            content()
        } footer: {
            EmptyView()
        }
    }

    init(
        padding: CGFloat = 12,
        cornerRadius: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) where Header == EmptyView, Footer == EmptyView {
        self.init(padding: padding, cornerRadius: cornerRadius) {
            EmptyView()
        } content: {
            content()
        } footer: {
            EmptyView()
        }
    }

    init(
        _ title: LocalizedStringKey,
        padding: CGFloat = 12,
        cornerRadius: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) where Header == Text, Footer == EmptyView {
        self.init(padding: padding, cornerRadius: cornerRadius) {
            Text(title)
                .font(.headline)
        } content: {
            content()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            VStack {
                content
            }
            .padding(padding)
            .glassSurface(cornerRadius: cornerRadius)
            footer
        }
    }
}

// MARK: - TBSection

/// A section with optional bordering and automatic dividers between items.
///
/// Inspired by Ice's `IceSection`. When `isBordered`, wraps content in a
/// `TBGroupBox`. When `hasDividers`, inserts `Divider()`s between each
/// child view automatically.
struct TBSection<Header: View, Content: View, Footer: View>: View {
    private let header: Header
    private let content: Content
    private let footer: Footer
    private let spacing: CGFloat
    private let isBordered: Bool
    private let hasDividers: Bool

    init(
        spacing: CGFloat = 10,
        isBordered: Bool = true,
        hasDividers: Bool = true,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.spacing = spacing
        self.isBordered = isBordered
        self.hasDividers = hasDividers
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    init(
        spacing: CGFloat = 10,
        isBordered: Bool = true,
        hasDividers: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) where Header == EmptyView {
        self.init(spacing: spacing, isBordered: isBordered, hasDividers: hasDividers) {
            EmptyView()
        } content: {
            content()
        } footer: {
            footer()
        }
    }

    init(
        spacing: CGFloat = 10,
        isBordered: Bool = true,
        hasDividers: Bool = true,
        @ViewBuilder content: () -> Content
    ) where Header == EmptyView, Footer == EmptyView {
        self.init(spacing: spacing, isBordered: isBordered, hasDividers: hasDividers) {
            EmptyView()
        } content: {
            content()
        } footer: {
            EmptyView()
        }
    }

    init(
        spacing: CGFloat = 10,
        isBordered: Bool = true,
        hasDividers: Bool = true,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.init(spacing: spacing, isBordered: isBordered, hasDividers: hasDividers) {
            header()
        } content: {
            content()
        } footer: {
            EmptyView()
        }
    }

    init(
        _ title: LocalizedStringKey,
        spacing: CGFloat = 10,
        isBordered: Bool = true,
        hasDividers: Bool = true,
        @ViewBuilder content: () -> Content
    ) where Header == Text, Footer == EmptyView {
        self.init(spacing: spacing, isBordered: isBordered, hasDividers: hasDividers) {
            Text(title)
                .font(.headline)
        } content: {
            content()
        }
    }

    init(
        _ title: LocalizedStringKey,
        spacing: CGFloat = 10,
        isBordered: Bool = true,
        hasDividers: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) where Header == Text {
        self.init(spacing: spacing, isBordered: isBordered, hasDividers: hasDividers) {
            Text(title)
                .font(.headline)
        } content: {
            content()
        } footer: {
            footer()
        }
    }

    var body: some View {
        if isBordered {
            TBGroupBox(padding: spacing) {
                header
            } content: {
                dividedContent
            } footer: {
                footer
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                header
                dividedContent
                footer
            }
        }
    }

    @ViewBuilder
    private var dividedContent: some View {
        if hasDividers {
            _VariadicView.Tree(TBSectionLayout(spacing: spacing)) {
                content
                    .frame(maxWidth: .infinity)
            }
        } else {
            content
                .frame(maxWidth: .infinity)
        }
    }
}

private struct TBSectionLayout: _VariadicView_UnaryViewRoot {
    let spacing: CGFloat

    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Divider()
                }
            }
        }
    }
}

// MARK: - TBLabeledContent

/// Label on the left (takes available space), control on the right (fixed).
///
/// Inspired by Ice's `IceLabeledContent`. The label gets `layoutPriority(0)`
/// so it expands, and the content gets `layoutPriority(1)` so it stays
/// intrinsic-sized — giving consistent label-left, control-right alignment.
struct TBLabeledContent<Label: View, Content: View>: View {
    private let label: Label
    private let content: Content

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.label = label()
        self.content = content()
    }

    init(
        _ titleKey: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) where Label == Text {
        self.init {
            content()
        } label: {
            Text(titleKey)
        }
    }

    var body: some View {
        LabeledContent {
            content
                .layoutPriority(1)
        } label: {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
        }
    }
}

// MARK: - TBForm

/// A scrollable form with consistent toggle styling.
///
/// Inspired by Ice's `IceForm`. Wraps content in a VStack with uniform
/// spacing and applies a custom toggle style so every `Toggle` renders
/// as label-left, switch-right at mini size — no need to repeat
/// `.toggleStyle(.switch).controlSize(.mini)` on each one.
struct TBForm<Content: View>: View {
    @State private var contentHeight: CGFloat = 0

    private let alignment: HorizontalAlignment
    private let padding: CGFloat
    private let spacing: CGFloat
    private let content: Content

    init(
        alignment: HorizontalAlignment = .center,
        padding: CGFloat = 20,
        spacing: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.padding = padding
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            if contentHeight > geometry.size.height {
                ScrollView {
                    contentStack
                }
                .scrollContentBackground(.hidden)
            } else {
                contentStack
            }
        }
    }

    private var contentStack: some View {
        VStack(alignment: alignment, spacing: spacing) {
            content
                .toggleStyle(TBFormToggleStyle())
        }
        .padding(padding)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        contentHeight = proxy.size.height
                    }
                    .onChange(of: proxy.size.height) { _, newHeight in
                        contentHeight = newHeight
                    }
            }
        }
    }
}

/// Custom toggle style for use inside `TBForm`.
/// Renders the label on the left and a mini switch on the right,
/// wrapped in `TBLabeledContent` for consistent alignment.
private struct TBFormToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        TBLabeledContent {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        } label: {
            configuration.label
        }
    }
}

// MARK: - Annotation

/// Adds helper text below a control.
///
/// Inspired by Thaw's `AnnotationView`. More granular than section footers —
/// each control can have its own annotation. The text is `.subheadline` size
/// and `.secondary` foreground by default.
extension View {
    func annotation(
        _ titleKey: LocalizedStringKey,
        alignment: HorizontalAlignment = .leading,
        spacing: CGFloat = 2
    ) -> some View {
        VStack(alignment: alignment, spacing: spacing) {
            self
            Text(titleKey)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Settings layout constants

/// Centralized layout constants for settings panes.
///
/// Inspired by Thaw's `SettingsDetailLayout`. Keeps spacing consistent
/// across all settings panes.
enum SettingsLayout {
    /// Comfortable max width for settings content columns.
    static let columnMaxWidth: CGFloat = 680
    /// Leading inset aligned with grouped form section cards / headers.
    static let titleHorizontalInset: CGFloat = 28
    /// Default spacing between sections in a settings form.
    static let sectionSpacing: CGFloat = 16
    /// Default padding inside a group box.
    static let groupPadding: CGFloat = 12
    /// Default corner radius for group boxes.
    static let groupCornerRadius: CGFloat = 10
}

// MARK: - Remove sidebar toggle

/// Removes the sidebar toggle button from a NavigationSplitView's toolbar.
///
/// Inspired by Ice/Thaw's `removeSidebarToggle()` modifier. The sidebar
/// toggle is automatically added by NavigationSplitView but isn't wanted
/// in a settings window where the sidebar should always be visible.
extension View {
    func removeSidebarToggle() -> some View {
        background {
            RemoveSidebarToggleHelper()
        }
    }
}

private struct RemoveSidebarToggleHelper: View {
    @State private var hasRemoved = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard !hasRemoved else { return }
                hasRemoved = true
                // Find the window and remove the sidebar toggle toolbar item
                DispatchQueue.main.async {
                    for window in NSApplication.shared.windows {
                        if let toolbar = window.toolbar {
                            // The sidebar toggle is typically the first item
                            // Remove it by identifier
                            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == "NSToolbarToggleSidebarItem" }) {
                                toolbar.removeItem(at: index)
                            }
                        }
                    }
                }
            }
    }
}
