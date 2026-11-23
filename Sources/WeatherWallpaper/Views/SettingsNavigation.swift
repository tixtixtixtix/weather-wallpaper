import AppKit
import SwiftUI

enum SettingsWindow {
    static let id = "settings"
    @MainActor static weak var window: NSWindow?
}

enum SettingsPane: Hashable {
    case general
    case playback
    case sky
    case notchHaze
    case widgetRain
    case widgetArea(Int)

    var title: String {
        switch self {
        case .general: "General"
        case .playback: "Playback"
        case .sky: "Sky"
        case .notchHaze: "Notch Haze"
        case .widgetRain: "Widget Rain"
        case let .widgetArea(index): "Widget \(index + 1)"
        }
    }

    /// Every symbol is verified to exist on macOS 14.0 (the minimum deployment target).
    var systemImage: String {
        switch self {
        case .general: "gear"
        case .playback: "play.fill"
        case .sky: "cloud.sun.fill"
        case .notchHaze: "moon.haze.fill"
        case .widgetRain, .widgetArea: "cloud.rain.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .general: .gray
        case .playback: .green
        case .sky: .blue
        case .notchHaze: .indigo
        case .widgetRain, .widgetArea: .cyan
        }
    }

    var widgetIndex: Int? {
        if case let .widgetArea(index) = self { return index }
        return nil
    }
}

struct SettingsNavigationHistory: Equatable {
    private(set) var entries: [SettingsPane]
    private(set) var currentIndex: Int

    init(initial: SettingsPane = .general) {
        entries = [initial]
        currentIndex = 0
    }

    var current: SettingsPane { entries[currentIndex] }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex < entries.count - 1 }

    mutating func navigate(to pane: SettingsPane) {
        guard pane != current else { return }
        if currentIndex + 1 < entries.count {
            entries.removeSubrange((currentIndex + 1)...)
        }
        entries.append(pane)
        currentIndex = entries.count - 1
    }

    @discardableResult
    mutating func goBack() -> SettingsPane {
        guard canGoBack else { return current }
        currentIndex -= 1
        return current
    }

    @discardableResult
    mutating func goForward() -> SettingsPane {
        guard canGoForward else { return current }
        currentIndex += 1
        return current
    }

    mutating func didAddWidgetArea(at index: Int, previousCount: Int) {
        if previousCount == 0 {
            let mapped = entries.map { $0 == .widgetRain ? SettingsPane.widgetArea(index) : $0 }
            rebuild(from: mapped, preferredIndex: currentIndex, fallback: .widgetArea(index))
        }
        navigate(to: .widgetArea(index))
    }

    mutating func didRemoveWidgetArea(at removedIndex: Int, remainingCount: Int) {
        let wasViewingRemoved = current == .widgetArea(removedIndex)
        let replacement: SettingsPane = remainingCount > 0
            ? .widgetArea(min(removedIndex, remainingCount - 1))
            : .widgetRain

        var mapped: [SettingsPane] = []
        var mappedCurrentIndex: Int?
        for (offset, entry) in entries.enumerated() {
            switch entry {
            case let .widgetArea(index) where index == removedIndex:
                if offset == currentIndex {
                    mappedCurrentIndex = mapped.count
                    mapped.append(replacement)
                }
            case let .widgetArea(index) where index > removedIndex:
                if offset == currentIndex { mappedCurrentIndex = mapped.count }
                mapped.append(.widgetArea(index - 1))
            default:
                if offset == currentIndex { mappedCurrentIndex = mapped.count }
                mapped.append(entry)
            }
        }

        if mapped.isEmpty {
            entries = [replacement]
            currentIndex = 0
            return
        }

        rebuild(from: mapped, preferredIndex: mappedCurrentIndex ?? (mapped.count - 1), fallback: replacement)
        if wasViewingRemoved && current != replacement {
            navigate(to: replacement)
        }
    }

    mutating func didRemoveAllWidgetAreas() {
        let wasViewingWidget = current.widgetIndex != nil
        var mapped: [SettingsPane] = []
        var mappedCurrentIndex: Int?
        for (offset, entry) in entries.enumerated() {
            if entry.widgetIndex != nil {
                if offset == currentIndex {
                    mappedCurrentIndex = mapped.count
                    mapped.append(.widgetRain)
                }
            } else {
                if offset == currentIndex { mappedCurrentIndex = mapped.count }
                mapped.append(entry)
            }
        }
        rebuild(from: mapped, preferredIndex: mappedCurrentIndex ?? max(0, mapped.count - 1), fallback: .widgetRain)
        if wasViewingWidget && current != .widgetRain {
            navigate(to: .widgetRain)
        }
    }

    mutating func reconcile(widgetAreaCount: Int) {
        var mapped: [SettingsPane] = []
        var mappedCurrentIndex: Int?
        for (offset, entry) in entries.enumerated() {
            let resolved: SettingsPane?
            switch entry {
            case .widgetRain:
                resolved = widgetAreaCount > 0 ? .widgetArea(0) : .widgetRain
            case let .widgetArea(index):
                if widgetAreaCount == 0 {
                    resolved = offset == currentIndex ? .widgetRain : nil
                } else if index < widgetAreaCount {
                    resolved = .widgetArea(index)
                } else {
                    resolved = offset == currentIndex ? .widgetArea(widgetAreaCount - 1) : nil
                }
            default:
                resolved = entry
            }
            if let resolved {
                if offset == currentIndex { mappedCurrentIndex = mapped.count }
                mapped.append(resolved)
            }
        }
        let fallback: SettingsPane = widgetAreaCount > 0 ? .widgetArea(0) : .general
        rebuild(from: mapped, preferredIndex: mappedCurrentIndex ?? max(0, mapped.count - 1), fallback: fallback)
    }

    private mutating func rebuild(from raw: [SettingsPane], preferredIndex: Int, fallback: SettingsPane) {
        guard !raw.isEmpty else {
            entries = [fallback]
            currentIndex = 0
            return
        }
        var deduplicated: [SettingsPane] = []
        var resolvedIndex = 0
        let clampedPreferred = max(0, min(preferredIndex, raw.count - 1))
        for (offset, entry) in raw.enumerated() {
            if deduplicated.last != entry {
                deduplicated.append(entry)
            }
            if offset == clampedPreferred {
                resolvedIndex = max(0, deduplicated.count - 1)
            }
        }
        entries = deduplicated
        currentIndex = max(0, min(resolvedIndex, deduplicated.count - 1))
    }
}
