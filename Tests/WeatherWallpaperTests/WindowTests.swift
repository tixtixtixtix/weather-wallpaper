import AppKit
import SwiftUI
import XCTest
import WeatherCore
@testable import WeatherWallpaper

final class WindowTests: XCTestCase {
    @MainActor
    func testMoonlitHazePreferencesHostWithoutStartingBackgroundWork() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = AppModel()
        let host = NSHostingView(rootView: PreferencesView(model: model))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width,510,accuracy: 1)
        XCTAssertEqual(host.fittingSize.height,650,accuracy: 1)
        XCTAssertFalse(model.isFetching)
        XCTAssertFalse(model.wallpaperActive)
    }

    func testMoonlitHazePreferencesAndUniformsStayCompatible() throws {
        var preferences = try JSONDecoder().decode(Preferences.self,from: JSONEncoder().encode(Preferences()))
        XCTAssertNil(preferences.notchHaze)
        var configuration = NotchHazeConfiguration()
        configuration.layout = .compact; configuration.intensity = .nan
        XCTAssertEqual(configuration.sanitized.intensity,0.75)
        configuration.intensity = 4
        XCTAssertEqual(configuration.sanitized.intensity,1)
        configuration.intensity = -1
        XCTAssertEqual(configuration.sanitized.intensity,0)
        configuration.intensity = 0.65; preferences.notchHaze = configuration
        let restored = try JSONDecoder().decode(Preferences.self,from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.notchHaze,configuration)
        XCTAssertEqual(MemoryLayout<MoonlitHazeUniforms>.stride,32)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.stride,256)
        let compact = MoonlitHazeUniforms(configuration: configuration,seconds: 360000)
        XCTAssertEqual(compact.appearance.x,0.65); XCTAssertEqual(compact.appearance.y,0)
        XCTAssertTrue((0..<4).allSatisfy { compact.motion[$0] >= 0 && compact.motion[$0] < 1 })
        configuration.enabled = false
        XCTAssertEqual(MoonlitHazeUniforms(configuration: configuration).appearance.x,0)
    }

    func testMoonlitHazeLayoutTransitionsAreContinuousAndPauseSnapsWithoutATimer() {
        var transition = NotchHazeTransition(), configuration = NotchHazeConfiguration()
        configuration.layout = .compact
        let compact = transition.value(configuration: configuration,at: 10,animated: true)
        XCTAssertEqual(compact.y,0)
        configuration.layout = .expanded
        XCTAssertEqual(transition.value(configuration: configuration,at: 10.1,animated: true),compact)
        let middle = transition.value(configuration: configuration,at: 10.4,animated: true)
        XCTAssertGreaterThan(middle.y,0); XCTAssertLessThan(middle.y,1)
        configuration.layout = .compact
        XCTAssertEqual(transition.value(configuration: configuration,at: 10.4,animated: true),middle,"Retarget without a jump")
        XCTAssertEqual(transition.value(configuration: configuration,at: 11.4,animated: true).y,0)
        configuration.layout = .expanded
        XCTAssertEqual(transition.value(configuration: configuration,at: 11.4,animated: false).y,1)
        configuration.enabled = false
        XCTAssertEqual(transition.value(configuration: configuration,at: 11.4,animated: false).x,0)
    }

    func testWidgetLayoutCacheReusesBytesAndInvalidatesEveryRelevantInput() {
        var cache = WidgetRainLayoutCache()
        var area = WidgetRainArea(); area.enabled = true
        var areas = [area], height: Float = 1000
        var guide = false, animated = true
        func check(_ expectedGeneration: Int) {
            let packed = cache.uniforms(areas: areas,screenHeight: height,guide: guide,animated: animated)
            XCTAssertEqual(packed.vectors,WidgetRainLayoutUniforms(areas: areas,screenHeight: height,guide: guide,animated: animated).vectors)
            XCTAssertEqual(cache.generation,expectedGeneration)
        }
        for _ in 0..<100 { check(1) }
        var secondDisplay = WidgetRainLayoutCache()
        let secondary = secondDisplay.uniforms(areas: areas,screenHeight: 720,guide: true,animated: false)
        XCTAssertEqual(secondary.vectors,WidgetRainLayoutUniforms(areas: areas,screenHeight: 720,guide: true,animated: false).vectors)
        XCTAssertEqual(cache.generation,1,"Each renderer keeps independent display-sized bytes")
        areas[0].x = 0.3; check(2)
        height = 500; check(3)
        guide = true; check(4)
        animated = false; check(5)
        areas[0].enabled = false; check(6)
        areas = []; check(7)
        area.y = 4 // The conservative bound must use the sanitized GPU rectangle.
        areas = [area]; check(8)
        let packed = cache.uniforms(areas: areas,screenHeight: height,guide: guide,animated: animated)
        XCTAssertEqual(packed.vectors[0].w,packed.vectors[1].y)
    }

    func testWidgetAreaIsOptionalClampedAndPersistsWithoutDiskWrites() throws {
        var preferences = try JSONDecoder().decode(Preferences.self,from: JSONEncoder().encode(Preferences()))
        XCTAssertNil(preferences.widgetRainArea)
        XCTAssertFalse(WidgetRainArea().enabled)
        var area = WidgetRainArea()
        area.enabled = true; area.width = 2; area.height = -1
        area.x = 0.8; area.y = .infinity; area.cornerRadius = .nan
        area = area.sanitized
        XCTAssertEqual(area.width,1); XCTAssertEqual(area.height,0.02)
        XCTAssertEqual(area.x,0); XCTAssertEqual(area.y,0); XCTAssertEqual(area.cornerRadius,24)
        preferences.widgetRainArea = area
        let restored = try JSONDecoder().decode(Preferences.self,from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.widgetRainArea,area)
        XCTAssertEqual(MemoryLayout<WidgetRainUniforms>.stride,32)
        let uniforms = WidgetRainUniforms(area: area,screenHeight: 1000,guide: true,animated: false)
        XCTAssertEqual(uniforms.options.x,0.024,accuracy: 0.00001)
        XCTAssertEqual(uniforms.options.z,1); XCTAssertEqual(uniforms.options.w,0)
    }

    func testMultipleWidgetAreasMigrateAndPackWithinTheGPULimit() throws {
        var preferences = Preferences()
        var original = WidgetRainArea(); original.enabled = true
        preferences.widgetRainArea = original
        XCTAssertEqual(preferences.resolvedWidgetRainAreas,[original])
        preferences.widgetRainAreas = []
        XCTAssertEqual(preferences.resolvedWidgetRainAreas,[],"Removing all areas must not restore the legacy area")
        var second = original; second.x = 0.5; second.cornerRadius = 40
        preferences.widgetRainAreas = [original,second]
        let restored = try JSONDecoder().decode(Preferences.self,from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.resolvedWidgetRainAreas,[original,second])
        let packed = WidgetRainLayoutUniforms(areas: restored.resolvedWidgetRainAreas,
            screenHeight: 1000,guide: true,animated: true)
        XCTAssertEqual(packed.count,2); XCTAssertTrue(packed.showsGuide)
        XCTAssertEqual(packed.vectors.count*MemoryLayout<SIMD4<Float>>.stride,784)
        XCTAssertEqual(packed.vectors[3].x,0.5); XCTAssertEqual(packed.vectors[4].x,0.04,accuracy: 0.00001)
        original.enabled = false
        XCTAssertEqual(WidgetRainLayoutUniforms(areas: [original,second],screenHeight: 1000,guide: false,animated: false).count,1)
        preferences.widgetRainAreas = Array(repeating: second,count: 100)
        XCTAssertEqual(preferences.resolvedWidgetRainAreas.count,24)
        XCTAssertEqual(RainRenderingBudget.rainCount(intensity: 1,scale: 1),5200)
        XCTAssertEqual(RainRenderingBudget.rainCount(intensity: 1,scale: 0.5),2600)
        XCTAssertEqual(RainRenderingBudget.rainCount(intensity: 0,scale: 1),0)
        XCTAssertEqual(RainRenderingBudget.lensCount(intensity: 1,scale: 1),140)
        XCTAssertEqual(RainRenderingBudget.lensCount(intensity: 1,scale: 0.5),35)
    }

    @MainActor
    func testDevelopmentAndGenusSelectionAreExclusiveAndResetForLive() async {
        let model = AppModel()
        model.previewKind = .partlyCloudy
        model.previewCloudGenus = .cumulus
        model.previewCloudDevelopment = .toweringCumulus
        XCTAssertNil(model.previewCloudGenus)
        model.previewCloudGenus = .cirrus
        XCTAssertNil(model.previewCloudDevelopment)
        model.previewCloudDevelopment = .toweringCumulus
        model.previewKind = .rain
        XCTAssertNil(model.previewCloudDevelopment)
        model.previewKind = .thunderstorm
        model.previewCloudDevelopment = .developingThunderstorm
        model.previewKind = nil
        XCTAssertNil(model.previewCloudDevelopment)
        XCTAssertFalse(model.wallpaperActive)
        XCTAssertFalse(model.isFetching)
    }

    func testPreferencesKeepOldUnknownKeysAndPersistDevelopmentWithoutDiskWrites() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        // Old reserved keys must be ignored rather than rejecting the whole file.
        object["contrailsEnabled"] = true
        let data = try JSONSerialization.data(withJSONObject: object)
        var decoded = try JSONDecoder().decode(Preferences.self,from: data)
        XCTAssertNil(decoded.appliedCloudDevelopment)
        decoded.appliedCloudDevelopment = .toweringCumulus
        decoded.appliedCloudGenus = .cumulus
        let encoded = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(Preferences.self,from: encoded)
        XCTAssertEqual(roundTrip.appliedCloudDevelopment,.toweringCumulus)
        XCTAssertEqual(roundTrip.appliedCloudGenus,.cumulus)
        XCTAssertFalse(String(decoding: encoded,as: UTF8.self).contains("contrails"))
    }
    @MainActor
    func testCloudPreviewSelectionResetsWhenTheWeatherIsIncompatible() async {
        let model = AppModel()
        model.previewKind = .partlyCloudy
        model.previewCloudGenus = .cirrocumulus
        model.previewKind = .rain
        XCTAssertNil(model.previewCloudGenus)
        XCTAssertFalse(model.isFetching)
        model.previewCloudGenus = .nimbostratus
        model.previewKind = nil
        XCTAssertNil(model.previewCloudGenus)
    }

    @MainActor
    func testWeatherPopoverUsesNativeCompactLayoutWithoutStartingWork() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = AppModel()
        let host = NSHostingView(rootView: WeatherMenuView(model: model))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 360, accuracy: 1)
        XCTAssertLessThan(host.fittingSize.height, 650)
        XCTAssertFalse(model.isFetching)
        XCTAssertFalse(model.wallpaperActive)
    }

    @MainActor
    func testClosingMainWindowHidesDockAndReopeningRestoresIt() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var policies: [NSApplication.ActivationPolicy] = []
        let presence = WindowPresenceController { policies.append($0) }
        let main = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        let desktop = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        desktop.isReleasedWhenClosed = false
        presence.track(main)
        presence.track(main) // SwiftUI may attach the same view/window again.
        XCTAssertEqual(policies, [.regular])

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: desktop)
        XCTAssertEqual(policies, [.regular], "Desktop window changes must not affect Dock presence")
        main.close()
        XCTAssertEqual(policies, [.regular, .accessory])

        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: main)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
        desktop.close()
    }

    @MainActor
    func testReplacingMainWindowStopsObservingTheOldWindow() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var policies: [NSApplication.ActivationPolicy] = []
        let presence = WindowPresenceController { policies.append($0) }
        let old = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let replacement = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        old.isReleasedWhenClosed = false
        replacement.isReleasedWhenClosed = false
        presence.track(old)
        presence.track(replacement)
        old.close()
        XCTAssertEqual(policies, [.regular, .regular])
        replacement.close()
        XCTAssertEqual(policies, [.regular, .regular, .accessory])
    }

    @MainActor
    func testMainInterfaceHostsInANativeWindowWithoutStartingBackgroundWork() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited) // Test process only; don't open a Dock icon or visible window.
        let model = AppModel()
        let host = NSHostingView(rootView: MainView(model: model).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 820),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.fittingSize.width, 800)
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 560)
        XCTAssertFalse(model.isFetching)
        XCTAssertFalse(model.wallpaperActive)
        XCTAssertFalse(window.isVisible)
        window.contentView = nil
        window.close()
    }
}
