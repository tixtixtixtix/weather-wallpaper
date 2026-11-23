import SwiftUI
import WeatherCore

private enum WallpaperDestination: Hashable {
    case live
    case scene(WeatherKind)
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var citySheetPresented = false
    @State private var diagnosticsPresented = false
    @State private var inspectorPresented = false

    private var selection: Binding<WallpaperDestination?> {
        Binding(get: { model.previewKind.map(WallpaperDestination.scene) ?? .live }, set: { destination in
            guard let destination else { return }
            switch destination {
            case .live: model.previewKind = nil
            case let .scene(kind): model.previewKind = kind
            }
        })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    Label("Live Weather", systemImage: "cloud.sun")
                        .tag(WallpaperDestination.live)
                }
                Section("Scenes") {
                    ForEach(WeatherKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(WallpaperDestination.scene(kind))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 270)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.wallpaperActive ? (model.isPreviewWallpaper ? "Scene on Desktop" : "Live Weather on Desktop") : "Wallpaper Not Applied")
                        .font(.callout)
                    Text("\(model.displayCount) \(model.displayCount == 1 ? "display" : "displays")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        } detail: {
            preview
                .navigationTitle(model.isLivePreview ? (model.city?.name ?? "Live Weather") : (model.previewKind?.title ?? "Wallpaper"))
                .toolbar { toolbar }
                .inspector(isPresented: $inspectorPresented) { details }
        }
        .frame(minWidth: 800, minHeight: 560)
        .sheet(isPresented: $citySheetPresented) { CitySearchSheet { model.selectCity($0) } }
        .sheet(isPresented: $diagnosticsPresented) { WeatherDiagnosticsView(model: model) }
        .onAppear {
            let action = openWindow
            model.showMainWindow = { WindowPresenceController.showMainWindow(using: action) }
        }
    }

    private var preview: some View {
        ZStack {
            SkyView(environment: model.previewEnvironment, onError: model.reportRendererError)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            if model.isLivePreview && model.city == nil {
                ContentUnavailableView {
                    Label("Choose a City", systemImage: "globe")
                } description: {
                    Text("Use a city's current weather for your desktop. Your location is never tracked.")
                } actions: {
                    Button("Choose City…") { citySheetPresented = true }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            } else {
                VStack(spacing: 8) {
                    Text(model.isLivePreview ? (model.city?.name ?? "") : (model.previewKind?.title ?? ""))
                        .font(.system(size: 28, weight: .regular)).accessibilityAddTraits(.isHeader)
                    if model.isLivePreview, let snapshot = model.snapshot {
                        Text(WeatherFormatting.temperature(snapshot.temperatureCelsius))
                            .font(.system(size: 84, weight: .thin)).monospacedDigit()
                        Text(snapshot.conditionDescription).font(.title3)
                        if model.isStale { Label("Last Known Weather", systemImage: "clock").font(.callout) }
                    } else if model.isLivePreview {
                        Text(model.isFetching ? "Updating Weather…" : "Weather Unavailable").font(.callout)
                    } else {
                        Text("\(model.previewTime.title) · Scene Preview").font(.callout)
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
                .padding(.top, 40).padding(.horizontal)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if !model.isLivePreview {
                    Picker("Time of Day", selection: $model.previewTime) {
                        ForEach(PreviewTime.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 360)
                    .help("Scene previews use illustrative sun and moon positions, not live ephemerides")
                    Picker("Cloud Shape", selection: $model.previewCloudGenus) {
                        Text("Automatic").tag(Optional<CloudGenus>.none)
                        ForEach(CloudGenus.eligiblePreviews(for: model.previewKind ?? .partlyCloudy)) { genus in
                            Text(genus.title).tag(Optional(genus))
                        }
                    }
                    .frame(maxWidth: 360)
                    .help("All ten researched families are available; only kinds compatible with this scene are listed")
                    developmentPicker.frame(maxWidth: 360)
                }
                if model.isLivePreview, let issue = model.weatherIssue {
                    HStack(alignment: .center, spacing: 12) {
                        Label(issue.title, systemImage: issue == .offline ? "network.slash" : "exclamationmark.triangle")
                            .font(.callout)
                        Spacer()
                        Button("Details…") { diagnosticsPresented = true }
                        Button("Retry", action: model.refresh).disabled(model.isFetching)
                    }
                }
                if let error = model.rendererError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                }
                HStack {
                    if model.isLivePreview {
                        Button { citySheetPresented = true } label: {
                            Label(model.city == nil ? "Choose City…" : "Change City…", systemImage: "mappin.and.ellipse")
                        }
                    } else {
                        Text("Preview scenes don't represent current weather.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isFetching { ProgressView().controlSize(.small) }
                    Label(model.powerDescription, systemImage: "leaf").font(.caption).foregroundStyle(.secondary)
                }
                if model.isLivePreview && model.snapshot != nil { WeatherAttributionView(model: model) }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var developmentPicker: some View {
        let options = CloudDevelopment.eligiblePreviews(for: model.previewKind ?? .clear)
        if !options.isEmpty {
            Picker("Cloud Development", selection: $model.previewCloudDevelopment) {
                Text("Standard").tag(Optional<CloudDevelopment>.none)
                ForEach(options) { Text($0.title).tag(Optional($0)) }
            }
            .help("Adds illustrative developing towers behind the scene’s ordinary clouds. Selecting a named cloud shape returns to standard development.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.isLivePreview {
                Button(action: model.refresh) { Label("Refresh Weather", systemImage: "arrow.clockwise") }
                    .disabled(model.city == nil || model.isFetching)
                    .help("Refresh Weather")
            }
            Button { model.setAnimations(!model.preferences.animationsEnabled) } label: {
                Label(model.preferences.animationsEnabled ? "Pause Animation" : "Resume Animation",
                      systemImage: model.preferences.animationsEnabled ? "pause" : "play")
            }
            .help(model.preferences.animationsEnabled ? "Pause Animation" : "Resume Animation")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(model.isLivePreview ? "Apply Live Weather" : "Apply Scene", action: model.applyWallpaper)
                .disabled((model.isLivePreview && !model.canApplyLive) || model.rendererError != nil)
                .help("Apply to all displays. Your original wallpaper is not changed.")
        }
        ToolbarItemGroup {
            Menu {
                if model.wallpaperActive { Button("Remove Wallpaper", action: model.removeWallpaper) }
                Button("Weather Diagnostics…") { diagnosticsPresented = true }
                SettingsLink()
            } label: { Label("More", systemImage: "ellipsis") }
            Button { inspectorPresented.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .help("Show Details")
        }
    }

    private var details: some View {
        Form {
            Section("Clouds") {
                if !model.isLivePreview {
                    Picker("Cloud Shape", selection: $model.previewCloudGenus) {
                        Text("Automatic").tag(Optional<CloudGenus>.none)
                        ForEach(CloudGenus.eligiblePreviews(for: model.previewKind ?? .partlyCloudy)) { genus in
                            Text(genus.title).tag(Optional(genus))
                        }
                    }
                    Text("Compatible shapes are offered for each scene. Raised Stratocumulus replaces the former cumulus look, keeping its thickness at a higher altitude. Named shapes are illustrative previews.")
                        .font(.caption).foregroundStyle(.secondary)
                    developmentPicker
                    Picker("Moon Phase", selection: $model.previewMoonPhase) {
                        ForEach(PreviewMoonPhase.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Live weather calculates the phase automatically. This control affects previews only.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Live mode uses modeled low/mid/high layers with generic compatible shapes — never a claimed genus observation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.isLivePreview {
                    LabeledContent("Coverage") {
                        Slider(value: $model.cloudCoverageBias, in: -0.3...0.3, step: 0.01)
                            .frame(maxWidth: 160)
                    }
                    LabeledContent("Ceiling shading") {
                        Slider(value: $model.cloudShade, in: 0...1, step: 0.01)
                            .frame(maxWidth: 160)
                    }
                    LabeledContent("High veil") {
                        Slider(value: $model.highCloudBias, in: -1...1, step: 0.01)
                            .frame(maxWidth: 160)
                    }
                    Text("Tuning adjusts Scene previews and applied scenes only — live weather uses its own data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Meteor speed") {
                    Slider(value: $model.meteorSpeed, in: 0.25...2.5, step: 0.05)
                        .frame(maxWidth: 160)
                }
                Toggle("Shooting stars", isOn: Binding(get: { model.preferences.meteorsEnabled ?? true }, set: model.setMeteors))
            }
            if !model.isLivePreview {
                Section("Preview Effects") {
                    Toggle("Meteor shower", isOn: $model.previewMeteors)
                    Text("Preview-only demo that switches the preview to a thin night sky. Live weather is never altered.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Wallpaper") {
                LabeledContent("Source", value: model.isLivePreview ? "Live Weather" : "Scene Preview")
                LabeledContent("Displays", value: "\(model.displayCount)")
                LabeledContent("Rendering", value: model.powerDescription)
            }
            if let city = model.city {
                Section("City") {
                    Text(city.name).font(.headline)
                    Text(city.region).foregroundStyle(.secondary)
                    LabeledContent("Local Time", value: WeatherFormatting.time(model.now, zone: city.timeZone))
                    Button("Change City…") { citySheetPresented = true }
                }
                if model.isLivePreview {
                    Section("Moon") {
                        let solar = model.previewEnvironment.scene(at: ProcessInfo.processInfo.systemUptime).solar
                        LabeledContent("Illuminated", value: Double(solar.moonIllumination).formatted(.percent.precision(.fractionLength(0))))
                        LabeledContent("Altitude", value: "\(Int(solar.moon.altitudeDegrees.rounded()))°")
                        LabeledContent("Azimuth", value: "\(Int(solar.moon.azimuthDegrees.rounded()))°")
                        Text(solar.moon.altitudeDegrees < 0 ? "Below the horizon in \(city.name)." : "Calculated for \(city.name); azimuth is measured clockwise from north.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let snapshot = model.snapshot {
                Section(model.isStale ? "Cached Weather" : "Current Weather") {
                    LabeledContent("Conditions", value: snapshot.conditionDescription)
                    LabeledContent("Temperature", value: WeatherFormatting.temperature(snapshot.temperatureCelsius))
                    LabeledContent("Valid At", value: WeatherFormatting.time(snapshot.observedAt, zone: model.city?.timeZone ?? .gmt))
                    Text(snapshot.effectiveProvider == .openMeteo ? "Model-derived conditions from Open-Meteo." : "Saved conditions from the previous provider.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let warning = model.cacheWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                }
                if model.isLivePreview {
                    Section("Cloud Layers") {
                        if let layers = snapshot.cloudLayers, layers.isUsable(at: model.now) {
                            LabeledContent("Low", value: layers.low.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Unknown")
                            LabeledContent("Middle", value: layers.middle.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Unknown")
                            LabeledContent("High", value: layers.high.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Unknown")
                            Text("Modeled layer fractions overlap. Shapes illustrate plausible conditions, not observed cloud genera.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Layer information is unavailable or stale. Using a conservative sky without invented high clouds.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.upcomingHours.isEmpty {
                    Section(model.isStale ? "Cached Forecast" : "Hourly Forecast") {
                        ForEach(model.upcomingHours, id: \.date) { hour in
                            HStack {
                                Text(WeatherFormatting.time(hour.date, zone: model.city?.timeZone ?? .gmt))
                                Spacer()
                                Image(systemName: hour.symbolName ?? hour.kind.symbol).symbolRenderingMode(.multicolor)
                                    .accessibilityLabel(hour.kind.title)
                                Text(WeatherFormatting.temperature(hour.temperatureCelsius)).monospacedDigit()
                                if hour.precipitationChance >= 0.1 {
                                    Text(hour.precipitationChance, format: .percent.precision(.fractionLength(0)))
                                        .foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                WeatherAttributionView(model: model)
                Link("Moon Imagery: NASA / LROC", destination: URL(string: "https://svs.gsfc.nasa.gov/4720/")!)
                Text("Lunar phase, orientation and position are calculated for the selected city. Preview scenes are illustrative.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 270, ideal: 310, max: 380)
    }
}

enum WeatherFormatting {
    static func temperature(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .weather,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }
    static func time(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = zone
        return date.formatted(style)
    }
    static func hour(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour()
        style.timeZone = zone
        return date.formatted(style)
    }
}

struct WeatherAttributionView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            let provider = model.snapshot?.effectiveProvider ?? .openMeteo
            Link("Weather: \(provider.name)", destination: provider.attributionURL)
            Spacer()
            Link(provider == .openMeteo ? "CC BY 4.0" : "Data Sources", destination: provider == .openMeteo
                 ? URL(string: "https://creativecommons.org/licenses/by/4.0/")! : provider.attributionURL)
        }.font(.caption)
    }
}
