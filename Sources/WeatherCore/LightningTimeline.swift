import Foundation

public struct LightningSample: Equatable, Sendable {
    public var origin: Float = 0.6
    public var seed: Float = 0
    public var intensity: Float = 0
    public var reach: Float = 0.88
    public var progress: Float = 1
    public init(origin: Float = 0.6, seed: Float = 0, intensity: Float = 0, reach: Float = 0.88, progress: Float = 1) {
        self.origin = origin; self.seed = seed; self.intensity = intensity; self.reach = reach
        self.progress = progress
    }
}

/// Event-driven geometry seeds and irregular intervals; no repeating sine-wave bolt.
public struct LightningTimeline: Sendable {
    private var random: UInt64 = 0x57EA_7A11
    private var nextStrike: TimeInterval = 7
    private var strikeAt: TimeInterval = -.infinity
    private var strike = LightningSample()

    public init() {}

    public mutating func sample(at seconds: TimeInterval, storm: Float, enabled: Bool) -> LightningSample {
        guard enabled && storm > 0.05 else {
            nextStrike = seconds + 7
            strikeAt = -.infinity
            return LightningSample()
        }
        if seconds >= nextStrike {
            strikeAt = seconds
            strike = LightningSample(origin: 0.18 + unit() * 0.64, seed: unit() * 1000,
                                      intensity: 1, reach: 0.84 + unit() * 0.10)
            nextStrike = seconds + 14 + Double(unit()) * 27
        }
        let age = seconds - strikeAt
        guard age >= 0 && age < 0.8 else { return LightningSample() }
        var result = strike
        // Smooth, bounded illumination with a faint return stroke rather than strobing.
        let initial = exp(-age * 9) * (1 - exp(-age * 55))
        let echo = exp(-pow((age - 0.23) / 0.055, 2)) * 0.22
        result.intensity = Float(min(0.8, initial + echo)) * storm
        result.progress = min(1, Float(age / 0.06))
        return result
    }

    private mutating func unit() -> Float {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        return Float((random >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
    }
}
