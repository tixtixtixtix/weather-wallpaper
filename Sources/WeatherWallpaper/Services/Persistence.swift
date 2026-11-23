import Foundation
import WeatherCore

enum WallpaperSource: String, Codable {
    case live, preview
}

enum NotchHazeLayout: String, Codable, CaseIterable, Identifiable {
    case compact, expanded
    var id: Self { self }
    var title: String { self == .compact ? "Compact" : "Expanded" }
}

struct NotchHazeConfiguration: Codable, Equatable {
    var enabled = true
    var layout = NotchHazeLayout.expanded
    var intensity: Float = 0.75

    var sanitized: Self {
        var value = self
        value.intensity = intensity.isFinite ? min(1,max(0,intensity)) : 0.75
        return value
    }
}

/// Screen-relative manual layout, shared across displays.
struct WidgetRainArea: Codable, Equatable {
    static let maximumCount = 24
    var enabled = false
    var x: Float = 0.05
    var y: Float = 0.12
    var width: Float = 0.22
    var height: Float = 0.22
    var cornerRadius: Float = 24 // Logical screen points, not render pixels.

    var sanitized: WidgetRainArea {
        func clamp(_ value: Float,_ low: Float,_ high: Float,_ fallback: Float) -> Float {
            value.isFinite ? min(high,max(low,value)) : fallback
        }
        var area = self
        area.width = clamp(width,0.02,1,0.22); area.height = clamp(height,0.02,1,0.22)
        area.x = clamp(x,0,1-area.width,0); area.y = clamp(y,0,1-area.height,0)
        area.cornerRadius = clamp(cornerRadius,0,100,24)
        return area
    }
}

struct Preferences: Codable {
    var city: City?
    var wallpaperEnabled = false
    var wallpaperSource = WallpaperSource.live
    var appliedKind = WeatherKind.partlyCloudy
    var appliedTime = PreviewTime.day
    var efficientRendering = false
    var animationsEnabled = true
    // Optional storage keeps preferences written by the first version decodable.
    var lightningEnabled: Bool?
    var bloomEnabled: Bool?
    var appliedMoonPhase: PreviewMoonPhase?
    var appliedCloudGenus: CloudGenus?
    var appliedCloudDevelopment: CloudDevelopment?
    // Optional cloud tuning keeps older preferences decodable. Nil means default.
    var cloudCoverageBias: Float?
    var cloudShade: Float?
    var highCloudBias: Float?
    // Preview-only meteor demo. Nil means off. Live weather is never altered by it.
    var previewMeteors: Bool?
    // Global meteor fall speed multiplier. Nil means 1x.
    var meteorSpeed: Float?
    var meteorsEnabled: Bool?
    var widgetRainArea: WidgetRainArea?
    var widgetRainAreas: [WidgetRainArea]?
    // Missing on older preferences; use the default moonlit desktop haze.
    var notchHaze: NotchHazeConfiguration?

    // Read the original single-area preference without rewriting user settings.
    var resolvedWidgetRainAreas: [WidgetRainArea] {
        Array((widgetRainAreas ?? widgetRainArea.map { [$0] } ?? []).prefix(WidgetRainArea.maximumCount))
            .map(\.sanitized)
    }
}

enum Persistence {
    private static let preferencesKey = "WeatherWallpaper.preferences.v1"

    static func loadPreferences() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
              let preferences = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return preferences
    }

    static func save(_ preferences: Preferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.weatherwallpaper.mac", isDirectory: true)
            .appendingPathComponent("weather-v1.json")
    }

    static func loadSnapshot(for city: City?) -> WeatherSnapshot? {
        guard let city, let url = cacheURL, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WeatherSnapshot.self, from: data),
              snapshot.cityID == city.id else { return nil }
        return snapshot
    }

    static func save(_ snapshot: WeatherSnapshot) throws {
        guard let url = cacheURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
