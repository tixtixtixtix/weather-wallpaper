import Foundation

public struct City: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(latitude),\(longitude)" }
    public let name: String
    public let region: String
    public let latitude: Double
    public let longitude: Double
    public let timeZoneIdentifier: String

    public init(name: String, region: String, latitude: Double, longitude: Double, timeZoneIdentifier: String) {
        self.name = name
        self.region = region
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .gmt }
}

public enum WeatherKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case clear, partlyCloudy, cloudy, rain, snow, sleet, thunderstorm, fog, windy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clear: "Clear"
        case .partlyCloudy: "Partly Cloudy"
        case .cloudy: "Overcast"
        case .rain: "Rain"
        case .snow: "Snow"
        case .sleet: "Wintry Mix"
        case .thunderstorm: "Thunderstorms"
        case .fog: "Fog"
        case .windy: "Wind"
        }
    }

    public var symbol: String {
        switch self {
        case .clear: "sun.max.fill"
        case .partlyCloudy: "cloud.sun.fill"
        case .cloudy: "cloud.fill"
        case .rain: "cloud.rain.fill"
        case .snow: "cloud.snow.fill"
        case .sleet: "cloud.sleet.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        case .fog: "cloud.fog.fill"
        case .windy: "wind"
        }
    }

}

public struct HourlyOutlook: Codable, Equatable, Sendable {
    public let date: Date
    public let kind: WeatherKind
    public let symbolName: String?
    public let temperatureCelsius: Double
    public let precipitationChance: Double

    public init(date: Date, kind: WeatherKind, symbolName: String? = nil,
                temperatureCelsius: Double, precipitationChance: Double) {
        self.date = date
        self.kind = kind
        self.symbolName = symbolName
        self.temperatureCelsius = temperatureCelsius
        self.precipitationChance = precipitationChance
    }
}

public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public let cityID: String
    public let observedAt: Date
    public let fetchedAt: Date
    public let expiresAt: Date
    public let kind: WeatherKind
    public let conditionDescription: String
    public let symbolName: String
    public let temperatureCelsius: Double
    public let cloudCover: Double
    public let precipitationMillimetersPerHour: Double
    public let windMetersPerSecond: Double
    public let windDirectionDegrees: Double
    public let visibilityMeters: Double
    public let hourly: [HourlyOutlook]
    /// Nil identifies caches written by the original Apple Weather implementation.
    public let provider: WeatherProvider?
    public let cloudLayers: CloudLayerCoverage?
    public let weatherCode: Int?
    public var effectiveProvider: WeatherProvider { provider ?? .appleWeather }

    public init(cityID: String, observedAt: Date, fetchedAt: Date, expiresAt: Date,
                kind: WeatherKind, conditionDescription: String, symbolName: String,
                temperatureCelsius: Double, cloudCover: Double,
                precipitationMillimetersPerHour: Double, windMetersPerSecond: Double,
                windDirectionDegrees: Double, visibilityMeters: Double, hourly: [HourlyOutlook] = [],
                provider: WeatherProvider? = nil, cloudLayers: CloudLayerCoverage? = nil, weatherCode: Int? = nil) {
        self.cityID = cityID
        self.observedAt = observedAt
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.kind = kind
        self.conditionDescription = conditionDescription
        self.symbolName = symbolName
        self.temperatureCelsius = temperatureCelsius
        self.cloudCover = cloudCover
        self.precipitationMillimetersPerHour = precipitationMillimetersPerHour
        self.windMetersPerSecond = windMetersPerSecond
        self.windDirectionDegrees = windDirectionDegrees
        self.visibilityMeters = visibilityMeters
        self.hourly = hourly
        self.provider = provider
        self.cloudLayers = cloudLayers
        self.weatherCode = weatherCode
    }

    public func isStale(at date: Date) -> Bool {
        date >= expiresAt || date.timeIntervalSince(observedAt) > 90 * 60
    }
}

public enum RefreshPolicy {
    /// Never poll faster than 15 minutes; don't leave a valid observation unrefreshed for over 30.
    public static func nextRefresh(after snapshot: WeatherSnapshot) -> Date {
        min(max(snapshot.expiresAt, snapshot.fetchedAt.addingTimeInterval(15 * 60)),
            snapshot.fetchedAt.addingTimeInterval(30 * 60))
    }

    public static func retryDelay(failureCount: Int) -> TimeInterval {
        min(30 * 60, 60 * pow(2, Double(max(0, min(failureCount - 1, 5)))))
    }
}
