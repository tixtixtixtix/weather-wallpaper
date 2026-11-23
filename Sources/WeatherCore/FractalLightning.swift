import Foundation

public struct LightningSegment: Equatable, Sendable {
    public let start: SIMD2<Float>
    public let end: SIMD2<Float>
    public let width: Float
    public let brightness: Float
}

/// Seeded, multi-scale midpoint displacement with a tapered branching hierarchy.
/// Geometry is built at strike onset, never regenerated on every animation frame.
public enum FractalLightning {
    public static let maximumSegments = 96
    public static let trunkSegmentCount = 32

    public static func segments(for strike: LightningSample) -> [LightningSegment] {
        guard strike.seed.isFinite, strike.origin.isFinite, strike.reach.isFinite else { return [] }
        var builder = Builder(seed: UInt64(abs(Double(strike.seed)).truncatingRemainder(dividingBy: 1_000_000) * 65536) &+ 1)
        let start = SIMD2(max(0.05, min(0.95, strike.origin)), 0.065 + builder.unit() * 0.035)
        let reach = max(0.15, min(0.94, strike.reach))
        let end = SIMD2(start.x + builder.signed() * 0.12, min(0.98, start.y + reach))
        let trunk = builder.path(from: start, to: end, displacement: reach * 0.085, levels: 5)
        builder.append(trunk, width: 0.0025, brightness: 1)
        // A readable main channel with a few forks, not a dense web of fine streamers.
        for branch in 0..<3 {
            let anchor = (Float(branch) * 0.618034 + builder.unit() * 0.10).truncatingRemainder(dividingBy: 1)
            let index = 5 + Int(anchor * Float(trunk.count - 12))
            let root = trunk[min(index, trunk.count - 2)]
            let side: Float = (branch % 2 == 0 ? -1 : 1) * (builder.unit() < 0.15 ? -1 : 1)
            let length = (0.12 + builder.unit() * 0.14) * reach
            let tip = SIMD2(max(-0.08, min(1.08, root.x + side * length * (0.6 + builder.unit()))),
                            min(0.99, root.y + length * (0.6 + builder.unit() * 0.7)))
            let points = builder.path(from: root, to: tip, displacement: length * 0.14, levels: 4)
            builder.append(points, width: 0.0013, brightness: 0.47 + builder.unit() * 0.19)
        }
        return builder.segments
    }

    private struct Builder {
        var seed: UInt64
        var segments: [LightningSegment] = []
        init(seed: UInt64) { self.seed = seed; segments.reserveCapacity(maximumSegments) }

        mutating func unit() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        mutating func signed() -> Float { unit() * 2 - 1 }

        mutating func path(from start: SIMD2<Float>, to end: SIMD2<Float>, displacement: Float,
                           levels: Int) -> [SIMD2<Float>] {
            var points = [start, end]
            var amplitude = displacement
            for _ in 0..<levels {
                var refined: [SIMD2<Float>] = []
                refined.reserveCapacity(points.count * 2 - 1)
                for index in 0..<(points.count - 1) {
                    let a = points[index], b = points[index + 1]
                    let delta = b - a
                    let length = max(0.00001, sqrt(delta.x * delta.x + delta.y * delta.y))
                    let perpendicular = SIMD2(-delta.y, delta.x) / length
                    // Several bounded samples approximate a Gaussian displacement.
                    let gaussian = (signed() + signed() + signed()) / 1.7
                    let midpoint = (a + b) * 0.5 + perpendicular * amplitude * gaussian
                    refined.append(a)
                    refined.append(midpoint)
                }
                refined.append(end)
                points = refined
                amplitude *= 0.48 // Suppress tiny zigzags while retaining broad natural bends.
            }
            return points
        }

        mutating func append(_ points: [SIMD2<Float>], width: Float, brightness: Float) {
            for i in 0..<(points.count - 1) where segments.count < maximumSegments {
                let t = Float(i) / Float(max(1, points.count - 2))
                segments.append(LightningSegment(start: points[i], end: points[i + 1],
                    width: width * (1 - t * 0.48), brightness: brightness * (1 - t * 0.28)))
            }
        }
    }
}
