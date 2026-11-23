import Foundation

/// A bounded sporadic meteor, in viewport-height units (x and y use the same metric).
/// No particle simulation, unbounded shader clocks or full-screen random sampling.
public struct MeteorAppearance: Equatable, Sendable {
    public let head: SIMD2<Float>
    public let direction: SIMD2<Float>
    public let trainLength: Float
    public let intensity: Float
    public let speed: Float

    public static func sample(at seconds: TimeInterval, aspect: Float, speed: Float = 1) -> MeteorAppearance? {
        guard seconds.isFinite, seconds >= 0, aspect.isFinite, aspect > 0 else { return nil }
        let cycle = floor(seconds / 7)
        // Integer hashing is stable across machines and does not lose precision after days.
        var seed = UInt64(cycle.truncatingRemainder(dividingBy: 1_000_000)) &+ 91
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 40) & 0xffffff) / Float(0xffffff)
        }
        let occurs = random()
        let startX = random(), startY = random(), variation = random(), magnitude = random()
        guard occurs < 0.72 else { return nil }
        let multiplier = speed.isFinite ? max(0.25, min(2.5, speed)) : 1
        let duration = Double(0.65 / multiplier)
        let age = seconds - cycle * 7 - 0.18
        guard age > 0, age < duration else { return nil }
        let progress = Float(age / duration)
        // Equal x/y screen velocity. Variety comes from placement/magnitude, not distortion.
        let direction = SIMD2<Float>(-0.70710678, 0.70710678)
        let travel = progress * (0.43 + variation * 0.08)
        let head = SIMD2<Float>((0.38 + startX * 0.50) * aspect, 0.10 + startY * 0.20) + direction * travel
        let ignition = min(1, Float(age) / 0.035)
        let fade = max(0, min(1, (1 - progress) / 0.18))
        let envelope = ignition * ignition * (3 - 2 * ignition) * fade * fade * (3 - 2 * fade)
        return MeteorAppearance(head: head, direction: direction,
            trainLength: min(0.085, travel * 0.65), intensity: envelope * (0.50 + magnitude * 0.35),
            speed: (0.43 + variation * 0.08) / Float(duration))
    }
}
