import AppKit
import Combine
import SwiftUI

/// Manages a dynamic `NSStatusItem` that shows realtime status text in the
/// menu bar, beyond what `MenuBarExtra`'s static label supports.
///
/// Inspired by Multi/Remotion's approach:
/// https://multi.app/blog/pushing-the-limits-nsstatusitem
///
/// Uses `NSStatusItem` + `NSHostingView` with a `GeometryReader` +
/// `PreferenceKey` to communicate size changes back to the
/// `NSStatusBarButton`, allowing the status item to grow/shrink
/// dynamically based on content.
@MainActor
final class StatusItemManager: ObservableObject {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<StatusItemContent>?
    private var popover: NSPopover?

    /// The SwiftUI view model that drives the status item content.
    @Published var statusText: String = ""
    @Published var statusColor: Color = .secondary
    @Published var iconName: String = "touchid"
    @Published var showBadge: Bool = false
    @Published var badgeCount: Int = 0
    @Published var isAuthPending: Bool = false

    private var sizePassthrough = PassthroughSubject<CGSize, Never>()
    private var sizeCancellable: AnyCancellable?

    // MARK: - Setup

    func setup() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let hostingView = NSHostingView(
            rootView: StatusItemContent(
                iconName: iconName,
                statusText: statusText,
                statusColor: statusColor,
                showBadge: showBadge,
                badgeCount: badgeCount,
                isAuthPending: isAuthPending,
                sizePassthrough: sizePassthrough
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 30, height: 24)
        statusItem.button?.frame = hostingView.frame
        statusItem.button?.addSubview(hostingView)

        // Click shows the popover
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        self.statusItem = statusItem
        self.hostingView = hostingView

        sizeCancellable = sizePassthrough.sink { [weak self] size in
            let frame = NSRect(origin: .zero, size: .init(width: max(size.width, 24), height: 24))
            self?.hostingView?.frame = frame
            self?.statusItem?.button?.frame = frame
        }
    }

    // MARK: - Update

    /// Update the status item content from app state.
    func update(
        isInstalled: Bool,
        isDaemonRunning: Bool,
        connectedDevices: Int,
        isAuthPending: Bool
    ) {
        // Determine icon
        iconName = "touchid"

        // Determine color
        if !isInstalled {
            statusColor = .red
        } else if !isDaemonRunning {
            statusColor = .orange
        } else if connectedDevices > 0 {
            statusColor = .green
        } else {
            statusColor = .secondary
        }

        // Determine text
        if !isInstalled {
            statusText = ""
        } else if isAuthPending {
            statusText = "Auth…"
            statusColor = .green
        } else if connectedDevices > 0 {
            statusText = "\(connectedDevices)"
        } else if isDaemonRunning {
            statusText = ""
        } else {
            statusText = ""
        }

        // Badge
        showBadge = isAuthPending
        badgeCount = isAuthPending ? 1 : 0
        self.isAuthPending = isAuthPending

        // Refresh the hosting view
        hostingView?.rootView = StatusItemContent(
            iconName: iconName,
            statusText: statusText,
            statusColor: statusColor,
            showBadge: showBadge,
            badgeCount: badgeCount,
            isAuthPending: isAuthPending,
            sizePassthrough: sizePassthrough
        )
    }

    // MARK: - Popover

    /// The SwiftUI view to show in the popover. Set by the app.
    var popoverContent: AnyView?

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popoverContent else { return }

        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: popoverContent)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)

        self.popover = popover
    }

    /// Close the popover if it's currently shown.
    func closePopover() {
        popover?.performClose(nil)
    }

    // MARK: - Teardown

    deinit {
        statusItem = nil
        hostingView = nil
        sizeCancellable?.cancel()
    }
}

// MARK: - Status item SwiftUI content

private struct StatusItemContent: View {
    let iconName: String
    let statusText: String
    let statusColor: Color
    let showBadge: Bool
    let badgeCount: Int
    let isAuthPending: Bool
    let sizePassthrough: PassthroughSubject<CGSize, Never>

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusColor)
                .symbolRenderingMode(.hierarchical)

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .fixedSize()
            }

            if showBadge {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 2)
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: StatusItemSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(StatusItemSizeKey.self) { size in
            sizePassthrough.send(size)
        }
    }
}

private struct StatusItemSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
