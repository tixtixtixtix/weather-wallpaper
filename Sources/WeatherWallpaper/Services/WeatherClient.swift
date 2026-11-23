import Foundation
import WeatherCore

/// Open-Meteo's public, keyless endpoint for eligible non-commercial use.
/// Data: CC BY 4.0. Commercial distribution must use an appropriately licensed endpoint.
@MainActor
final class WeatherClient {
    private let session: URLSession
    private var unsupportedLayerCities: Set<String> = []
    init(session: URLSession = .shared) { self.session = session }

    static func requestURL(for city: City, includeCloudLayers: Bool = true) throws -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let layers = includeCloudLayers ? ",cloud_cover_low,cloud_cover_mid,cloud_cover_high" : ""
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(city.latitude)),
            URLQueryItem(name: "longitude", value: String(city.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,precipitation,weather_code,cloud_cover,wind_speed_10m,wind_direction_10m,visibility,is_day" + layers),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day" + layers),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "precipitation_unit", value: "mm"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "forecast_hours", value: "7"),
            URLQueryItem(name: "past_hours", value: "1")
        ]
        guard let url = components.url else { throw WeatherFailure.invalidResponse }
        return url
    }

    func fetch(for city: City) async throws -> WeatherSnapshot {
        try await fetch(for: city, includeCloudLayers: !unsupportedLayerCities.contains(city.id))
    }

    private func fetch(for city: City, includeCloudLayers: Bool) async throws -> WeatherSnapshot {
        var request = URLRequest(url: try Self.requestURL(for: city, includeCloudLayers: includeCloudLayers))
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw WeatherFailure.invalidResponse }
        if response.statusCode == 400 && includeCloudLayers && Self.isUnsupportedCloudLayerResponse(data) {
            // Specialist fields must never prevent the core weather request from succeeding.
            unsupportedLayerCities.insert(city.id)
            return try await fetch(for: city, includeCloudLayers: false)
        }
        guard (200..<300).contains(response.statusCode) else { throw WeatherFailure.http(response.statusCode) }
        return try Self.decode(data, for: city, fetchedAt: Date())
    }

    static func isUnsupportedCloudLayerResponse(_ data: Data) -> Bool {
        struct APIError: Decodable { let reason: String }
        guard let error = try? JSONDecoder().decode(APIError.self, from: data) else { return false }
        return ["cloud_cover_low", "cloud_cover_mid", "cloud_cover_high"].contains { error.reason.contains($0) }
    }

    static func decode(_ data: Data, for city: City, fetchedAt now: Date) throws -> WeatherSnapshot {
        let response = try JSONDecoder().decode(ForecastResponse.self, from: data)
        let current = response.current
        let hours = response.hourly
        guard (60...3600).contains(current.interval), current.temperature_2m.isFinite,
              hours.time.count == hours.temperature_2m.count,
              hours.time.count == hours.weather_code.count,
              hours.time.count == hours.precipitation_probability.count,
              hours.time.count == hours.is_day.count else { throw WeatherFailure.invalidResponse }
        let code = WeatherCode(current.weather_code)
        let layerResponse = try? JSONDecoder().decode(OptionalLayerResponse.self, from: data)
        let currentDate = Date(timeIntervalSince1970: current.time)
        var cloudLayers = layerResponse?.current.coverage(at: currentDate)
        if cloudLayers == nil, let hourly = layerResponse?.hourly {
            // Only an hour at/before the current condition's valid time may describe its sky.
            for i in hours.time.indices.reversed() where hours.time[i] <= current.time && current.time - hours.time[i] <= 3600 {
                if let value = hourly.coverage(at: Date(timeIntervalSince1970: hours.time[i]), index: i) {
                    cloudLayers = value; break
                }
            }
        }
        var outlook: [HourlyOutlook] = []
        for i in hours.time.indices where outlook.count < 6 {
            let date = Date(timeIntervalSince1970: hours.time[i])
            guard date > now, let temperature = hours.temperature_2m[i],
                  let rawCode = hours.weather_code[i] else { continue }
            let condition = WeatherCode(rawCode)
            outlook.append(HourlyOutlook(date: date, kind: condition.kind,
                symbolName: condition.symbol(isDaylight: hours.is_day[i] != 0),
                temperatureCelsius: temperature,
                precipitationChance: max(0, min(1, (hours.precipitation_probability[i] ?? 0) / 100))))
        }
        return WeatherSnapshot(
            cityID: city.id, observedAt: Date(timeIntervalSince1970: current.time), fetchedAt: now,
            expiresAt: now.addingTimeInterval(15 * 60), kind: code.kind,
            conditionDescription: code.description, symbolName: code.symbol(isDaylight: current.is_day != 0),
            temperatureCelsius: current.temperature_2m, cloudCover: max(0, min(1, current.cloud_cover / 100)),
            // Current sums cover `interval` seconds (usually 900), not a full hour.
            precipitationMillimetersPerHour: max(0, current.precipitation) * 3600 / Double(current.interval),
            windMetersPerSecond: max(0, current.wind_speed_10m), windDirectionDegrees: current.wind_direction_10m,
            visibilityMeters: max(0, current.visibility ?? (code.kind == .fog ? 1000 : 10_000)),
            hourly: outlook, provider: .openMeteo, cloudLayers: cloudLayers, weatherCode: current.weather_code
        )
    }
}

/// Lossy, optional specialist decoding: malformed layer values do not discard valid weather.
private struct OptionalLayerResponse: Decodable {
    let current: LayerValues
    let hourly: LayerHours
    private enum Keys: String, CodingKey { case cloud_cover_low, cloud_cover_mid, cloud_cover_high }

    struct LayerValues: Decodable {
        let low: Double?, middle: Double?, high: Double?
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Keys.self)
            low = try? fields.decode(Double.self, forKey: .cloud_cover_low)
            middle = try? fields.decode(Double.self, forKey: .cloud_cover_mid)
            high = try? fields.decode(Double.self, forKey: .cloud_cover_high)
        }
        func coverage(at date: Date) -> CloudLayerCoverage? {
            let value = CloudLayerCoverage(validAt: date, low: low.map { $0 / 100 }, middle: middle.map { $0 / 100 }, high: high.map { $0 / 100 })
            return value.hasKnownLayer ? value : nil
        }
    }
    struct LayerHours: Decodable {
        let low: [Double?]?, middle: [Double?]?, high: [Double?]?
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Keys.self)
            low = try? fields.decode([Double?].self, forKey: .cloud_cover_low)
            middle = try? fields.decode([Double?].self, forKey: .cloud_cover_mid)
            high = try? fields.decode([Double?].self, forKey: .cloud_cover_high)
        }
        func coverage(at date: Date, index: Int) -> CloudLayerCoverage? {
            func fraction(_ values: [Double?]?) -> Double? {
                guard let values, values.indices.contains(index), let value = values[index] else { return nil }
                return value / 100
            }
            let value = CloudLayerCoverage(validAt: date, low: fraction(low), middle: fraction(middle), high: fraction(high))
            return value.hasKnownLayer ? value : nil
        }
    }
}

private struct ForecastResponse: Decodable {
    let current: Current
    let hourly: Hourly
    struct Current: Decodable {
        let time: Double
        let interval: Int
        let temperature_2m: Double
        let precipitation: Double
        let weather_code: Int
        let cloud_cover: Double
        let wind_speed_10m: Double
        let wind_direction_10m: Double
        let visibility: Double?
        let is_day: Int
    }
    struct Hourly: Decodable {
        let time: [Double]
        let temperature_2m: [Double?]
        let precipitation_probability: [Double?]
        let weather_code: [Int?]
        let is_day: [Int?]
    }
}
