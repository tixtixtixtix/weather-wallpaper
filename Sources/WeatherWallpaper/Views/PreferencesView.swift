import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var history = SettingsNavigationHistory(initial: .general)
    @FocusState private var sidebarFocused: Bool

    private var sidebarSelection: Binding<SettingsPane?> {
        Binding(
            get: { history.current },
            set: { destination in
                guard let destination else { return }
                history.navigate(to: destination)
            }
        )
    }

    private var selectedWidgetIndex: Int? {
        guard let index = history.current.widgetIndex,
              model.widgetRainAreas.indices.contains(index) else { return nil }
        return index
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailPane
                .toolbar { navigationToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, idealWidth: 720, minHeight: 480, idealHeight: 580)
        .background(SettingsWindowConfigurator())
        .onAppear {
            history.reconcile(widgetAreaCount: model.widgetRainAreas.count)
            sidebarFocused = true
            Task { @MainActor in sidebarFocused = true }
        }
        .onChange(of: model.widgetRainAreas.count) { _, newCount in
            history.reconcile(widgetAreaCount: newCount)
        }
        .onDisappear { model.showsWidgetGuide = false }
        .alert("Weather Wallpaper", isPresented: Binding(
            get: { model.generalError != nil },
            set: { if !$0 { model.generalError = nil } }
        )) {
            Button("OK") { model.generalError = nil }
        } message: {
            Text(model.generalError ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                sidebarRow(.general, summary: generalSummary)
                sidebarRow(.playback, summary: playbackSummary)
                sidebarRow(.sky, summary: skySummary)
                sidebarRow(.notchHaze, summary: notchHazeSummary)
            }
            Section("Widget Rain") {
                if model.widgetRainAreas.isEmpty {
                    sidebarRow(.widgetRain, summary: "No areas", tintOverride: .gray)
                } else {
                    ForEach(model.widgetRainAreas.indices, id: \.self) { index in
                        let enabled = model.widgetRainAreas[index].enabled
                        sidebarRow(
                            .widgetArea(index),
                            summary: widgetSummary(at: index),
                            tintOverride: enabled ? .cyan : .gray
                        )
                        .contextMenu {
                            Button("Duplicate") { duplicateWidgetArea(at: index) }
                                .disabled(model.widgetRainAreas.count >= WidgetRainArea.maximumCount)
                            Divider()
                            Button("Remove", role: .destructive) { removeWidgetArea(at: index) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, 4, for: .scrollContent)
        .focused($sidebarFocused)
        .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 250)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarBottomBar
        }
    }

    private func sidebarRow(_ pane: SettingsPane, summary: String, tintOverride: Color? = nil) -> some View {
        HStack(spacing: 8) {
            SettingsIconBadge(
                systemImage: pane.systemImage,
                color: tintOverride ?? pane.badgeColor,
                size: 22
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .tag(pane)
    }

    private var sidebarBottomBar: some View {
        HStack(spacing: 8) {
            SidebarActionGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: addWidgetArea) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16, height: 16)
                    }
                    .settingsGlassCircleButtonStyle()
                    .disabled(model.widgetRainAreas.count >= WidgetRainArea.maximumCount)
                    .accessibilityLabel("Add Widget Area")
                    .help("Add a widget rain area (up to \(WidgetRainArea.maximumCount))")

                    Button(action: removeSelectedWidgetArea) {
                        Image(systemName: "minus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16, height: 16)
                    }
                    .settingsGlassCircleButtonStyle()
                    .disabled(selectedWidgetIndex == nil)
                    .accessibilityLabel("Remove Widget Area")
                    .help("Remove the selected widget rain area")

                    SettingsGlassMenuButton(
                        systemImage: "ellipsis",
                        accessibilityLabel: "Widget Area Actions",
                        helpText: "More widget area actions",
                        items: widgetMenuItems
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.bottom, 12)
        .padding(.trailing, 12)
        .padding(.top, 6)
    }

    private var widgetMenuItems: [SettingsMenuAction] {
        let canAdd = model.widgetRainAreas.count < WidgetRainArea.maximumCount
        let duplicateTitle = selectedWidgetIndex.map { "Duplicate Widget \($0 + 1)" } ?? "Duplicate Selected Area"
        return [
            .item(1, title: "Add Widget Area", systemImage: "plus", isEnabled: canAdd) {
                addWidgetArea()
            },
            .item(2, title: duplicateTitle, systemImage: "plus.square.on.square",
                  isEnabled: selectedWidgetIndex != nil && canAdd) {
                if let index = selectedWidgetIndex {
                    duplicateWidgetArea(at: index)
                }
            },
            .separator(3),
            .item(4, title: "Show Placement Outline", systemImage: "viewfinder",
                  isEnabled: !model.widgetRainAreas.isEmpty,
                  isChecked: model.showsWidgetGuide) {
                model.showsWidgetGuide.toggle()
            },
            .separator(5),
            .item(6, title: "Remove All Widget Areas", systemImage: "trash",
                  isEnabled: !model.widgetRainAreas.isEmpty) {
                removeAllWidgetAreas()
            }
        ]
    }

    // MARK: - Navigation Toolbar

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button {
                    history.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!history.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")

                Button {
                    history.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(!history.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")
            }
            .controlGroupStyle(.navigation)
        }
    }

    // MARK: - Detail Panes

    private var detailPane: some View {
        Form {
            switch history.current {
            case .general:
                generalPane
            case .playback:
                playbackPane
            case .sky:
                skyPane
            case .notchHaze:
                notchHazePane
            case .widgetRain:
                widgetRainEmptyPane
            case let .widgetArea(index):
                if model.widgetRainAreas.indices.contains(index) {
                    widgetAreaPane(index: index)
                } else {
                    widgetRainEmptyPane
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .contentMargins(.top, 6, for: .scrollContent)
        .id(history.current)
    }

    @ViewBuilder
    private var generalPane: some View {
        SettingsPageHeader(title: "General", systemImage: "gear", color: .gray)

        Section("Startup") {
            Toggle(isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled)) {
                SettingsRowLabel(title: "Open at login", systemImage: "arrow.up.forward.app")
            }
            .help("Closing the main window hides the Dock icon and keeps the wallpaper running in the menu bar. Reopen the window from the menu bar to restore the Dock icon. No helper process is installed.")
        }

        Section("Desktop") {
            LabeledContent {
                Text("All connected displays (\(model.displayCount))")
                    .foregroundStyle(.secondary)
            } label: {
                SettingsRowLabel(
                    title: "Displays",
                    systemImage: model.displayCount > 1 ? "display.2" : "display"
                )
            }
            .help("Weather is shared across displays. Your macOS wallpaper settings, Lock Screen, and screen saver are never modified.")

            LabeledContent {
                HStack(spacing: 10) {
                    Text(model.wallpaperActive ? (model.isPreviewWallpaper ? "Scene active" : "Live weather") : "Inactive")
                        .foregroundStyle(.secondary)
                    if model.wallpaperActive {
                        Button("Remove", role: .destructive, action: model.removeWallpaper)
                            .help("Remove the live wallpaper and reveal your original macOS desktop.")
                    }
                }
            } label: {
                SettingsRowLabel(title: "Live wallpaper", systemImage: "desktopcomputer")
            }
            .help("Apply live weather or a preview scene from the Weather Wallpaper window or menu bar.")
        }

        Section("Sources") {
            let provider = model.snapshot?.effectiveProvider ?? .openMeteo
            LabeledContent {
                HStack(spacing: 6) {
                    Link(provider.name, destination: provider.attributionURL)
                    Text("·").foregroundStyle(.tertiary)
                    Link(
                        provider == .openMeteo ? "CC BY 4.0" : "Data Sources",
                        destination: provider == .openMeteo
                            ? URL(string: "https://creativecommons.org/licenses/by/4.0/")!
                            : provider.attributionURL
                    )
                }
            } label: {
                SettingsRowLabel(title: "Weather data", systemImage: "cloud")
            }

            LabeledContent {
                Link("NASA / LROC", destination: URL(string: "https://svs.gsfc.nasa.gov/4720/")!)
            } label: {
                SettingsRowLabel(title: "Moon imagery", systemImage: "moon.circle")
            }
        }
    }

    @ViewBuilder
    private var playbackPane: some View {
        SettingsPageHeader(title: "Playback", systemImage: "play.fill", color: .green)

        Section("Animation & Power") {
            Toggle(isOn: Binding(
                get: { model.preferences.animationsEnabled },
                set: model.setAnimations
            )) {
                SettingsRowLabel(title: "Animate wallpapers", systemImage: "play.circle")
            }
            .help("Reduce Motion displays a still frame. Animation pauses automatically when displays sleep, your session is inactive, or a rendering window is fully occluded.")

            Toggle(isOn: Binding(
                get: { model.preferences.efficientRendering },
                set: model.setEfficientRendering
            )) {
                SettingsRowLabel(title: "Energy saver", systemImage: "leaf")
            }
            .help("Uses 15 fps, fewer particles, and lower render resolution. Battery power and Low Power Mode enable it automatically.")

            LabeledContent {
                Text(model.powerDescription)
                    .foregroundStyle(.secondary)
            } label: {
                SettingsRowLabel(title: "Rendering", systemImage: "gauge.with.needle")
            }
            .help("Current frame rate and rendering quality mode.")
        }

        Section("Visual Effects") {
            Toggle(isOn: Binding(
                get: { model.preferences.lightningEnabled ?? true },
                set: model.setLightning
            )) {
                SettingsRowLabel(title: "Lightning flashes", systemImage: "bolt")
            }
            .help("Automatically disabled with Reduce Motion, Dim Flashing Lights, or energy saving.")

            Toggle(isOn: Binding(
                get: { model.preferences.bloomEnabled ?? true },
                set: model.setBloom
            )) {
                SettingsRowLabel(title: "Bloom and lens effects", systemImage: "sun.max")
            }
            .help("Sun bloom uses a smaller eighth-resolution pass on battery instead of turning off.")
        }
    }

    @ViewBuilder
    private var skyPane: some View {
        SettingsPageHeader(title: "Sky", systemImage: "cloud.sun.fill", color: .blue)

        Section("Preview Clouds") {
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: $model.cloudCoverageBias, in: -0.3...0.3, step: 0.01)
                    SettingsValueText(formattedSignedPercent(model.cloudCoverageBias))
                }
            } label: {
                SettingsRowLabel(title: "Coverage", systemImage: "cloud")
            }
            .help("Preview looks only — live weather uses its own data.")

            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: $model.cloudShade, in: 0...1, step: 0.01)
                    SettingsValueText(formattedPercent(model.cloudShade))
                }
            } label: {
                SettingsRowLabel(title: "Ceiling shading", systemImage: "shadow")
            }
            .help("Preview looks only — live weather uses its own data.")

            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: $model.highCloudBias, in: -1...1, step: 0.01)
                    SettingsValueText(formattedSignedPercent(model.highCloudBias))
                }
            } label: {
                SettingsRowLabel(title: "High veil", systemImage: "cloud.fog")
            }
            .help("Preview looks only — live weather uses its own data. High veils stay hidden behind opaque low clouds and fog.")
        }

        Section("Shooting Stars") {
            let meteorsEnabled = model.preferences.meteorsEnabled ?? true
            Toggle(isOn: Binding(get: { meteorsEnabled }, set: model.setMeteors)) {
                SettingsRowLabel(title: "Shooting stars", systemImage: "sparkles")
            }
            .help("Occasional meteors on clear night skies. Respects daylight, cloud cover, pause, and Reduce Motion.")

            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: $model.meteorSpeed, in: 0.25...2.5, step: 0.05)
                    SettingsValueText(formattedSpeed(model.meteorSpeed))
                }
            } label: {
                SettingsRowLabel(title: "Meteor speed", systemImage: "gauge.medium")
            }
            .disabled(!meteorsEnabled)
            .help("Fall speed multiplier for shooting stars.")
        }
    }

    @ViewBuilder
    private var notchHazePane: some View {
        SettingsPageHeader(title: "Notch Haze", systemImage: "moon.haze.fill", color: .indigo)

        Section {
            Toggle(isOn: Binding(
                get: { model.notchHaze.enabled },
                set: { enabled in
                    var configuration = model.notchHaze
                    configuration.enabled = enabled
                    model.setNotchHaze(configuration)
                }
            )) {
                SettingsRowLabel(title: "Nighttime notch haze", systemImage: "moon.haze")
            }
            .help("Soft moonlit mist behind notch apps at night. Movement freezes with pause or Reduce Motion.")

            LabeledContent {
                Picker("Notch layout", selection: Binding(
                    get: { model.notchHaze.layout },
                    set: { layout in
                        var configuration = model.notchHaze
                        configuration.layout = layout
                        model.setNotchHaze(configuration)
                    }
                )) {
                    ForEach(NotchHazeLayout.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
            } label: {
                SettingsRowLabel(title: "Notch layout", systemImage: "macbook")
            }
            .disabled(!model.notchHaze.enabled)
            .help("Layout sizing is manual and not linked to another app's expansion state.")

            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(model.notchHaze.intensity) },
                        set: { intensity in
                            var configuration = model.notchHaze
                            configuration.intensity = Float(intensity)
                            model.setNotchHaze(configuration)
                        }
                    ), in: 0...1, step: 0.05)
                    SettingsValueText(formattedPercent(Double(model.notchHaze.intensity)))
                }
            } label: {
                SettingsRowLabel(title: "Intensity", systemImage: "circle.lefthalf.filled")
            }
            .disabled(!model.notchHaze.enabled)
            .help("Controls brightness of the nighttime moonlit mist.")
        }
    }

    @ViewBuilder
    private var widgetRainEmptyPane: some View {
        SettingsPageHeader(title: "Widget Rain", systemImage: "cloud.rain.fill", color: .cyan)

        Section {
            LabeledContent {
                Button("Add Widget Area", action: addWidgetArea)
                    .disabled(model.widgetRainAreas.count >= WidgetRainArea.maximumCount)
            } label: {
                SettingsRowLabel(title: "Widget areas", systemImage: "square.dashed")
            }
            .help("Configure up to \(WidgetRainArea.maximumCount) manual rounded areas where raindrops bounce off the top edge. No automatic detection; rain stays behind desktop widgets.")

            LabeledContent {
                Text(widgetReferenceSummary)
                    .foregroundStyle(.secondary)
            } label: {
                SettingsRowLabel(title: "Reference display", systemImage: "display")
            }
            .help("X increases rightward and Y increases downward from the top-left. Positions and sizes scale proportionally on other displays.")
        }
    }

    @ViewBuilder
    private func widgetAreaPane(index: Int) -> some View {
        let area = model.widgetRainAreas[index]
        SettingsPageHeader(
            title: "Widget \(index + 1)",
            systemImage: "cloud.rain.fill",
            color: area.enabled ? .cyan : .gray
        )

        Section("Behavior") {
            Toggle(isOn: Binding(
                get: { model.widgetRainAreas.indices.contains(index) ? model.widgetRainAreas[index].enabled : false },
                set: { enabled in
                    var areas = model.widgetRainAreas
                    guard areas.indices.contains(index) else { return }
                    areas[index].enabled = enabled
                    model.setWidgetRainAreas(areas)
                }
            )) {
                SettingsRowLabel(title: "Bounce rain on this area", systemImage: "drop")
            }
            .help("Middle and foreground raindrops splash on the rounded top edge. Rain effects remain behind desktop widgets.")

            Toggle(isOn: $model.showsWidgetGuide) {
                SettingsRowLabel(title: "Show placement outline", systemImage: "viewfinder")
            }
            .help("Apply a wallpaper and use outlines to align each area. Outlines hide automatically when Settings closes.")
        }

        Section("Position & Size") {
            widgetNumberInput(
                "X (px)",
                systemImage: "arrow.right.to.line",
                index: index,
                \.x,
                range: 0...widgetPixelWidth,
                scale: widgetPixelWidth,
                help: "Horizontal offset from the left edge of \(widgetReferenceScreenName). X increases rightward."
            )
            widgetNumberInput(
                "Y (px)",
                systemImage: "arrow.down.to.line",
                index: index,
                \.y,
                range: 0...widgetPixelHeight,
                scale: widgetPixelHeight,
                help: "Vertical offset from the top edge of \(widgetReferenceScreenName). Y increases downward."
            )
            widgetNumberInput(
                "Width (px)",
                systemImage: "arrow.left.and.right",
                index: index,
                \.width,
                range: (widgetPixelWidth * 0.02)...widgetPixelWidth,
                scale: widgetPixelWidth,
                help: "Area width in backing pixels on \(widgetReferenceScreenName). Scales proportionally on other displays."
            )
            widgetNumberInput(
                "Height (px)",
                systemImage: "arrow.up.and.down",
                index: index,
                \.height,
                range: (widgetPixelHeight * 0.02)...widgetPixelHeight,
                scale: widgetPixelHeight,
                help: "Area height in backing pixels on \(widgetReferenceScreenName). Scales proportionally on other displays."
            )
            widgetNumberInput(
                "Corner radius (px)",
                systemImage: "rectangle.roundedtop",
                index: index,
                \.cornerRadius,
                range: 0...(100 * widgetPixelScale),
                scale: widgetPixelScale,
                help: "Rounded top-edge corner radius, stored in logical screen points."
            )

            LabeledContent {
                Text(widgetReferenceSummary)
                    .foregroundStyle(.secondary)
            } label: {
                SettingsRowLabel(title: "Reference display", systemImage: "display")
            }
            .help("Up to \(WidgetRainArea.maximumCount) manual areas shared across displays. Layouts scale proportionally on other displays.")
        }
    }

    private func widgetNumberInput(
        _ title: String,
        systemImage: String,
        index: Int,
        _ key: WritableKeyPath<WidgetRainArea, Float>,
        range: ClosedRange<Double>,
        scale: Double,
        help: String
    ) -> some View {
        // Capture the area index so a pending text-field commit cannot edit another
        // widget when selection changes. Recreate field state on selection or scale changes.
        let value = Binding<Double>(
            get: {
                let areas = model.widgetRainAreas
                return areas.indices.contains(index) ? Double(areas[index][keyPath: key]) * scale : range.lowerBound
            },
            set: { newValue in
                var areas = model.widgetRainAreas
                guard newValue.isFinite, areas.indices.contains(index) else { return }
                areas[index][keyPath: key] = Float(min(range.upperBound, max(range.lowerBound, newValue)) / scale)
                model.setWidgetRainAreas(areas)
            }
        )
        return LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Stepper(title, value: value, in: range, step: 1)
                    .labelsHidden()
                    .fixedSize()
            }
        } label: {
            SettingsRowLabel(title: title, systemImage: systemImage)
        }
        .help(help)
        .id("\(index)-\(title)-\(scale)")
    }

    // MARK: - Widget Actions

    private func addWidgetArea() {
        var areas = model.widgetRainAreas
        guard areas.count < WidgetRainArea.maximumCount else { return }
        let previousCount = areas.count
        var area = WidgetRainArea()
        area.enabled = true
        areas.append(area)
        model.setWidgetRainAreas(areas)
        model.showsWidgetGuide = true
        history.didAddWidgetArea(at: areas.count - 1, previousCount: previousCount)
    }

    private func duplicateWidgetArea(at index: Int) {
        var areas = model.widgetRainAreas
        guard areas.indices.contains(index), areas.count < WidgetRainArea.maximumCount else { return }
        let previousCount = areas.count
        var copy = areas[index]
        copy.x += 0.03
        copy.y += 0.03
        areas.append(copy.sanitized)
        model.setWidgetRainAreas(areas)
        history.didAddWidgetArea(at: areas.count - 1, previousCount: previousCount)
    }

    private func removeSelectedWidgetArea() {
        guard let index = selectedWidgetIndex else { return }
        removeWidgetArea(at: index)
    }

    private func removeWidgetArea(at index: Int) {
        var areas = model.widgetRainAreas
        guard areas.indices.contains(index) else { return }
        areas.remove(at: index)
        model.setWidgetRainAreas(areas)
        if areas.isEmpty { model.showsWidgetGuide = false }
        history.didRemoveWidgetArea(at: index, remainingCount: areas.count)
    }

    private func removeAllWidgetAreas() {
        guard !model.widgetRainAreas.isEmpty else { return }
        model.setWidgetRainAreas([])
        model.showsWidgetGuide = false
        history.didRemoveAllWidgetAreas()
    }

    // MARK: - Sidebar Summaries & Formatting

    private var generalSummary: String {
        if model.wallpaperActive {
            return "\(model.displayCount) \(model.displayCount == 1 ? "display" : "displays")"
        }
        return model.loginEnabled ? "Opens at login" : "Menu bar"
    }

    private var playbackSummary: String {
        if !model.preferences.animationsEnabled { return "Paused" }
        if model.isReduceMotion { return "Still frame" }
        if model.preferences.efficientRendering || model.isOnBattery || model.isLowPower {
            return "15 fps · Energy saver"
        }
        return "30 fps"
    }

    private var skySummary: String {
        (model.preferences.meteorsEnabled ?? true) ? "Shooting stars on" : "Shooting stars off"
    }

    private var notchHazeSummary: String {
        guard model.notchHaze.enabled else { return "Off" }
        return "\(model.notchHaze.layout.title) · \(formattedPercent(Double(model.notchHaze.intensity)))"
    }

    private func widgetSummary(at index: Int) -> String {
        let area = model.widgetRainAreas[index]
        guard area.enabled else { return "Off" }
        let width = Int((Double(area.width) * widgetPixelWidth).rounded())
        let height = Int((Double(area.height) * widgetPixelHeight).rounded())
        return "\(width) × \(height) px"
    }

    private func formattedPercent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func formattedSignedPercent(_ value: Double) -> String {
        let rounded = Int((value * 100).rounded())
        return rounded > 0 ? "+\(rounded)%" : "\(rounded)%"
    }

    private func formattedSpeed(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2))))×"
    }

    // Use one stable reference display, not whichever screen currently hosts
    // Settings. Storage stays normalized, and radius stays in logical points.
    private var widgetReferenceScreen: NSScreen? { NSScreen.screens.first }
    private var widgetReferenceScreenName: String { widgetReferenceScreen?.localizedName ?? "the primary display" }
    private var widgetPixelScale: Double { Double(widgetReferenceScreen?.backingScaleFactor ?? 1) }
    private var widgetPixelWidth: Double { Double(widgetReferenceScreen?.frame.width ?? 1920) * widgetPixelScale }
    private var widgetPixelHeight: Double { Double(widgetReferenceScreen?.frame.height ?? 1080) * widgetPixelScale }
    private var widgetReferenceSummary: String {
        "\(widgetReferenceScreen?.localizedName ?? "Primary display") (\(Int(widgetPixelWidth)) × \(Int(widgetPixelHeight)) px)"
    }
}
