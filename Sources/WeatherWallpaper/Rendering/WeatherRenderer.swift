import MetalKit
import WeatherCore

enum SkyOptics {
    /// Apparent disk radii, expressed as a fraction of viewport height.
    static let bodyRadius: Float = 0.012
    static let moonRadius = bodyRadius * 1.5
    static let windSpeedMultiplier = 1.35

    static func glareStrength(for scene: SceneState) -> Float {
        func fade(_ value: Float, from low: Float, to high: Float) -> Float {
            let t = min(1,max(0,(value-low)/(high-low)))
            return t*t*(3-2*t)
        }
        // Keep reported gloomy conditions disk-only even if rain intensity is
        // currently zero. Also cover manually tuned precipitation / dense haze.
        let wet = max(scene.rain,max(scene.snow,scene.storm))
        return min(1,max(0,scene.sunGlare)) * (1-fade(wet,from: 0.005,to: 0.10))
            * (1-fade(scene.fog,from: 0.20,to: 0.60))
    }
}

enum RainRenderingBudget {
    static func rainCount(intensity: Float,scale: Float) -> Int {
        Int(min(1,max(0,intensity))*min(1,max(0,scale))*5200)
    }
    static func lensCount(intensity: Float,scale: Float) -> Int {
        Int(min(1,max(0,intensity*2))*pow(min(1,max(0,scale)),2)*140)
    }
}

struct WidgetRainUniforms {
    var rect: SIMD4<Float>
    var options: SIMD4<Float> // radius / logical height, enabled, guide, permit bounce
    static let disabled = WidgetRainUniforms(area: WidgetRainArea(),screenHeight: 1,guide: false,animated: false)

    init(area: WidgetRainArea,screenHeight: Float,guide: Bool,animated: Bool) {
        let area = area.sanitized
        rect = SIMD4(area.x,area.y,area.width,area.height)
        options = SIMD4(area.cornerRadius/max(1,screenHeight),area.enabled ? 1 : 0,
                        area.enabled && guide ? 1 : 0,area.enabled && animated ? 1 : 0)
    }
}

/// Packed header + fixed-capacity records mirrored by WidgetRainLayout in Metal.
struct WidgetRainLayoutUniforms {
    var vectors: [SIMD4<Float>]
    var count: Int { Int(vectors[0].x) }
    var showsGuide: Bool { vectors[0].y > 0 }
    static let disabled = WidgetRainLayoutUniforms(areas: [],screenHeight: 1,guide: false,animated: false)

    init(areas: [WidgetRainArea],screenHeight: Float,guide: Bool,animated: Bool) {
        let areas = areas.prefix(WidgetRainArea.maximumCount).filter(\.enabled)
        vectors = [SIMD4<Float>](repeating: .zero,count: 1+WidgetRainArea.maximumCount*2)
        // Count, guide, animation permission, conservative minimum rounded top.
        vectors[0] = SIMD4(Float(areas.count),guide ? 1 : 0,animated ? 1 : 0,1)
        for (index,area) in areas.enumerated() {
            let record = WidgetRainUniforms(area: area,screenHeight: screenHeight,guide: guide,animated: animated)
            vectors[1+index*2] = record.rect; vectors[2+index*2] = record.options
            vectors[0].w = min(vectors[0].w,record.rect.y)
        }
    }
}

/// Reuse packed bytes until layout, logical viewport height or policy changes.
struct WidgetRainLayoutCache {
    private struct Key: Equatable {
        var areas: [WidgetRainArea]
        var screenHeight: Float
        var guide: Bool
        var animated: Bool
    }
    private var key: Key?
    private var packed = WidgetRainLayoutUniforms.disabled
    private(set) var generation = 0

    mutating func uniforms(areas: [WidgetRainArea],screenHeight: Float,guide: Bool,animated: Bool) -> WidgetRainLayoutUniforms {
        let next = Key(areas: areas,screenHeight: screenHeight,guide: guide,animated: animated)
        if key != next {
            packed = WidgetRainLayoutUniforms(areas: areas,screenHeight: screenHeight,guide: guide,animated: animated)
            key = next
            generation += 1
        }
        return packed
    }
}

/// Aligned vectors mirrored exactly in Sky.metal. Shared by the app and GPU capture tests.
struct ShaderUniforms {
    var viewport: SIMD4<Float>
    var atmosphere: SIMD4<Float>
    var weather: SIMD4<Float>
    var celestial: SIMD4<Float>
    var options: SIMD4<Float>
    var moon: SIMD4<Float>
    var moonLight: SIMD4<Float> // lunar light xyz; solar weather-glare permission w (previously unused altitude)
    var lightning: SIMD4<Float>
    var clock: SIMD4<Float>
    var clouds: SIMD4<Float>
    var rendering: SIMD4<Float>
    var morphology: SIMD4<Float>
    var cloudStructure: SIMD4<Float>
    var upperStyle: SIMD4<Float>
    var convection: SIMD4<Float>
    var towerMetrics: SIMD4<Float> // heights + inverse heights, evaluated once per frame on CPU

    /// Mirrors the continuous shader weight's exact endpoints, never quantizes a
    /// transitioning scene. No extra uniform storage / per-frame compilation.
    var cloudBillowMode: UInt32 {
        if morphology.w >= 0.65 || clouds.z >= 1 || cloudStructure.w >= 1 || cloudStructure.z >= 0.92 { return 0 }
        if morphology.w <= 0.25 && clouds.z == 0 && cloudStructure.w == 0 && cloudStructure.z <= 0.72 { return 2 }
        return 1
    }

    init(scene: SceneState, size: CGSize, seconds: TimeInterval, wind: Double,
          policy: RenderPolicy = RenderPolicy(), strike: LightningSample = LightningSample()) {
        // Split long-running clocks so GPU motion remains smooth after days of playback.
        // Only bounded phases, not huge low-precision elapsed values, drive each effect.
        let lowSeconds = seconds.truncatingRemainder(dividingBy: 3600)
        let visualWind = wind * SkyOptics.windSpeedMultiplier
        let lowWind = visualWind.truncatingRemainder(dividingBy: 1024)
        viewport = SIMD4(Float(size.width), Float(size.height), Float(lowSeconds), Float(size.width / size.height))
        atmosphere = SIMD4(scene.solar.daylight, scene.solar.twilight, scene.cloud, scene.fog)
        weather = SIMD4(scene.rain, scene.snow, scene.storm, scene.wind)
        celestial = SIMD4(scene.solar.sunPosition.x, scene.solar.sunPosition.y, scene.solar.moonIllumination, scene.windDirection)
        options = SIMD4(policy.particleScale, policy.permitsLightning && policy.animated ? 1 : 0, Float(lowWind), policy.bloom ? 1 : 0)
        moon = SIMD4(scene.solar.moon.position.x, scene.solar.moon.position.y, scene.solar.moon.visibility, scene.solar.moon.rotation)
        moonLight = SIMD4(scene.solar.moon.lightDirection,SkyOptics.glareStrength(for: scene))
        lightning = SIMD4(strike.origin, strike.seed,
                          policy.permitsLightning && policy.animated && !policy.suspended ? strike.intensity : 0, strike.reach)
        clock = SIMD4(Float(seconds - lowSeconds), Float(visualWind - lowWind), strike.progress, Float(policy.bloomDownsample))
        let appearance = CloudAppearance(scene: scene)
        clouds = SIMD4(appearance.coverage, appearance.opticalDepth, appearance.wetness, appearance.cirrus)
        rendering = SIMD4(Float(policy.cloudSteps), Float(policy.cloudDownsample), policy.volumetricClouds ? (policy.panoramicClouds ? 2 : 1) : 0, SkyOptics.bodyRadius)
        morphology = appearance.presentation.shape
        cloudStructure = SIMD4(appearance.presentation.erosion, appearance.presentation.density,
                               appearance.volumeCoverage, appearance.presentation.opaque)
        upperStyle = SIMD4(appearance.presentation.upperStyle, 0)
        let towers = appearance.presentation.convection
        // Double-precision bounded phases remain continuous across clock splits and
        // long uptimes. The scene clock already freezes for pause/Reduce Motion.
        convection = SIMD4(towers.x * min(1,max(0,scene.cloud)/0.3) * pow(max(0,1-scene.fog),2), towers.y,
                           Float(seconds.truncatingRemainder(dividingBy: 900) / 900 * 2 * .pi),
                           Float(sin(visualWind * 0.001 + seconds * 0.0003)) * 1.4)
        if convection.x > 0.001 {
            let height = (3.8 + (6.8-3.8) * convection.y) * 1.35
            let a = height * (0.88 + 0.12 * sin(convection.z))
            let b = height * (0.88 + 0.12 * sin(convection.z+2.1)) * 0.92
            towerMetrics = SIMD4(a,b,1/a,1/b)
        } else { towerMetrics = .zero }
    }
}

@MainActor
final class WeatherRenderer: NSObject, MTKViewDelegate {
    private weak var view: MTKView?
    private let environment: SceneEnvironment
    private let resources: MetalResources
    private let compositor: SceneCompositor
    private let inFlight = DispatchSemaphore(value: 2)
    private var observation: UUID?
    private var stopped = false
    private var widgetCache = WidgetRainLayoutCache()
    private let moonlitHaze: Bool
    private var hazeTransition = NotchHazeTransition()
    private var lastRenderedUptime: TimeInterval = 0
    private var forceNextDraw = true
    private var hasDrawnOnce = false

    init(view: MTKView, environment: SceneEnvironment, moonlitHaze: Bool = false) throws {
        self.view = view
        self.environment = environment
        self.moonlitHaze = moonlitHaze
        resources = try MetalResources.shared.get()
        compositor = SceneCompositor(resources: resources)
        super.init()
        view.device = resources.device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .invalid
        view.sampleCount = 1
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.delegate = self
        if let layer = view.layer as? CAMetalLayer {
            layer.maximumDrawableCount = 2
            layer.presentsWithTransaction = false
        }
        observation = environment.observe { [weak self] in self?.refreshPolicy() }
        refreshPolicy()
    }

    func stop() {
        stopped = true
        view?.isPaused = true
        view?.delegate = nil
        view?.releaseDrawables()
        if let observation { environment.removeObserver(observation) }
        observation = nil
        compositor.releaseTransientResources()
    }

    func refreshPolicy() {
        guard let view, !stopped else { return }
        let policy = environment.policy
        view.preferredFramesPerSecond = policy.framesPerSecond
        resize(view)
        let visible = view.window?.occlusionState.contains(.visible) == true && !view.isHiddenOrHasHiddenAncestor
        let paused = !policy.animated || policy.suspended || !visible
        view.isPaused = paused
        forceNextDraw = true
        if !policy.suspended && visible && (paused || !hasDrawnOnce) { view.draw() }
        if policy.suspended || !visible {
            hasDrawnOnce = false
            view.releaseDrawables()
            compositor.releaseTransientResources()
        }
    }

    /// Adaptive pacing keeps precipitation, lightning, meteors, and transitions at full
    /// rate while skipping redundant GPU frames on calm clear/dry skies.
    static func targetFrameInterval(scene: SceneState, policy: RenderPolicy,
                                    transitioning: Bool, meteorActive: Bool) -> TimeInterval {
        guard policy.animated, !policy.suspended else { return 0 }
        if transitioning || meteorActive || policy.showsWidgetGuide
            || scene.rain > 0.001 || scene.snow > 0.001 || scene.storm > 0.001 {
            return 0
        }
        let appearance = CloudAppearance(scene: scene)
        let hasClouds = appearance.volumeCoverage > 0.075
            || appearance.cirrus > 0.001
            || appearance.presentation.convection.x > 0.001
        if !hasClouds && scene.solar.daylight <= 0.01 && scene.solar.twilight <= 0.01 {
            return 1.0 / 6.0
        }
        return 1.0 / 15.0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func resize(_ view: MTKView) {
        let bounds = view.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let nativeScale = view.window?.backingScaleFactor ?? 1
        let scale = min(nativeScale, environment.policy.maximumDimension / max(bounds.width, bounds.height))
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        if view.drawableSize != size { view.drawableSize = size }
    }

    func draw(in view: MTKView) {
        guard !stopped, !environment.policy.suspended,
               !view.isHiddenOrHasHiddenAncestor,
              view.window?.occlusionState.contains(.visible) == true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let scene = environment.scene(at: now)
        let policy = environment.policy
        let seconds = environment.animationTime(at: now)
        let meteor = policy.animated && !policy.suspended && policy.permitsMeteors && scene.solar.daylight < 0.1
            ? MeteorAppearance.sample(at: seconds, aspect: Float(view.drawableSize.width / max(1, view.drawableSize.height)),
                                       speed: policy.meteorSpeed) : nil
        let transitioning = environment.isTransitioning(at: now)
            || (moonlitHaze && hazeTransition.isTransitioning(at: seconds))
        let interval = Self.targetFrameInterval(scene: scene, policy: policy,
                                                transitioning: transitioning, meteorActive: meteor != nil)
        if !forceNextDraw && interval > 0 && now - lastRenderedUptime < interval * 0.92 {
            return
        }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        guard let drawable = view.currentDrawable,
               let buffer = resources.queue.makeCommandBuffer() else { return }
        buffer.label = environment.renderLabel
        let uniforms = ShaderUniforms(
            scene: scene, size: view.drawableSize, seconds: seconds,
            wind: environment.windOffset(at: now, scene: scene), policy: policy,
            strike: environment.lightningSample(at: now, scene: scene)
        )
        var haze = MoonlitHazeUniforms.disabled
        if moonlitHaze {
            let state = hazeTransition.value(configuration: policy.notchHaze,at: seconds,animated: policy.animated && !policy.suspended)
            haze = MoonlitHazeUniforms(strength: state.x,expansion: state.y,seconds: seconds)
        }
        compositor.encode(into: drawable.texture, buffer: buffer, uniforms: uniforms, meteor: meteor,
                           framesPerSecond: policy.framesPerSecond,animated: policy.animated && !policy.suspended,
                            widget: widgetCache.uniforms(areas: policy.widgetRainAreas,screenHeight: Float(view.bounds.height),
                                guide: policy.showsWidgetGuide,animated: policy.animated && !policy.suspended),
                            haze: haze,
                            allowCloudReuse: policy.animated && !policy.suspended && !transitioning)
        let semaphore = inFlight
        buffer.addCompletedHandler { _ in semaphore.signal() }
        buffer.present(drawable)
        buffer.commit()
        committed = true
        lastRenderedUptime = now
        forceNextDraw = false
        hasDrawnOnce = true
    }
}
