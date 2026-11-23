import Foundation

public struct SolarState: Equatable, Sendable {
    public var daylight: Float
    public var twilight: Float
    public var sunPosition: SIMD2<Float>
    public var moonIllumination: Float
    public var moon: MoonState

    public init(daylight: Float, twilight: Float, sunPosition: SIMD2<Float>, moonIllumination: Float,
                moon: MoonState = .hidden) {
        self.daylight = daylight
        self.twilight = twilight
        self.sunPosition = sunPosition
        self.moonIllumination = moonIllumination
        self.moon = moon
    }

    public static func preview(_ time: PreviewTime, phase: PreviewMoonPhase = .waxingGibbous) -> SolarState {
        let moon = MoonState(position: time == .night ? SIMD2(0.68, 0.25) : SIMD2(0.30, 0.34),
                             lightDirection: phase.lightDirection, rotation: -0.18,
                             visibility: phase == .newMoon ? 0 : 1, altitudeDegrees: 45)
        switch time {
        case .dawn: return SolarState(daylight: 0.28, twilight: 0.95, sunPosition: SIMD2(0.2, 0.81), moonIllumination: phase.illumination, moon: moon)
        case .day: return SolarState(daylight: 1, twilight: 0, sunPosition: SIMD2(0.72, 0.23), moonIllumination: phase.illumination, moon: moon)
        case .dusk: return SolarState(daylight: 0.22, twilight: 1, sunPosition: SIMD2(0.82, 0.83), moonIllumination: phase.illumination, moon: moon)
        case .night: return SolarState(daylight: 0, twilight: 0, sunPosition: SIMD2(0.7, 1.2), moonIllumination: phase.illumination, moon: moon)
        }
    }

    public static func interpolate(from a: SolarState, to b: SolarState, progress: Float) -> SolarState {
        let t = max(0, min(1, progress))
        if t == 0 { return a }; if t == 1 { return b }
        func blend(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        func angle(_ x: Float, _ y: Float, period: Float) -> Float {
            var delta = (y - x).truncatingRemainder(dividingBy: period)
            if delta > period / 2 { delta -= period }
            if delta < -period / 2 { delta += period }
            return x + delta * t
        }
        return SolarState(daylight: blend(a.daylight, b.daylight), twilight: blend(a.twilight, b.twilight),
            sunPosition: SIMD2(angle(a.sunPosition.x, b.sunPosition.x, period: 1), blend(a.sunPosition.y, b.sunPosition.y)),
            moonIllumination: blend(a.moonIllumination, b.moonIllumination),
            moon: MoonState(position: SIMD2(angle(a.moon.position.x, b.moon.position.x, period: 1),
                                           blend(a.moon.position.y, b.moon.position.y)),
                lightDirection: a.moon.lightDirection + (b.moon.lightDirection - a.moon.lightDirection) * t,
                rotation: angle(a.moon.rotation, b.moon.rotation, period: 2 * .pi),
                visibility: blend(a.moon.visibility, b.moon.visibility),
                altitudeDegrees: blend(a.moon.altitudeDegrees, b.moon.altitudeDegrees),
                azimuthDegrees: angle(a.moon.azimuthDegrees, b.moon.azimuthDegrees, period: 360)))
    }
}

public enum PreviewTime: String, CaseIterable, Identifiable, Codable, Sendable {
    case dawn, day, dusk, night
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum SolarCalculator {
    /// NOAA's approximate solar coordinates, evaluated in UTC. Handles polar day/night and
    /// cities across the date line without relying on the Mac's local time zone.
    public static func state(at date: Date, latitude: Double, longitude: Double) -> SolarState {
        let julianDay = date.timeIntervalSince1970 / 86400 + 2440587.5
        let centuries = (julianDay - 2451545) / 36525
        let meanLongitude = (280.46646 + centuries * (36000.76983 + centuries * 0.0003032))
            .truncatingRemainder(dividingBy: 360)
        let anomaly = radians(357.52911 + centuries * (35999.05029 - 0.0001537 * centuries))
        let eccentricity = 0.016708634 - centuries * (0.000042037 + 0.0000001267 * centuries)
        let center = sin(anomaly) * (1.914602 - centuries * (0.004817 + 0.000014 * centuries))
            + sin(2 * anomaly) * (0.019993 - 0.000101 * centuries) + sin(3 * anomaly) * 0.000289
        let omega = radians(125.04 - 1934.136 * centuries)
        let apparentLongitude = radians(meanLongitude + center - 0.00569 - 0.00478 * sin(omega))
        let obliquity = radians(23 + (26 + (21.448 - centuries * (46.815 + centuries *
            (0.00059 - centuries * 0.001813))) / 60) / 60 + 0.00256 * cos(omega))
        let declination = asin(sin(obliquity) * sin(apparentLongitude))
        let y = pow(tan(obliquity / 2), 2)
        let l = radians(meanLongitude)
        let equation = 4 * degrees(y * sin(2 * l) - 2 * eccentricity * sin(anomaly)
            + 4 * eccentricity * y * sin(anomaly) * cos(2 * l)
            - 0.5 * y * y * sin(4 * l) - 1.25 * eccentricity * eccentricity * sin(2 * anomaly))
        let utcMinutes = positiveModulo(date.timeIntervalSince1970, 86400) / 60
        let solarMinutes = positiveModulo(utcMinutes + equation + 4 * longitude, 1440)
        let hourAngle = solarMinutes / 4 - 180
        let lat = radians(max(-90, min(90, latitude)))
        let elevation = degrees(asin(max(-1, min(1, sin(lat) * sin(declination)
            + cos(lat) * cos(declination) * cos(radians(hourAngle))))))
        let daylight = smoothstep(-6, 8, elevation)
        let twilight = exp(-pow((elevation + 1.5) / 7, 2))
        let azimuth = positiveModulo(atan2(sin(radians(hourAngle)), cos(radians(hourAngle)) * sin(lat)
            - tan(declination) * cos(lat)) + .pi, 2 * .pi)
        let lunar = LunarCalculator.state(at: date, latitude: latitude, longitude: longitude)
        return SolarState(daylight: Float(daylight), twilight: Float(twilight),
                          sunPosition: SkyProjection.position(azimuthDegrees: degrees(azimuth), altitudeDegrees: elevation),
                          moonIllumination: lunar.illumination, moon: lunar.moon)
    }

    private static func radians(_ value: Double) -> Double { value * .pi / 180 }
    private static func degrees(_ value: Double) -> Double { value * 180 / .pi }
    private static func positiveModulo(_ value: Double, _ divisor: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder < 0 ? remainder + divisor : remainder
    }
    private static func smoothstep(_ a: Double, _ b: Double, _ value: Double) -> Double {
        let t = max(0, min(1, (value - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
