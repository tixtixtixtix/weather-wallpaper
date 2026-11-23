import Foundation

/// A consistent 360° sky panorama: azimuth runs left-to-right, apparent altitude
/// follows the projected dome. It isn't a calibrated camera field of view.
public enum SkyProjection {
    /// Inverse panorama mapping shared with the cloud shader. x=east, y=up, z=north.
    /// Input altitude includes apparent refraction when produced by `position`.
    public static func direction(at position: SIMD2<Float>) -> SIMD3<Float> {
        let azimuth = position.x * 2 * Float.pi
        let vertical = max(-1, min(1, (0.97 - position.y) / 0.90))
        let horizontal = sqrt(max(0, 1 - vertical * vertical))
        return SIMD3(sin(azimuth) * horizontal, vertical, cos(azimuth) * horizontal)
    }

    public static func position(azimuthDegrees: Double, altitudeDegrees: Double) -> SIMD2<Float> {
        let azimuth = azimuthDegrees.truncatingRemainder(dividingBy: 360)
        let x = (azimuth < 0 ? azimuth + 360 : azimuth) / 360
        let apparentAltitude = altitudeDegrees + refraction(at: altitudeDegrees)
        return SIMD2(Float(x), Float(0.97 - 0.90 * sin(apparentAltitude * .pi / 180)))
    }

    /// Bennett's standard-atmosphere approximation, used only for horizon appearance.
    public static func refraction(at altitude: Double) -> Double {
        guard altitude > -1, altitude < 89.9 else { return 0 }
        return 1.02 / tan((altitude + 10.3 / (altitude + 5.11)) * .pi / 180) / 60
    }
}
