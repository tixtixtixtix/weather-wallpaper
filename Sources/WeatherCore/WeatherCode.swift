import Foundation

/// WMO interpretation codes returned by Open-Meteo. Current conditions are model-derived,
/// not a claim that a weather station has observed the exact sky above the selected city.
public struct WeatherCode: Equatable, Sendable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public var kind: WeatherKind {
        switch value {
        case 0, 1: .clear
        case 2: .partlyCloudy
        case 3: .cloudy
        case 45, 48: .fog
        case 51, 53, 55, 61, 63, 65, 80, 81, 82: .rain
        case 56, 57, 66, 67: .sleet
        case 71, 73, 75, 77, 85, 86: .snow
        case 95, 96, 97, 99: .thunderstorm
        default: .partlyCloudy
        }
    }
    public var description: String {
        switch value {
        case 0: "Clear"
        case 1: "Mostly Clear"
        case 2: "Partly Cloudy"
        case 3: "Overcast"
        case 45: "Fog"
        case 48: "Freezing Fog"
        case 51: "Light Drizzle"
        case 53, 55: "Drizzle"
        case 56, 57: "Freezing Drizzle"
        case 61: "Light Rain"
        case 63: "Rain"
        case 65: "Heavy Rain"
        case 66, 67: "Freezing Rain"
        case 71: "Light Snow"
        case 73: "Snow"
        case 75: "Heavy Snow"
        case 77: "Snow Grains"
        case 80, 81: "Rain Showers"
        case 82: "Heavy Rain Showers"
        case 85, 86: "Snow Showers"
        case 95: "Thunderstorms"
        case 97: "Heavy Thunderstorms"
        case 96, 99: "Thunderstorms with Hail"
        default: "Weather Conditions"
        }
    }
    public func symbol(isDaylight: Bool) -> String {
        if !isDaylight {
            if kind == .clear { return "moon.stars.fill" }
            if kind == .partlyCloudy { return "cloud.moon.fill" }
        }
        return kind.symbol
    }
}

public enum WeatherProvider: String, Codable, Sendable {
    case appleWeather, openMeteo
    public var name: String { self == .openMeteo ? "Open-Meteo" : "Apple Weather (Cached)" }
    public var attributionURL: URL {
        URL(string: self == .openMeteo ? "https://open-meteo.com/" : "https://weatherkit.apple.com/legal-attribution.html")!
    }
}
