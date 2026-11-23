import Foundation
import simd

/// Separate 32-byte fragment buffer; ShaderUniforms keeps its existing layout.
struct MoonlitHazeUniforms {
    var appearance: SIMD4<Float> // strength, expanded fraction, center x, top anchor y
    var motion: SIMD4<Float> // two independent periodic texture translations
    static let disabled = MoonlitHazeUniforms(strength: 0,expansion: 1,seconds: 0)

    init(configuration: NotchHazeConfiguration,seconds: TimeInterval = 0) {
        let configuration = configuration.sanitized
        self.init(strength: configuration.enabled ? configuration.intensity : 0,
                  expansion: configuration.layout == .expanded ? 1 : 0,seconds: seconds)
    }

    init(strength: Float,expansion: Float,seconds: TimeInterval) {
        appearance = SIMD4(strength.isFinite ? min(1,max(0,strength)) : 0,
                           expansion.isFinite ? min(1,max(0,expansion)) : 1,0.5,0)
        func phase(_ rate: Double) -> Float {
            let value = (seconds.isFinite ? seconds : 0)*rate
            let wrapped = Float(value-floor(value))
            return wrapped >= 1 ? 0 : wrapped
        }
        // Each translation wraps by exactly one texture period. Do not derive
        // one layer from an already-wrapped phase: that would cause a seam.
        motion = SIMD4(phase(0.000080),phase(0.000027),phase(-0.000043),phase(0.000061))
    }
}

/// Uses the existing scene clock, not a timer or SwiftUI animation driver.
struct NotchHazeTransition {
    private var start: SIMD2<Float> = .zero
    private var target: SIMD2<Float>?
    private var began: TimeInterval = 0
    private let duration: TimeInterval = 0.65

    mutating func value(configuration: NotchHazeConfiguration,at seconds: TimeInterval,animated: Bool) -> SIMD2<Float> {
        let configuration = configuration.sanitized
        let next = SIMD2(configuration.enabled ? configuration.intensity : 0,
                         configuration.layout == .expanded ? 1 : 0)
        if target == nil || !animated || seconds < began {
            start = next; target = next; began = seconds
            return next
        }
        let current = interpolated(at: seconds)
        if next != target {
            start = current; target = next; began = seconds
            return current
        }
        return current
    }

    func isTransitioning(at seconds: TimeInterval) -> Bool {
        guard let target, start != target else { return false }
        return seconds >= began && seconds - began < duration
    }

    private func interpolated(at seconds: TimeInterval) -> SIMD2<Float> {
        let progress = Float(min(1,max(0,(seconds-began)/duration)))
        let eased = progress*progress*(3-2*progress)
        return start+((target ?? start)-start)*eased
    }
}
