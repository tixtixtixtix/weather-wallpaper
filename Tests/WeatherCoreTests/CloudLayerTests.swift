import Foundation
import XCTest
@testable import WeatherCore

final class CloudLayerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let city = City(name: "London", region: "UK", latitude: 51.5, longitude: 0, timeZoneIdentifier: "Europe/London")

    func testOrdinaryCloudsKeepTheirThicknessButUseRaisedStratocumulusStyling() {
        let replacement = CloudPresentation.profile(.cumulus)
        let stratocumulus = CloudPresentation.profile(.stratocumulus)
        XCTAssertEqual(replacement.shape.y,1.1,"Keep the former cumulus vertical thickness")
        XCTAssertGreaterThan(replacement.shape.x,1.15,"Raise the layer rather than flattening its height")
        XCTAssertEqual(replacement.shape.z,stratocumulus.shape.z)
        XCTAssertEqual(replacement.shape.w,stratocumulus.shape.w)
        XCTAssertEqual(replacement.erosion,stratocumulus.erosion)
        XCTAssertEqual(replacement.density,stratocumulus.density)
        XCTAssertEqual(replacement.opaque,stratocumulus.opaque)
        XCTAssertEqual(CloudPresentation.weatherProfile(.partlyCloudy),replacement)
        XCTAssertEqual(CloudPresentation.generic,replacement)
        XCTAssertEqual(CloudGenus.cumulus.title,"Raised Stratocumulus")
        XCTAssertEqual(SceneState.preview(kind: .partlyCloudy,time: .day,cloudGenus: .cumulus).cloudPresentation,replacement,
                       "Existing saved cumulus selections use the replacement without resetting preferences")
        var developed = CloudPresentation.developing(.toweringCumulus)
        developed.convection = .zero
        XCTAssertEqual(developed,replacement,"The raised foreground remains beneath optional background towers")
        let live = SceneState.live(snapshot: snapshot(low: nil,middle: nil,high: nil,cover: 0.44),city: city,at: now)
        XCTAssertEqual(live.cloudPresentation,replacement)
        XCTAssertEqual(live.cloud,0.44,accuracy: 0.0001)
    }

    func testSolarGlareTracksWeatherConditionAndBlendsAcrossTransitions() {
        for kind in WeatherKind.allCases {
            let expected: Float = [.clear,.partlyCloudy,.windy].contains(kind) ? 1 : 0
            XCTAssertEqual(SceneState.preview(kind: kind,time: .day).sunGlare,expected)
            let live = SceneState.live(snapshot: snapshot(low: 0.5,middle: 0.3,high: 0.2,kind: kind,precipitation: 0,cover: 0.44),city: city,at: now)
            XCTAssertEqual(live.sunGlare,expected,"Reported \(kind) determines optics even at zero precipitation / equal cover")
            XCTAssertEqual(live.rain,0); XCTAssertEqual(live.snow,0,"Do not invent precipitation to suppress glare")
        }
        let fair = SceneState.preview(kind: .partlyCloudy,time: .day,cloudDevelopment: .toweringCumulus)
        let gloomy = SceneState.preview(kind: .thunderstorm,time: .day,cloudDevelopment: .developingThunderstorm)
        XCTAssertEqual(fair.sunGlare,1); XCTAssertEqual(gloomy.sunGlare,0)
        let halfway = SceneState.interpolate(from: fair,to: gloomy,progress: 0.5)
        XCTAssertEqual(halfway.sunGlare,0.5)
        XCTAssertEqual(SceneState.interpolate(from: fair,to: gloomy,progress: 0),fair)
        XCTAssertEqual(SceneState.interpolate(from: fair,to: gloomy,progress: 1),gloomy)
        XCTAssertEqual(SceneState.preview(kind: .clear,time: .day,cloudGenus: .cirrus).sunGlare,1)
    }

    private func snapshot(low: Double?, middle: Double?, high: Double?, at date: Date? = nil,
                          kind: WeatherKind = .partlyCloudy, code: Int? = 2,
                          precipitation: Double = 0, visibility: Double = 20_000, cover: Double = 0.8) -> WeatherSnapshot {
        WeatherSnapshot(cityID: city.id, observedAt: now, fetchedAt: now, expiresAt: now.addingTimeInterval(900),
            kind: kind, conditionDescription: kind.title, symbolName: kind.symbol, temperatureCelsius: 15,
            cloudCover: cover, precipitationMillimetersPerHour: precipitation, windMetersPerSecond: 4,
            windDirectionDegrees: 200, visibilityMeters: visibility, provider: .openMeteo,
            cloudLayers: CloudLayerCoverage(validAt: date ?? now, low: low, middle: middle, high: high), weatherCode: code)
    }

    func testConvectionRequiresFreshCompatibleWeatherAndKnownLowerLayers() throws {
        let shower = snapshot(low: 0.65,middle: 0.5,high: 0.3,kind: .rain,code: 81,precipitation: 1)
        let thunder = snapshot(low: 0.65,middle: 0.5,high: 0.3,kind: .thunderstorm,code: 95)
        XCTAssertGreaterThan(CloudPresentation.live(snapshot: shower,at: now).convection.x,0)
        XCTAssertGreaterThan(CloudPresentation.live(snapshot: thunder,at: now).convection.y,0.9)
        XCTAssertEqual(SceneState.live(snapshot: thunder,city: city,at: now).rain,0)
        for value in [
            snapshot(low: 0.65,middle: 0.5,high: 0.3),
            snapshot(low: 0.65,middle: 0.5,high: 0.3,kind: .rain,code: 63,precipitation: 2),
            snapshot(low: 0.65,middle: 0.5,high: 0.3,kind: .rain,code: 81),
            snapshot(low: nil,middle: 0.5,high: 0.3,kind: .thunderstorm,code: 95),
            snapshot(low: 0,middle: 0,high: 0.8,kind: .thunderstorm,code: 95),
            snapshot(low: 0.8,middle: 0.5,high: 0,kind: .thunderstorm,code: 95,visibility: 2000),
            snapshot(low: 0.8,middle: 0.5,high: 0,kind: .thunderstorm,code: 95,cover: 0.2),
            snapshot(low: 0.8,middle: 0.5,high: 0,at: now.addingTimeInterval(600),kind: .thunderstorm,code: 95)
        ] {
            XCTAssertEqual(CloudPresentation.live(snapshot: value,at: now).convection.x,0)
        }
        XCTAssertEqual(CloudPresentation.live(snapshot: thunder,at: now.addingTimeInterval(901)).convection.x,0,
                       "Expired weather must not sustain developing towers")
        let cached = try JSONDecoder().decode(WeatherSnapshot.self,from: JSONEncoder().encode(shower))
        XCTAssertEqual(CloudPresentation.live(snapshot: cached,at: now),CloudPresentation.live(snapshot: shower,at: now))
    }

    func testDevelopmentPreviewsAreSubtypesAndBlendContinuously() {
        XCTAssertEqual(CloudGenus.allCases.count,10)
        for (development,kind) in [(CloudDevelopment.toweringCumulus,WeatherKind.partlyCloudy),(.developingThunderstorm,.thunderstorm)] {
            let scene = SceneState.preview(kind: kind,time: .day,cloudDevelopment: development)
            XCTAssertEqual(scene.cloudPresentation,CloudPresentation.developing(development))
            XCTAssertGreaterThan(scene.cloudPresentation!.convection.x,0)
            XCTAssertGreaterThan(scene.cloudPresentation!.volumeFraction,0.5,"Development must keep ordinary foreground clouds")
            let ignored = SceneState.preview(kind: .clear,time: .day,cloudDevelopment: development)
            XCTAssertEqual(ignored.cloudPresentation,CloudPresentation.weatherProfile(.clear))
            let start = SceneState.preview(kind: kind,time: .day)
            var transition = SceneTransition(scene: start)
            transition.setTarget(scene,at: 0)
            let a = transition.value(at: 2.999).cloudPresentation!.convection
            let b = transition.value(at: 3.001).cloudPresentation!.convection
            XCTAssertGreaterThan(a.x,0); XCTAssertLessThan(b.x-a.x,0.001)
            XCTAssertEqual(transition.value(at: 6),scene)
        }
        let ordinary = CloudPresentation.profile(.cumulus)
        var combined = CloudPresentation.developing(.toweringCumulus)
        combined.convection = .zero
        XCTAssertEqual(combined,ordinary,"Selecting towers adds background mass, not a replacement foreground")
    }

    func testHighOnlySkyDoesNotManufactureLowerCumulus() {
        let scene = SceneState.live(snapshot: snapshot(low: 0,middle: 0,high: 0.8), city: city, at: now)
        let appearance = CloudAppearance(scene: scene)
        XCTAssertEqual(appearance.volumeCoverage, 0)
        XCTAssertEqual(appearance.cirrus, 0.8, accuracy: 0.001)
        XCTAssertEqual(scene.cloud, 0.8)
    }

    func testUnknownLayersAreNotTreatedAsClearOrDecoratedWithHighClouds() {
        let scene = SceneState.live(snapshot: snapshot(low: nil,middle: nil,high: nil), city: city, at: now)
        let appearance = CloudAppearance(scene: scene)
        XCTAssertEqual(appearance.volumeCoverage, 0.8, accuracy: 0.001)
        XCTAssertEqual(appearance.cirrus, 0)
        let partial = CloudAppearance(scene: .live(snapshot: snapshot(low: nil,middle: 0,high: 0.8), city: city, at: now))
        XCTAssertGreaterThan(partial.volumeCoverage, 0, "An unknown low layer is not an explicit zero")
    }

    func testStaleOrFutureLayerDataFallsBackConservatively() {
        for date in [now.addingTimeInterval(-2 * 3600), now.addingTimeInterval(900)] {
            let scene = SceneState.live(snapshot: snapshot(low: 0,middle: 0,high: 0.8,at: date), city: city, at: now)
            XCTAssertEqual(CloudAppearance(scene: scene).cirrus, 0)
            XCTAssertGreaterThan(CloudAppearance(scene: scene).volumeCoverage, 0)
        }
    }

    func testLayerFractionsOverlapRatherThanAddingToTheReportedCover() {
        let scene = SceneState.live(snapshot: snapshot(low: 0.7,middle: 0.8,high: 0.6), city: city, at: now)
        let appearance = CloudAppearance(scene: scene)
        XCTAssertEqual(scene.cloud, 0.8)
        XCTAssertEqual(appearance.coverage, 0.8)
        XCTAssertEqual(appearance.volumeCoverage, 0.8)
        XCTAssertEqual(appearance.cirrus, 0.6, accuracy: 0.001)
    }

    func testWeatherEvidenceSelectsCompatibleRegimesWithoutInventingRain() {
        let drizzle = SceneState.live(snapshot: snapshot(low: 0.8,middle: 0.2,high: 0,kind: .rain,code: 51), city: city, at: now)
        XCTAssertEqual(drizzle.cloudPresentation?.shape, CloudPresentation.profile(.stratus).shape)
        let rain = SceneState.live(snapshot: snapshot(low: 0.8,middle: 0.8,high: 0.7,kind: .rain,code: 63), city: city, at: now)
        XCTAssertEqual(rain.cloudPresentation?.opaque, 1)
        XCTAssertEqual(rain.rain, 0)
        let thunder = SceneState.live(snapshot: snapshot(low: 0.8,middle: 0.8,high: 0.8,kind: .thunderstorm,code: 95), city: city, at: now)
        XCTAssertEqual(thunder.cloudPresentation?.shape, CloudPresentation.profile(.cumulonimbus).shape)
        XCTAssertEqual(thunder.rain, 0)
    }

    func testCloudShapeWeightsDoNotFlipAbruptlyAtCoverageThresholds() {
        let before = CloudPresentation.live(snapshot: snapshot(low: 0.599,middle: 0.6,high: 0.4), at: now)
        let after = CloudPresentation.live(snapshot: snapshot(low: 0.601,middle: 0.6,high: 0.4), at: now)
        XCTAssertLessThan(abs(after.shape.x - before.shape.x), 0.02)
        XCTAssertLessThan(abs(after.shape.z - before.shape.z), 0.05)
        XCTAssertEqual(CloudPresentation.interpolate(before,after,progress: 0), before)
        XCTAssertEqual(CloudPresentation.interpolate(before,after,progress: 1), after)
    }

    func testAllTenFamiliesHaveExplicitCompatiblePreviews() {
        XCTAssertEqual(CloudGenus.allCases.count, 10)
        for genus in CloudGenus.allCases {
            let kind = WeatherKind.allCases.first { CloudGenus.eligiblePreviews(for: $0).contains(genus) }!
            let scene = SceneState.preview(kind: kind,time: .day,cloudGenus: genus)
            XCTAssertEqual(scene.cloudPresentation, CloudPresentation.profile(genus))
        }
        let rain = SceneState.preview(kind: .rain,time: .day,cloudGenus: .cirrocumulus)
        XCTAssertEqual(rain.cloudPresentation, CloudPresentation.profile(.nimbostratus), "An incompatible preview request is ignored")
    }

    func testFractionsValidateAndRoundTripThroughTheWeatherCache() throws {
        let layers = CloudLayerCoverage(validAt: now, low: -1,middle: 1.2,high: 0)
        XCTAssertNil(layers.low); XCTAssertNil(layers.middle); XCTAssertEqual(layers.high,0)
        let value = snapshot(low: 0,middle: nil,high: 0.8)
        let decoded = try JSONDecoder().decode(WeatherSnapshot.self,from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.cloudLayers,value.cloudLayers)
        XCTAssertEqual(decoded.weatherCode,2)
    }
}
