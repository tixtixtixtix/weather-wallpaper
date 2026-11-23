import Foundation

public struct SceneState: Equatable, Sendable {
    public var cloud: Float
    public var rain: Float
    public var snow: Float
    public var fog: Float
    public var storm: Float
    public var wind: Float
    public var windDirection: Float
    public var solar: SolarState
    public var cloudPresentation: CloudPresentation? = nil
    /// Weather-level permission for solar glare, independent of cloud-at-source
    /// opacity. Continuous so weather transitions do not abruptly switch optics.
    public var sunGlare: Float = 1

    public static func preview(kind: WeatherKind, time: PreviewTime, moonPhase: PreviewMoonPhase = .waxingGibbous,
                               cloudGenus: CloudGenus? = nil, cloudDevelopment: CloudDevelopment? = nil) -> SceneState {
        var scene = SceneState(cloud: 0, rain: 0, snow: 0, fog: 0, storm: 0,
                               wind: 0.2, windDirection: 0.5, solar: .preview(time, phase: moonPhase))
        switch kind {
        case .clear: scene.cloud = 0.06
        case .partlyCloudy: scene.cloud = 0.44
        case .cloudy: scene.cloud = 0.94
        case .rain: scene.cloud = 0.92; scene.rain = 0.65; scene.wind = 0.4
        case .snow: scene.cloud = 0.82; scene.snow = 0.65; scene.wind = 0.18
        case .sleet: scene.cloud = 0.88; scene.rain = 0.35; scene.snow = 0.32
        case .thunderstorm: scene.cloud = 1; scene.rain = 0.85; scene.storm = 1; scene.wind = 0.7
        case .fog: scene.cloud = 0.7; scene.fog = 0.85; scene.wind = 0.05
        case .windy: scene.cloud = 0.56; scene.wind = 0.95
        }
        switch kind {
        case .clear, .partlyCloudy, .windy: scene.sunGlare = 1
        case .cloudy, .rain, .snow, .sleet, .thunderstorm, .fog: scene.sunGlare = 0
        }
        scene.cloudPresentation = .weatherProfile(kind)
        if let cloudGenus, CloudGenus.eligiblePreviews(for: kind).contains(cloudGenus) {
            scene.cloudPresentation = .profile(cloudGenus)
            switch cloudGenus {
            case .cirrus: scene.cloud = 0.30
            case .cirrocumulus: scene.cloud = 0.42
            case .cirrostratus: scene.cloud = 0.75
            case .altocumulus: scene.cloud = 0.52
            case .altostratus: scene.cloud = 0.82
            default: break
            }
        }
        if let cloudDevelopment, CloudDevelopment.eligiblePreviews(for: kind).contains(cloudDevelopment) {
            scene.cloudPresentation = .developing(cloudDevelopment)
            if cloudDevelopment == .developingThunderstorm {
                scene.cloud = 0.58; scene.rain = 0.12; scene.storm = 0.3
            }
        }
        return scene
    }

    public static func live(snapshot: WeatherSnapshot, city: City, at date: Date) -> SceneState {
        var scene = preview(kind: snapshot.kind, time: .day)
        scene.cloud = Float(max(0, min(1, snapshot.cloudCover)))
        scene.wind = Float(max(0, min(1, snapshot.windMetersPerSecond / 22)))
        scene.windDirection = Float(sin(snapshot.windDirectionDegrees * .pi / 180))
        // No invented precipitation when the observation reports zero intensity.
        let intensity = Float(min(1, sqrt(max(0, snapshot.precipitationMillimetersPerHour) / 8)))
        if scene.rain > 0 && scene.snow > 0 {
            scene.rain = intensity * 0.55; scene.snow = intensity * 0.45
        } else if scene.rain > 0 {
            scene.rain = intensity
        } else if scene.snow > 0 {
            scene.snow = intensity
        }
        if snapshot.kind == .fog {
            scene.fog = Float(max(0.12, min(0.98, 1 - max(0, snapshot.visibilityMeters) / 15000)))
        } else if snapshot.visibilityMeters < 5000 {
            scene.fog = max(scene.fog, Float(1 - max(0, snapshot.visibilityMeters) / 5000) * 0.8)
        }
        scene.solar = SolarCalculator.state(at: date, latitude: city.latitude, longitude: city.longitude)
        scene.cloudPresentation = .live(snapshot: snapshot, at: date)
        return scene
    }

    public static func interpolate(from a: SceneState, to b: SceneState, progress: Float) -> SceneState {
        let t = max(0, min(1, progress))
        if t == 0 { return a }; if t == 1 { return b }
        func blend(_ a: Float, _ b: Float) -> Float { a + (b - a) * t }
        return SceneState(cloud: blend(a.cloud, b.cloud), rain: blend(a.rain, b.rain),
                          snow: blend(a.snow, b.snow), fog: blend(a.fog, b.fog),
                          storm: blend(a.storm, b.storm), wind: blend(a.wind, b.wind),
                          windDirection: blend(a.windDirection, b.windDirection),
                          solar: .interpolate(from: a.solar, to: b.solar, progress: t),
                          cloudPresentation: a.cloudPresentation == nil && b.cloudPresentation == nil ? nil
                             : .interpolate(a.cloudPresentation ?? .generic, b.cloudPresentation ?? .generic, progress: t),
                          sunGlare: blend(a.sunGlare,b.sunGlare))
    }
}

public struct SceneTransition: Sendable {
    private var start: SceneState
    private var target: SceneState
    private var beganAt: TimeInterval
    public var duration: TimeInterval

    public init(scene: SceneState, at time: TimeInterval = 0, duration: TimeInterval = 6) {
        start = scene
        target = scene
        beganAt = time
        self.duration = duration
    }

    public mutating func setTarget(_ scene: SceneState, at time: TimeInterval, immediate: Bool = false) {
        start = immediate ? scene : value(at: time)
        target = scene
        beganAt = time
    }

    public func value(at time: TimeInterval) -> SceneState {
        let t = Float(max(0, min(1, (time - beganAt) / max(0.001, duration))))
        return .interpolate(from: start, to: target, progress: t * t * (3 - 2 * t))
    }

    public func isActive(at time: TimeInterval) -> Bool {
        start != target && time - beganAt < duration
    }
}
