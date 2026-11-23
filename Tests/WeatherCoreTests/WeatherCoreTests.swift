import XCTest
@testable import WeatherCore

final class WeatherCoreTests: XCTestCase {
    private let city = City(name: "London", region: "UK", latitude: 51.5074, longitude: -0.1278,
                            timeZoneIdentifier: "Europe/London")

    func testLegacyCacheIsNotMisattributedToNewProvider() throws {
        let value = snapshot(at: Date(), expires: Date())
        let decoded = try JSONDecoder().decode(WeatherSnapshot.self, from: JSONEncoder().encode(value))
        XCTAssertNil(decoded.provider)
        XCTAssertEqual(decoded.effectiveProvider, .appleWeather)
        XCTAssertEqual(WeatherCode(999).kind, .partlyCloudy)
        XCTAssertEqual(WeatherProvider.openMeteo.name, "Open-Meteo")
    }

    func testSolarDayAndNightAreIndependentOfSystemTimeZone() {
        let noon = date("2026-06-21T12:00:00Z")
        XCTAssertGreaterThan(SolarCalculator.state(at: noon, latitude: 51.5, longitude: 0).daylight, 0.99)
        XCTAssertLessThan(SolarCalculator.state(at: date("2026-06-21T00:00:00Z"), latitude: 51.5, longitude: 0).daylight, 0.01)
        XCTAssertLessThan(SolarCalculator.state(at: noon, latitude: -36.8, longitude: 174.7).daylight, 0.01)
    }

    func testPolarDayNightAndDateLine() {
        XCTAssertGreaterThan(SolarCalculator.state(at: date("2026-06-21T00:00:00Z"), latitude: 80, longitude: 0).daylight, 0.99)
        XCTAssertLessThan(SolarCalculator.state(at: date("2026-12-21T12:00:00Z"), latitude: 80, longitude: 0).daylight, 0.01)
        let a = SolarCalculator.state(at: date("2026-03-20T18:00:00Z"), latitude: 0, longitude: 180)
        let b = SolarCalculator.state(at: date("2026-03-20T18:00:00Z"), latitude: 0, longitude: -180)
        XCTAssertEqual(a.daylight, b.daylight, accuracy: 0.0001)
    }

    func testRetargetingTransitionDoesNotJump() {
        let a = SceneState.preview(kind: .clear, time: .day)
        let b = SceneState.preview(kind: .rain, time: .night)
        var transition = SceneTransition(scene: a, duration: 6)
        transition.setTarget(b, at: 0)
        XCTAssertEqual(transition.value(at: 0), a)
        XCTAssertEqual(transition.value(at: 6), b)
        let midpoint = transition.value(at: 3)
        XCTAssertEqual(midpoint.rain, b.rain / 2, accuracy: 0.0001)
        transition.setTarget(.preview(kind: .snow, time: .dawn), at: 3)
        XCTAssertEqual(transition.value(at: 3), midpoint)
    }

    func testRefreshBoundsAndBackoff() {
        let now = Date()
        let expired = snapshot(at: now, expires: now.addingTimeInterval(-10))
        XCTAssertEqual(RefreshPolicy.nextRefresh(after: expired), now.addingTimeInterval(900))
        let longLived = snapshot(at: now, expires: now.addingTimeInterval(7200))
        XCTAssertEqual(RefreshPolicy.nextRefresh(after: longLived), now.addingTimeInterval(1800))
        XCTAssertEqual(RefreshPolicy.retryDelay(failureCount: 1), 60)
        XCTAssertEqual(RefreshPolicy.retryDelay(failureCount: 2), 120)
        XCTAssertEqual(RefreshPolicy.retryDelay(failureCount: 1000), 1800)
    }

    func testCacheRoundTripAndStaleness() throws {
        let now = Date()
        let value = snapshot(at: now, expires: now.addingTimeInterval(900))
        let decoded = try JSONDecoder().decode(WeatherSnapshot.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value, decoded)
        XCTAssertFalse(decoded.isStale(at: now))
        XCTAssertTrue(decoded.isStale(at: now.addingTimeInterval(901)))
        XCTAssertEqual(try JSONDecoder().decode(City.self, from: JSONEncoder().encode(city)), city)
    }

    func testNoInventedRainAndInputsAreClamped() {
        let value = snapshot(at: Date(), expires: Date(), cloudCover: 3, precipitation: 0)
        let scene = SceneState.live(snapshot: value, city: city, at: Date())
        XCTAssertEqual(scene.rain, 0)
        XCTAssertEqual(scene.cloud, 1)
        XCTAssertTrue(scene.solar.daylight.isFinite)
    }

    func testCloudBanksThickenContinuouslyWithRainAndThunderstorms() {
        var scene = SceneState.preview(kind: .partlyCloudy, time: .day)
        let dry = CloudAppearance(scene: scene)
        scene.rain = 0.25
        let light = CloudAppearance(scene: scene)
        scene.rain = 0.9
        let heavy = CloudAppearance(scene: scene)
        scene.storm = 1
        let thunder = CloudAppearance(scene: scene)
        XCTAssertLessThan(dry.coverage, light.coverage)
        XCTAssertLessThan(light.coverage, heavy.coverage)
        XCTAssertLessThan(heavy.coverage, thunder.coverage)
        XCTAssertLessThan(dry.opticalDepth, light.opticalDepth)
        XCTAssertLessThan(light.opticalDepth, heavy.opticalDepth)
        XCTAssertLessThan(heavy.opticalDepth, thunder.opticalDepth)
        XCTAssertEqual(dry.cirrus, 0, "Unknown high layers must not manufacture cirrus")
        XCTAssertEqual(thunder.cirrus, 0)
        XCTAssertEqual(scene.cloud, 0.44, "Reported cover must not be overwritten by artistic density")

        var transition = SceneTransition(scene: .preview(kind: .clear, time: .day))
        transition.setTarget(scene, at: 0)
        let before = CloudAppearance(scene: transition.value(at: 2.99))
        let after = CloudAppearance(scene: transition.value(at: 3.01))
        XCTAssertLessThan(abs(after.opticalDepth - before.opticalDepth), 0.05)
    }

    func testDryThunderstormCanHaveDenseCloudsWithoutInventedRain() {
        var scene = SceneState.preview(kind: .thunderstorm, time: .day)
        scene.cloud = 0.5
        scene.rain = 0
        let appearance = CloudAppearance(scene: scene)
        XCTAssertGreaterThan(appearance.coverage, 0.9)
        XCTAssertGreaterThan(appearance.opticalDepth, 3)
        XCTAssertEqual(scene.rain, 0)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func snapshot(at now: Date, expires: Date, cloudCover: Double = 0.8,
                          precipitation: Double = 3) -> WeatherSnapshot {
        WeatherSnapshot(cityID: city.id, observedAt: now, fetchedAt: now, expiresAt: expires,
                        kind: .rain, conditionDescription: "Rain", symbolName: "cloud.rain.fill",
                        temperatureCelsius: 12, cloudCover: cloudCover,
                        precipitationMillimetersPerHour: precipitation, windMetersPerSecond: 4,
                        windDirectionDegrees: 220, visibilityMeters: 10000)
    }
}
