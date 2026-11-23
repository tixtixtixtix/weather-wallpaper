import Foundation
import WeatherCore
import XCTest
@testable import WeatherWallpaper

final class WeatherClientTests: XCTestCase {
    private let city = City(name: "London", region: "UK", latitude: 51.5074, longitude: -0.1278,
                            timeZoneIdentifier: "Europe/London")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var fixture: Data {
        Data("""
        {"current":{"time":1799999700,"interval":900,"temperature_2m":12.4,"precipitation":0.75,
         "weather_code":63,"cloud_cover":85,"wind_speed_10m":4.2,"wind_direction_10m":240,
         "visibility":7000,"is_day":0},"hourly":{"time":[1800000000,1800003600,1800007200],
         "temperature_2m":[12,11,10],"precipitation_probability":[10,75,100],"weather_code":[63,2,0],"is_day":[0,0,1]}}
        """.utf8)
    }

    @MainActor
    func testProviderNeedsNoAccountAndUsesExplicitUnitsAndUTCTimestamps() throws {
        let url = try WeatherClient.requestURL(for: city)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertNil(query["apikey"])
        XCTAssertEqual(query["timeformat"], "unixtime")
        XCTAssertEqual(query["wind_speed_unit"], "ms")
        XCTAssertEqual(query["forecast_hours"], "7")
        XCTAssertEqual(query["past_hours"], "1")
        XCTAssertTrue(query["current"]?.contains("cloud_cover_high") == true)
        let fallback = try WeatherClient.requestURL(for: city, includeCloudLayers: false)
        XCTAssertFalse(fallback.absoluteString.contains("cloud_cover_high"))
    }

    @MainActor
    func testCurrentIntervalIsNormalizedToRainfallPerHour() throws {
        let value = try WeatherClient.decode(fixture, for: city, fetchedAt: now)
        XCTAssertEqual(value.provider, .openMeteo)
        XCTAssertEqual(value.kind, .rain)
        XCTAssertEqual(value.precipitationMillimetersPerHour, 3, accuracy: 0.0001)
        XCTAssertEqual(value.cloudCover, 0.85, accuracy: 0.0001)
        XCTAssertEqual(value.windMetersPerSecond, 4.2)
        XCTAssertEqual(value.expiresAt.timeIntervalSince(now), 900)
        XCTAssertEqual(value.hourly.count, 2)
        XCTAssertEqual(value.hourly[0].precipitationChance, 0.75)
        XCTAssertEqual(value.hourly[0].symbolName, "cloud.moon.fill")
        XCTAssertEqual(value.hourly[1].symbolName, "sun.max.fill")
    }

    @MainActor
    func testMalformedIntervalsAndMisalignedHourlyDataAreRejected() throws {
        let zeroInterval = String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "\"interval\":900", with: "\"interval\":0")
        XCTAssertThrowsError(try WeatherClient.decode(Data(zeroInterval.utf8), for: city, fetchedAt: now))
        let badArray = String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "[12,11,10]", with: "[12]")
        XCTAssertThrowsError(try WeatherClient.decode(Data(badArray.utf8), for: city, fetchedAt: now))
    }

    @MainActor
    func testCurrentCloudLayersRetainExplicitZeroAndUnknownValues() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var current = try XCTUnwrap(object["current"] as? [String: Any])
        current["cloud_cover_low"] = 0
        current["cloud_cover_mid"] = NSNull()
        current["cloud_cover_high"] = 80
        object["current"] = current
        let value = try WeatherClient.decode(JSONSerialization.data(withJSONObject: object),for: city,fetchedAt: now)
        XCTAssertEqual(value.cloudLayers?.low,0)
        XCTAssertNil(value.cloudLayers?.middle)
        XCTAssertEqual(value.cloudLayers?.high,0.8)
        XCTAssertEqual(value.cloudLayers?.validAt,value.observedAt)
        XCTAssertEqual(value.weatherCode,63)
    }

    @MainActor
    func testHourlyFallbackNeverUsesAFutureCloudLayer() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var hourly = try XCTUnwrap(object["hourly"] as? [String: Any])
        hourly["cloud_cover_low"] = [10,80,90]
        hourly["cloud_cover_mid"] = [20,80,90]
        hourly["cloud_cover_high"] = [70,80,90]
        object["hourly"] = hourly
        let futureOnly = try WeatherClient.decode(JSONSerialization.data(withJSONObject: object),for: city,fetchedAt: now)
        XCTAssertNil(futureOnly.cloudLayers)
        hourly["time"] = [now.timeIntervalSince1970 - 3600,now.timeIntervalSince1970,now.timeIntervalSince1970 + 3600]
        object["hourly"] = hourly
        let aligned = try WeatherClient.decode(JSONSerialization.data(withJSONObject: object),for: city,fetchedAt: now)
        XCTAssertEqual(aligned.cloudLayers?.low,0.1)
        XCTAssertEqual(aligned.cloudLayers?.middle,0.2)
        XCTAssertEqual(aligned.cloudLayers?.high,0.7)
        XCTAssertEqual(aligned.cloudLayers?.validAt,now.addingTimeInterval(-3600))
    }

    @MainActor
    func testMalformedSpecialistFieldsDoNotBreakTheBasicForecast() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var current = try XCTUnwrap(object["current"] as? [String: Any])
        current["cloud_cover_low"] = "unknown"
        current["cloud_cover_mid"] = -20
        current["cloud_cover_high"] = 300
        object["current"] = current
        let value = try WeatherClient.decode(JSONSerialization.data(withJSONObject: object),for: city,fetchedAt: now)
        XCTAssertNil(value.cloudLayers)
        XCTAssertEqual(value.temperatureCelsius,12.4)
        XCTAssertFalse(value.hourly.isEmpty)
        XCTAssertTrue(WeatherClient.isUnsupportedCloudLayerResponse(Data("{\"reason\":\"Invalid variable cloud_cover_high\"}".utf8)))
        XCTAssertFalse(WeatherClient.isUnsupportedCloudLayerResponse(Data("{\"reason\":\"Invalid latitude\"}".utf8)))
    }

    func testErrorsAndOldPreferencesRemainUsable() throws {
        XCTAssertEqual(WeatherFailure(error: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(WeatherFailure(error: WeatherFailure.http(429)), .http(429))
        let original = Data("""
        {"wallpaperEnabled":true,"wallpaperSource":"preview","appliedKind":"snow","appliedTime":"night",
         "efficientRendering":true,"animationsEnabled":false}
        """.utf8)
        let value = try JSONDecoder().decode(Preferences.self, from: original)
        XCTAssertEqual(value.appliedKind, .snow)
        XCTAssertTrue(value.wallpaperEnabled)
        XCTAssertTrue(value.efficientRendering)
        XCTAssertFalse(value.animationsEnabled)
        XCTAssertNil(value.appliedMoonPhase)
    }

    @MainActor
    func testLiveOpenMeteoWithoutCredentialsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_LIVE_WEATHER"] == "1" else {
            throw XCTSkip("Set WEATHER_WALLPAPER_LIVE_WEATHER=1 to make one real provider request")
        }
        let value = try await WeatherClient().fetch(for: city)
        XCTAssertEqual(value.provider, .openMeteo)
        XCTAssertEqual(value.cityID, city.id)
        XCTAssertFalse(value.hourly.isEmpty)
        XCTAssertLessThan(abs(value.observedAt.timeIntervalSinceNow), 3600)
        XCTAssertTrue(value.temperatureCelsius.isFinite)
        XCTAssertNotNil(value.cloudLayers, "The live provider should supply optional layer cover")
    }
}
