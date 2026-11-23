import AppKit
import SwiftUI

struct SettingsIconBadge: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        let radius = size * 0.24
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.84), color],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.26), lineWidth: 0.5)
                }
            Image(systemName: systemImage)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(size >= 40 ? 0.14 : 0.08), radius: size >= 40 ? 4 : 1, y: size >= 40 ? 2 : 0.5)
        .accessibilityHidden(true)
    }
}

struct SettingsPageHeader: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Section {
            VStack(spacing: 10) {
                SettingsIconBadge(systemImage: systemImage, color: color, size: 52)
                Text(title)
                    .font(.title2.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? tint : .secondary)
                .frame(width: 18, alignment: .center)
                .opacity(isEnabled ? 1 : 0.55)
            Text(title)
                .foregroundStyle(isEnabled ? .primary : .secondary)
        }
    }
}

struct SettingsValueText: View {
    let text: String
    var width: CGFloat = 46
    @Environment(\.isEnabled) private var isEnabled

    init(_ text: String, width: CGFloat = 46) {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(isEnabled ? .secondary : .tertiary)
            .frame(width: width, alignment: .trailing)
    }
}

struct SidebarActionGlassContainer<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

extension View {
    @ViewBuilder
    func settingsGlassCircleButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        } else {
            self
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        }
    }
}

struct SettingsMenuAction: Identifiable {
    enum Kind {
        case item(title: String, systemImage: String?, isEnabled: Bool, isChecked: Bool, action: @MainActor () -> Void)
        case separator
    }

    let id: Int
    let kind: Kind

    static func item(
        _ id: Int,
        title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        isChecked: Bool = false,
        action: @escaping @MainActor () -> Void
    ) -> Self {
        Self(id: id, kind: .item(title: title, systemImage: systemImage, isEnabled: isEnabled, isChecked: isChecked, action: action))
    }

    static func separator(_ id: Int) -> Self {
        Self(id: id, kind: .separator)
    }
}

@MainActor
private final class SettingsMenuAnchorController: NSObject, ObservableObject {
    weak var anchorView: NSView?
    private var actions: [Int: @MainActor () -> Void] = [:]

    func present(items: [SettingsMenuAction]) {
        guard let anchorView else { return }
        actions.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false

        for entry in items {
            switch entry.kind {
            case .separator:
                menu.addItem(.separator())
            case let .item(title, systemImage, isEnabled, isChecked, action):
                let item = NSMenuItem(title: title, action: #selector(handleMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = entry.id
                item.isEnabled = isEnabled
                item.state = isChecked ? .on : .off
                if let systemImage, let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) {
                    item.image = image
                }
                actions[entry.id] = action
                menu.addItem(item)
            }
        }

        let origin = NSPoint(x: 0, y: anchorView.isFlipped ? anchorView.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: origin, in: anchorView)
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        actions[sender.tag]?()
    }
}

private struct PassiveMenuAnchor: NSViewRepresentable {
    let controller: SettingsMenuAnchorController

    func makeNSView(context: Context) -> PassiveAnchorView {
        let view = PassiveAnchorView()
        controller.anchorView = view
        return view
    }

    func updateNSView(_ nsView: PassiveAnchorView, context: Context) {
        controller.anchorView = nsView
    }

    final class PassiveAnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct SettingsGlassMenuButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let helpText: String
    let items: [SettingsMenuAction]
    @StateObject private var controller = SettingsMenuAnchorController()

    var body: some View {
        Button {
            controller.present(items: items)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .settingsGlassCircleButtonStyle()
        .background(PassiveMenuAnchor(controller: controller))
        .accessibilityLabel(accessibilityLabel)
        .help(helpText)
    }
}

/// Ensures window restoration stays disabled even on macOS 14 where Scene.restorationBehavior is unavailable.
struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowConfiguratorView { WindowConfiguratorView() }
    func updateNSView(_ nsView: WindowConfiguratorView, context: Context) {}

    final class WindowConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
            if let window {
                SettingsWindow.window = window
            }
        }
    }
}
