import Foundation

public enum PreviewMoonPhase: String, CaseIterable, Codable, Identifiable, Sendable {
    case newMoon, waxingCrescent, firstQuarter, waxingGibbous, fullMoon, waningGibbous, lastQuarter, waningCrescent
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .newMoon: "New Moon"
        case .waxingCrescent: "Waxing Crescent"
        case .firstQuarter: "First Quarter"
        case .waxingGibbous: "Waxing Gibbous"
        case .fullMoon: "Full Moon"
        case .waningGibbous: "Waning Gibbous"
        case .lastQuarter: "Last Quarter"
        case .waningCrescent: "Waning Crescent"
        }
    }
    public var lightDirection: SIMD3<Float> {
        let angle = Float(Self.allCases.firstIndex(of: self)!) / 8 * 2 * .pi
        return SIMD3(sin(angle) * 0.985, sin(angle) * 0.173, -cos(angle))
    }
    public var illumination: Float { (1 + lightDirection.z) / 2 }
}

public struct MoonState: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var lightDirection: SIMD3<Float>
    public var rotation: Float
    public var visibility: Float
    public var altitudeDegrees: Float
    public var azimuthDegrees: Float

    public static let hidden = MoonState(position: SIMD2(0.3, 0.3), lightDirection: SIMD3(0, 0, 1),
                                         rotation: 0, visibility: 0, altitudeDegrees: -90)

    public init(position: SIMD2<Float>, lightDirection: SIMD3<Float>, rotation: Float,
                visibility: Float, altitudeDegrees: Float, azimuthDegrees: Float = 180) {
        self.position = position
        self.lightDirection = lightDirection
        self.rotation = rotation
        self.visibility = visibility
        self.altitudeDegrees = altitudeDegrees
        self.azimuthDegrees = azimuthDegrees
    }
}

public enum LunarCalculator {
    /// Truncated lunar theory with the dominant longitude/latitude perturbations and
    /// topocentric parallax. Adequate for a sky illustration, not telescope pointing.
    /// Angles follow Meeus' ecliptic/equatorial conventions; all dates are absolute UTC.
    public static func state(at date: Date, latitude: Double, longitude: Double) -> (moon: MoonState, illumination: Float) {
        let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545
        let l = rad(218.3164477 + 13.17639648 * d)
        let m = rad(134.9633964 + 13.06499295 * d)
        let f = rad(93.2720950 + 13.22935024 * d)
        let elongation = rad(297.8501921 + 12.19074912 * d)
        let sunM = rad(357.5291092 + 0.98560028 * d)
        let moonLongitude = l + rad(6.289 * sin(m) + 1.274 * sin(2 * elongation - m)
            + 0.658 * sin(2 * elongation) + 0.214 * sin(2 * m) - 0.186 * sin(sunM)
            - 0.114 * sin(2 * f) + 0.059 * sin(2 * elongation - 2 * m)
            + 0.057 * sin(2 * elongation - sunM - m) + 0.053 * sin(2 * elongation + m)
            + 0.046 * sin(2 * elongation - sunM) - 0.041 * sin(sunM - m)
            - 0.035 * sin(elongation) - 0.030 * sin(sunM + m)
            + 0.015 * sin(2 * elongation - 2 * f) - 0.013 * sin(m + 2 * f)
            + 0.011 * sin(m - 2 * f) + 0.011 * sin(4 * elongation - m))
        let moonLatitude = rad(5.128 * sin(f) + 0.280 * sin(m + f) + 0.277 * sin(m - f)
            + 0.173 * sin(2 * elongation - f) + 0.055 * sin(2 * elongation + f - m)
            + 0.046 * sin(2 * elongation - f - m))
        let distance = 385000.56 - 20905 * cos(m) - 3699 * cos(2 * elongation - m)
            - 2956 * cos(2 * elongation) - 570 * cos(2 * m)
        let obliquity = rad(23.439291 - d * 0.000000356)
        let geocentric = equatorial(longitude: moonLongitude, latitude: moonLatitude, obliquity: obliquity)
        let sidereal = rad(280.46061837 + 360.98564736629 * d + longitude)
        let lat = rad(max(-89.999, min(89.999, latitude)))
        let reducedLat = atan(0.99664719 * tan(lat))
        let observer = SIMD3(cos(reducedLat) * cos(sidereal), cos(reducedLat) * sin(sidereal),
                             0.99664719 * sin(reducedLat)) * 6378.14
        let topocentric = geocentric * distance - observer
        let ra = atan2(topocentric.y, topocentric.x)
        let dec = atan2(topocentric.z, hypot(topocentric.x, topocentric.y))
        let h = sidereal - ra
        let altitude = asin(clamp(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(h)))
        let azimuth = positive(atan2(sin(h), cos(h) * sin(lat) - tan(dec) * cos(lat)) + .pi)
        let sunLongitude = rad(280.46646 + 0.98564736 * d) + rad(1.9148 * sin(sunM) + 0.0200 * sin(2 * sunM))
        let sun = equatorial(longitude: sunLongitude, latitude: 0, obliquity: obliquity)
        let sunRA = atan2(sun.y, sun.x), sunDec = asin(sun.z)
        let phi = acos(clamp(sun.x * geocentric.x + sun.y * geocentric.y + sun.z * geocentric.z))
        let phase = atan2(149_598_000 * sin(phi), distance - 149_598_000 * cos(phi))
        let illumination = (1 + cos(phase)) / 2
        let limb = atan2(cos(sunDec) * sin(sunRA - ra),
                         sin(sunDec) * cos(dec) - cos(sunDec) * sin(dec) * cos(sunRA - ra))
        let parallactic = atan2(sin(h), tan(lat) * cos(dec) - sin(dec) * cos(h))
        let angle = limb - parallactic
        let elevation = altitude * 180 / .pi
        let horizonFade = smooth(-0.3, 1.5, elevation + SkyProjection.refraction(at: elevation))
        let visiblePhase = smooth(0.005, 0.04, illumination)
        let moon = MoonState(
            position: SkyProjection.position(azimuthDegrees: azimuth * 180 / .pi, altitudeDegrees: elevation),
            lightDirection: SIMD3(Float(sin(angle) * sin(phase)), Float(cos(angle) * sin(phase)), Float(cos(phase))),
            rotation: Float(parallactic), visibility: Float(horizonFade * visiblePhase), altitudeDegrees: Float(elevation),
            azimuthDegrees: Float(azimuth * 180 / .pi)
        )
        return (moon, Float(illumination))
    }

    private static func equatorial(longitude l: Double, latitude b: Double, obliquity e: Double) -> SIMD3<Double> {
        SIMD3(cos(b) * cos(l), cos(e) * cos(b) * sin(l) - sin(e) * sin(b),
              sin(e) * cos(b) * sin(l) + cos(e) * sin(b))
    }
    private static func rad(_ degrees: Double) -> Double { degrees.truncatingRemainder(dividingBy: 360) * .pi / 180 }
    private static func positive(_ radians: Double) -> Double {
        let value = radians.truncatingRemainder(dividingBy: 2 * .pi)
        return value < 0 ? value + 2 * .pi : value
    }
    private static func clamp(_ value: Double) -> Double { max(-1, min(1, value)) }
    private static func smooth(_ a: Double, _ b: Double, _ value: Double) -> Double {
        let t = max(0, min(1, (value - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
