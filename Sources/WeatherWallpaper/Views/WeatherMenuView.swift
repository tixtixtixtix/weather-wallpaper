import AppKit
import SwiftUI
import WeatherCore

struct WeatherMenuLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.snapshot?.symbolName ?? "cloud.sun")
            if let snapshot = model.snapshot {
                Text(Measurement(value: snapshot.temperatureCelsius, unit: UnitTemperature.celsius),
                     format: .measurement(width: .narrow, usage: .weather,
                                          numberFormatStyle: .number.precision(.fractionLength(0))))
                    .monospacedDigit()
                if model.isStale { Image(systemName: "clock").imageScale(.small) }
            }
        }
        .accessibilityLabel(model.snapshot.map {
            "\(model.city?.name ?? "Weather"): \(WeatherFormatting.temperature($0.temperatureCelsius)), \($0.conditionDescription)\(model.isStale ? ", cached" : "")"
        } ?? "Weather Wallpaper")
    }
}

/// A lightweight native weather popover; shares the app's cache and refresh schedule.
/// No animated sky, location polling, or additional weather requests while open.
struct WeatherMenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var citySheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.city?.name ?? "Weather Wallpaper").font(.headline)
                    if let city = model.city {
                        Text(WeatherFormatting.time(model.now, zone: city.timeZone))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { citySheetPresented = true } label: {
                    Label("Change City", systemImage: "mappin.and.ellipse")
                }.labelStyle(.iconOnly).help("Change City")
                Button(action: model.refresh) {
                    Label(model.isFetching ? "Updating Weather…" : "Refresh Weather", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly).help("Refresh Weather")
                .disabled(model.city == nil || model.isFetching)
            }
            if let snapshot = model.snapshot {
                conditions(snapshot)
                if !model.upcomingHours.isEmpty {
                    Divider()
                    hourlyForecast
                }
                HStack {
                    Text(model.isStale ? "Cached · Updated \(WeatherFormatting.time(snapshot.fetchedAt, zone: model.city?.timeZone ?? .gmt))"
                         : "Updated \(WeatherFormatting.time(snapshot.fetchedAt, zone: model.city?.timeZone ?? .gmt))")
                    Spacer()
                    Link(snapshot.effectiveProvider.name, destination: snapshot.effectiveProvider.attributionURL)
                }.font(.caption2).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView {
                    Label(model.isFetching ? "Updating Weather" : (model.city == nil ? "Choose a City" : "Weather Unavailable"), systemImage: "cloud.sun")
                } description: {
                    Text("Current conditions and hourly forecasts, right in your menu bar.")
                } actions: {
                    if model.city != nil { Button("Retry", action: model.refresh).disabled(model.isFetching) }
                    Button("Choose City…") { citySheetPresented = true }
                }
            }
            if let issue = model.weatherIssue {
                Label(issue.title, systemImage: issue == .offline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Animate Wallpaper", isOn: Binding(get: { model.preferences.animationsEnabled }, set: model.setAnimations))
                .toggleStyle(.switch).controlSize(.small)
            HStack {
                Button("Show Weather Wallpaper") { WindowPresenceController.showMainWindow(using: openWindow) }
                    .keyboardShortcut("0")
                Spacer()
                Menu {
                    Button("Use Live Weather") {
                        model.previewKind = nil
                        if model.canApplyLive { model.applyWallpaper() }
                        else { citySheetPresented = true }
                    }
                    if model.wallpaperActive {
                        Button("Remove Wallpaper", action: model.removeWallpaper)
                    } else {
                        Button("Resume Wallpaper", action: model.resumeWallpaper)
                            .disabled(model.preferences.wallpaperSource == .live && !model.canApplyLive)
                    }
                    SettingsLink { Text("Settings…") }
                    Divider()
                    Button("Quit Weather Wallpaper") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Label("App Controls", systemImage: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .buttonStyle(.borderless)
        .padding(16)
        .frame(width: 360)
        .sheet(isPresented: $citySheetPresented) { CitySearchSheet { model.selectCity($0) } }
    }

    private func conditions(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WeatherFormatting.temperature(snapshot.temperatureCelsius))
                        .font(.system(size: 42, weight: .light)).monospacedDigit()
                    Text(snapshot.conditionDescription).font(.callout)
                }
                Spacer()
                Image(systemName: snapshot.symbolName)
                    .symbolRenderingMode(.multicolor).font(.system(size: 42))
                    .accessibilityHidden(true)
            }
            HStack {
                Label(Measurement(value: snapshot.windMetersPerSecond * 3.6, unit: UnitSpeed.kilometersPerHour)
                    .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0)))),
                      systemImage: "wind")
                Spacer()
                Label("\(snapshot.precipitationMillimetersPerHour.formatted(.number.precision(.fractionLength(0...1)))) mm/h", systemImage: "drop")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hourlyForecast: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Next Hours").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(model.upcomingHours.prefix(6)), id: \.date) { hour in
                    VStack(spacing: 8) {
                        Text(WeatherFormatting.hour(hour.date, zone: model.city?.timeZone ?? .gmt))
                            .font(.caption2).foregroundStyle(.secondary)
                        Image(systemName: hour.symbolName ?? hour.kind.symbol).symbolRenderingMode(.multicolor)
                            .frame(height: 18).accessibilityLabel(hour.kind.title)
                        Text(WeatherFormatting.temperature(hour.temperatureCelsius)).font(.callout).monospacedDigit()
                        Text(hour.precipitationChance, format: .percent.precision(.fractionLength(0)))
                            .font(.caption2).foregroundStyle(hour.precipitationChance >= 0.3 ? .blue : .secondary)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }
}
