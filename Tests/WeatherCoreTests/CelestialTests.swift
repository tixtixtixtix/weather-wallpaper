import XCTest
@testable import WeatherCore

final class CelestialTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testDaytimeQuarterAgainstJPLHorizons() {
        // JPL Horizons DE441, airless topocentric Moon (301), London at sea level.
        // 2024-04-15T14:00Z: azimuth 93.370063°, altitude 36.695803°, illumination 48.49160%.
        let time = date("2024-04-15T14:00:00Z")
        let lunar = LunarCalculator.state(at: time, latitude: 51.5074, longitude: -0.1278)
        XCTAssertEqual(lunar.moon.altitudeDegrees, 36.6958, accuracy: 0.5)
        XCTAssertEqual(lunar.moon.azimuthDegrees, 93.3701, accuracy: 0.5)
        XCTAssertEqual(lunar.moon.position.x * 360, lunar.moon.azimuthDegrees, accuracy: 0.001)
        XCTAssertEqual(lunar.illumination, 0.484916, accuracy: 0.015)
        XCTAssertGreaterThan(lunar.moon.visibility, 0.99)
        XCTAssertGreaterThan(SolarCalculator.state(at: time, latitude: 51.5074, longitude: -0.1278).daylight, 0.99)
    }

    func testNewMoonAtDallasEclipseAgainstJPLHorizons() {
        // JPL Horizons DE441: 2024-04-08T18:40Z, Dallas, altitude 64.668255°, illumination 0.00000%.
        let lunar = LunarCalculator.state(at: date("2024-04-08T18:40:00Z"), latitude: 32.7767, longitude: -96.797)
        XCTAssertEqual(lunar.moon.altitudeDegrees, 64.6683, accuracy: 0.5)
        XCTAssertLessThan(lunar.illumination, 0.001)
        XCTAssertEqual(lunar.moon.visibility, 0, "An unilluminated new moon must not become a black daytime disk")
    }

    func testFullMoonAndBelowHorizonVisibility() {
        let time = date("2024-03-25T00:00:00Z")
        let london = LunarCalculator.state(at: time, latitude: 51.5074, longitude: -0.1278)
        XCTAssertGreaterThan(london.illumination, 0.99)
        XCTAssertGreaterThan(london.moon.visibility, 0.99)
        let opposite = LunarCalculator.state(at: time, latitude: -51.5074, longitude: 179.8722)
        XCTAssertLessThan(opposite.moon.altitudeDegrees, 0)
        XCTAssertEqual(opposite.moon.visibility, 0)
    }

    func testWaxingAndWaningLightOppositeLimbs() {
        XCTAssertGreaterThan(PreviewMoonPhase.firstQuarter.lightDirection.x, 0)
        XCTAssertLessThan(PreviewMoonPhase.lastQuarter.lightDirection.x, 0)
        XCTAssertEqual(PreviewMoonPhase.firstQuarter.illumination, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PreviewMoonPhase.lastQuarter.illumination, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PreviewMoonPhase.fullMoon.illumination, 1, accuracy: 0.0001)
        XCTAssertEqual(PreviewMoonPhase.newMoon.illumination, 0, accuracy: 0.0001)
    }

    func testSouthernHemisphereAndPolarCoordinatesStayFinite() {
        for lat in [-90.0, -33.9, 0, 51.5, 90] {
            let value = LunarCalculator.state(at: date("2026-11-08T12:00:00Z"), latitude: lat, longitude: 151.2)
            XCTAssertTrue(value.moon.rotation.isFinite)
            XCTAssertTrue(value.moon.altitudeDegrees.isFinite)
            XCTAssertTrue(value.moon.position.x.isFinite)
            let light = value.moon.lightDirection
            XCTAssertEqual(light.x * light.x + light.y * light.y + light.z * light.z, 1, accuracy: 0.001)
        }
    }

    func testLightningRespectsSuppressionAndDoesNotRunAsPeriodicStrobe() {
        var timeline = LightningTimeline()
        for t in stride(from: 0.0, to: 100.0, by: 0.1) {
            XCTAssertEqual(timeline.sample(at: t, storm: 1, enabled: false).intensity, 0)
        }
        var flashes = 0
        var lastOrigin: Float?
        for t in stride(from: 100.0, to: 250.0, by: 0.1) {
            let flash = timeline.sample(at: t, storm: 1, enabled: true)
            XCTAssertLessThanOrEqual(flash.intensity, 0.8)
            if flash.intensity > 0.01, lastOrigin != flash.origin { flashes += 1; lastOrigin = flash.origin }
        }
        XCTAssertGreaterThan(flashes, 1)
        XCTAssertLessThan(flashes, 12)
        XCTAssertEqual(timeline.sample(at: 251, storm: 0, enabled: true).intensity, 0)
    }

    func testFractalGeometryHasConnectedBranchesAndIsBoundedAndDeterministic() {
        let strike = LightningSample(origin: 0.55, seed: 42, intensity: 0.6, reach: 0.7)
        let segments = FractalLightning.segments(for: strike)
        XCTAssertGreaterThan(segments.count, FractalLightning.trunkSegmentCount)
        XCTAssertLessThanOrEqual(segments.count, FractalLightning.maximumSegments)
        XCTAssertEqual(segments, FractalLightning.segments(for: strike))
        XCTAssertNotEqual(segments, FractalLightning.segments(for: LightningSample(seed: 99)))
        for segment in segments {
            XCTAssertTrue(segment.start.x.isFinite && segment.end.y.isFinite)
            XCTAssertGreaterThan(segment.width, 0)
            XCTAssertLessThanOrEqual(segment.brightness, 1)
        }
        let trunkCount = FractalLightning.trunkSegmentCount
        XCTAssertLessThan(segments[trunkCount - 1].width, segments[0].width)
        let trunkVertices = Set(segments.prefix(trunkCount).flatMap { ["\($0.start.x),\($0.start.y)", "\($0.end.x),\($0.end.y)"] })
        XCTAssertTrue(trunkVertices.contains("\(segments[trunkCount].start.x),\(segments[trunkCount].start.y)"))
    }

    func testLightningHasALongReadableChannelDownToTheDockArea() throws {
        var timeline = LightningTimeline()
        _ = timeline.sample(at: 7, storm: 1, enabled: true)
        let strike = timeline.sample(at: 7.1, storm: 1, enabled: true)
        let trunk = FractalLightning.segments(for: strike).prefix(FractalLightning.trunkSegmentCount)
        let tip = try XCTUnwrap(trunk.last)
        XCTAssertGreaterThan(tip.end.y, 0.90)
        XCTAssertGreaterThan(tip.width, 0.001)
        XCTAssertLessThanOrEqual(FractalLightning.segments(for: strike).count, 96)
    }

    func testSolarInterpolationTakesShortPathAcrossNorthAndRotationSeams() {
        var start = SolarState.preview(.night)
        var end = start
        start.moon.position.x = 0.999
        end.moon.position.x = 0.001
        start.moon.rotation = .pi - 0.01
        end.moon.rotation = -.pi + 0.01
        let middle = SolarState.interpolate(from: start, to: end, progress: 0.5)
        XCTAssertLessThan(abs(middle.moon.position.x - 1), 0.001)
        XCTAssertLessThan(abs(middle.moon.rotation - .pi), 0.001)
        XCTAssertEqual(SolarState.interpolate(from: start, to: end, progress: 1), end)
    }

    func testAllOpenMeteoWMOCodesMapWithoutRequiringWeatherKit() {
        let groups: [(WeatherKind, [Int])] = [(.clear, [0, 1]), (.partlyCloudy, [2]), (.cloudy, [3]),
            (.fog, [45, 48]), (.rain, [51, 53, 55, 61, 63, 65, 80, 81, 82]),
            (.sleet, [56, 57, 66, 67]), (.snow, [71, 73, 75, 77, 85, 86]), (.thunderstorm, [95, 96, 97, 99])]
        for (kind, codes) in groups { for code in codes { XCTAssertEqual(WeatherCode(code).kind, kind) } }
        XCTAssertEqual(WeatherCode(0).symbol(isDaylight: false), "moon.stars.fill")
        XCTAssertEqual(WeatherCode(2).symbol(isDaylight: false), "cloud.moon.fill")
    }
}
