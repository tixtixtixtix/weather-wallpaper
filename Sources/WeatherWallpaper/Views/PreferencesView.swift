import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @State private var selectedWidget = 0

    var body: some View {
        Form {
            Section("Sky") {
                LabeledContent("Coverage") {
                    Slider(value: $model.cloudCoverageBias, in: -0.3...0.3, step: 0.01)
                }
                LabeledContent("Ceiling shading") {
                    Slider(value: $model.cloudShade, in: 0...1, step: 0.01)
                }
                LabeledContent("High veil") {
                    Slider(value: $model.highCloudBias, in: -1...1, step: 0.01)
                }
                Text("Preview looks only — live weather uses its own data. High veils stay hidden behind opaque low clouds and fog.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Meteor speed") {
                    Slider(value: $model.meteorSpeed, in: 0.25...2.5, step: 0.05)
                }
                Toggle("Shooting stars", isOn: Binding(get: { model.preferences.meteorsEnabled ?? true }, set: model.setMeteors))
            }
            Section("Playback") {
                Toggle("Animate wallpapers", isOn: Binding(
                    get: { model.preferences.animationsEnabled }, set: model.setAnimations
                ))
                Toggle("Energy saver", isOn: Binding(
                    get: { model.preferences.efficientRendering }, set: model.setEfficientRendering
                ))
                Toggle("Lightning flashes", isOn: Binding(
                    get: { model.preferences.lightningEnabled ?? true }, set: model.setLightning
                ))
                Toggle("Bloom and lens effects", isOn: Binding(
                    get: { model.preferences.bloomEnabled ?? true }, set: model.setBloom
                ))
                Text("Lightning is disabled with Reduce Motion, Dim Flashing Lights, or energy saving. Sun bloom uses a smaller, eighth-resolution pass on battery instead of disappearing.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Energy saver uses 15 fps, fewer particles, and lower render resolution. Battery power and Low Power Mode enable it automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Rendering", value: model.powerDescription)
                Text("Reduce Motion displays a still frame. Animation stops when displays sleep, your session is inactive, or a rendering window is fully occluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled))
                Text("Closing the main window hides the Dock icon and keeps the wallpaper running in the menu bar. Reopen the window from the menu bar to restore the Dock icon. Quit from the menu bar to stop the app. No helper process is installed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Moonlit notch haze") {
                Toggle("Nighttime notch haze",isOn: Binding(get: { model.notchHaze.enabled },set: { enabled in
                    var configuration = model.notchHaze; configuration.enabled = enabled; model.setNotchHaze(configuration)
                }))
                Picker("Notch layout",selection: Binding(get: { model.notchHaze.layout },set: { layout in
                    var configuration = model.notchHaze; configuration.layout = layout; model.setNotchHaze(configuration)
                })) {
                    ForEach(NotchHazeLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!model.notchHaze.enabled)
                LabeledContent("Intensity") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.notchHaze.intensity) },set: { intensity in
                            var configuration = model.notchHaze; configuration.intensity = Float(intensity); model.setNotchHaze(configuration)
                        }),in: 0...1,step: 0.05)
                        Text(model.notchHaze.intensity,format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().frame(width: 42,alignment: .trailing)
                    }
                }
                .disabled(!model.notchHaze.enabled)
                Text("Soft moonlit mist behind notch apps at night. Layout sizing is manual, not linked to another app's expansion state. Movement freezes with pause or Reduce Motion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Widget rain") {
                HStack {
                    Button("Add widget") {
                        var areas = model.widgetRainAreas
                        var area = WidgetRainArea(); area.enabled = true
                        areas.append(area); model.setWidgetRainAreas(areas)
                        selectedWidget = areas.count-1; model.showsWidgetGuide = true
                    }.disabled(model.widgetRainAreas.count >= WidgetRainArea.maximumCount)
                    if !model.widgetRainAreas.isEmpty {
                        Button("Duplicate") {
                            var areas = model.widgetRainAreas
                            var area = selectedArea; area.x += 0.03; area.y += 0.03
                            areas.append(area.sanitized); model.setWidgetRainAreas(areas)
                            selectedWidget = areas.count-1
                        }.disabled(model.widgetRainAreas.count >= WidgetRainArea.maximumCount)
                        Button("Remove",role: .destructive) {
                            var areas = model.widgetRainAreas
                            areas.remove(at: selectedIndex); model.setWidgetRainAreas(areas)
                            selectedWidget = max(0,min(selectedWidget,areas.count-1))
                        }
                    }
                }
                if !model.widgetRainAreas.isEmpty {
                    Picker("Area",selection: $selectedWidget) {
                        ForEach(model.widgetRainAreas.indices,id: \.self) { index in
                            Text("Widget \(index+1)").tag(index)
                        }
                    }
                    Toggle("Bounce rain on this area",isOn: Binding(get: { selectedArea.enabled },set: { enabled in
                        var areas = model.widgetRainAreas
                        guard !areas.isEmpty else { return }
                        areas[selectedIndex].enabled = enabled; model.setWidgetRainAreas(areas)
                    }))
                    widgetNumberInput("X (px)", \.x, range: 0...widgetPixelWidth, scale: widgetPixelWidth)
                    widgetNumberInput("Y (px)", \.y, range: 0...widgetPixelHeight, scale: widgetPixelHeight)
                    widgetNumberInput("Width (px)", \.width, range: (widgetPixelWidth*0.02)...widgetPixelWidth, scale: widgetPixelWidth)
                    widgetNumberInput("Height (px)", \.height, range: (widgetPixelHeight*0.02)...widgetPixelHeight, scale: widgetPixelHeight)
                    widgetNumberInput("Corner radius (px)", \.cornerRadius, range: 0...(100*widgetPixelScale), scale: widgetPixelScale)
                    Toggle("Show placement outline",isOn: $model.showsWidgetGuide)
                }
                Text("Up to 24 manual areas shared across displays. Position/size are screen-relative, measured from the top-left. Apply a wallpaper and use the outlines to align each area. No automatic detection; rain effects remain behind desktop widgets.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Pixels refer to \(widgetReferenceScreen?.localizedName ?? "the primary display") (\(Int(widgetPixelWidth)) × \(Int(widgetPixelHeight)) backing pixels). X increases rightward; Y increases downward. Layouts scale proportionally on other displays.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Desktop") {
                LabeledContent("Displays", value: "All connected displays (\(model.displayCount))")
                Text("Weather is shared across displays. Your macOS wallpaper settings are never modified. Lock Screen and screen saver are not changed.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.wallpaperActive {
                    Button("Remove live wallpaper", role: .destructive, action: model.removeWallpaper)
                }
            }
            Section("Sources") {
                WeatherAttributionView(model: model)
                Link("Moon Imagery: NASA / LROC", destination: URL(string: "https://svs.gsfc.nasa.gov/4720/")!)
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .frame(width: 510, height: 650)
        .onDisappear { model.showsWidgetGuide = false }
        .alert("Weather Wallpaper", isPresented: Binding(
            get: { model.generalError != nil }, set: { if !$0 { model.generalError = nil } }
        )) { Button("OK") { model.generalError = nil } }
        message: { Text(model.generalError ?? "") }
    }

    private func widgetNumberInput(_ title: String,_ key: WritableKeyPath<WidgetRainArea,Float>,
                                   range: ClosedRange<Double>,scale: Double) -> some View {
        // Capture the area so a pending text-field commit cannot edit another
        // widget when the selection changes. Recreate field state on selection.
        let index = selectedIndex
        let value = Binding<Double>(get: {
            let areas = model.widgetRainAreas
            return areas.indices.contains(index) ? Double(areas[index][keyPath: key])*scale : range.lowerBound
        },set: { value in
            var areas = model.widgetRainAreas
            guard value.isFinite, areas.indices.contains(index) else { return }
            areas[index][keyPath: key] = Float(min(range.upperBound,max(range.lowerBound,value))/scale)
            model.setWidgetRainAreas(areas)
        })
        return LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title,value: value,format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Stepper(title,value: value,in: range,step: 1)
                    .labelsHidden()
                    .fixedSize()
            }
        }
        .id("\(index)-\(title)-\(scale)")
    }

    // Use one stable reference display, not whichever screen currently hosts
    // Settings. Storage stays normalized, and radius stays in logical points.
    private var widgetReferenceScreen: NSScreen? { NSScreen.screens.first }
    private var widgetPixelScale: Double { Double(widgetReferenceScreen?.backingScaleFactor ?? 1) }
    private var widgetPixelWidth: Double { Double(widgetReferenceScreen?.frame.width ?? 1920)*widgetPixelScale }
    private var widgetPixelHeight: Double { Double(widgetReferenceScreen?.frame.height ?? 1080)*widgetPixelScale }

    private var selectedIndex: Int { max(0,min(selectedWidget,model.widgetRainAreas.count-1)) }
    private var selectedArea: WidgetRainArea {
        model.widgetRainAreas.isEmpty ? WidgetRainArea() : model.widgetRainAreas[selectedIndex]
    }
}
