import Foundation

/// Model layer fractions, not observed genera. Provider bands: <3 km, 3–8 km, >8 km.
public struct CloudLayerCoverage: Codable, Equatable, Sendable {
    public let validAt: Date
    public let low: Double?
    public let middle: Double?
    public let high: Double?

    public init(validAt: Date, low: Double?, middle: Double?, high: Double?) {
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, (0...1).contains(value) else { return nil }
            return value
        }
        self.validAt = validAt
        self.low = valid(low); self.middle = valid(middle); self.high = valid(high)
    }

    private enum CodingKeys: String, CodingKey { case validAt, low, middle, high }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(validAt: try values.decode(Date.self,forKey: .validAt),
            low: try? values.decode(Double.self,forKey: .low), middle: try? values.decode(Double.self,forKey: .middle),
            high: try? values.decode(Double.self,forKey: .high))
    }

    public var hasKnownLayer: Bool { low != nil || middle != nil || high != nil }
    public func isUsable(at date: Date) -> Bool {
        hasKnownLayer && date.timeIntervalSince(validAt) >= -300 && date.timeIntervalSince(validAt) <= 75 * 60
    }
}

public enum CloudGenus: String, CaseIterable, Codable, Identifiable, Sendable {
    case cirrus, cirrocumulus, cirrostratus, altocumulus, altostratus
    case nimbostratus, stratocumulus, stratus, cumulus, cumulonimbus
    public var id: String { rawValue }
    public var title: String {
        if self == .cumulus { return "Raised Stratocumulus" }
        return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    public static func eligiblePreviews(for kind: WeatherKind) -> [CloudGenus] {
        switch kind {
        case .clear: [.cirrus, .cirrocumulus, .cirrostratus]
        case .partlyCloudy, .windy: [.cirrus, .cirrocumulus, .cirrostratus, .altocumulus, .altostratus, .stratocumulus, .cumulus]
        case .cloudy: [.cirrostratus, .altostratus, .stratocumulus, .stratus]
        case .rain, .sleet: [.nimbostratus]
        case .snow: [.nimbostratus, .stratus]
        case .thunderstorm: [.cumulonimbus]
        case .fog: [.stratus]
        }
    }
}

/// Development subtypes, not additional WMO genera. Explicit scenes are illustrative.
public enum CloudDevelopment: String, CaseIterable, Codable, Identifiable, Sendable {
    case toweringCumulus, developingThunderstorm
    public var id: String { rawValue }
    public var title: String {
        self == .toweringCumulus ? "Towering Cumulus" : "Developing Thunderstorm"
    }
    public static func eligiblePreviews(for kind: WeatherKind) -> [CloudDevelopment] {
        switch kind {
        case .partlyCloudy, .windy: [.toweringCumulus]
        case .thunderstorm: [.developingThunderstorm]
        default: []
        }
    }
}

/// Continuous, low-cost visual parameters. Live selection never claims an observed genus.
public struct CloudPresentation: Equatable, Sendable {
    public var shape: SIMD4<Float> // base height, depth, relative element frequency, sheet amount
    public var erosion: Float
    public var density: Float
    public var opaque: Float
    public var volumeFraction: Float
    public var highFraction: Float
    public var upperStyle: SIMD3<Float> // wisps, small ripples, veil; normalized weights
    public var convection: SIMD2<Float> = .zero // bounded tower mass, development (congestus → developing Cb)

    // Ordinary low clouds now use stratocumulus styling. Keep the former
    // cumulus vertical thickness (1.1), raise its base 1.15 → 1.55, and otherwise
    // match stratocumulus frequency/sheet/erosion. Existing saved genus keys work.
    public static let generic = CloudPresentation(shape: SIMD4(1.55, 1.1, 0.85, 0.65), erosion: 0.055,
        density: 38, opaque: 0, volumeFraction: 1, highFraction: 0, upperStyle: SIMD3(1,0,0))

    public static func profile(_ genus: CloudGenus) -> CloudPresentation {
        var value = generic
        switch genus {
        case .cirrus, .cirrocumulus, .cirrostratus:
            value.volumeFraction = 0; value.highFraction = 1
            value.upperStyle = genus == .cirrus ? SIMD3(1,0,0) : (genus == .cirrocumulus ? SIMD3(0,1,0) : SIMD3(0,0,1))
        case .cumulus: break // Retained compatible key for the raised stratocumulus-style look.
        case .stratocumulus:
            value.shape = SIMD4(1.05,0.70,0.85,0.65); value.erosion = 0.055
        case .stratus:
            value.shape = SIMD4(0.90,0.50,0.50,1); value.erosion = 0.015; value.density = 30
        case .altocumulus:
            value.shape = SIMD4(1.80,0.75,2.3,0.35); value.erosion = 0.06; value.density = 34
        case .altostratus:
            value.shape = SIMD4(1.80,0.65,0.65,0.90); value.erosion = 0.015; value.density = 28
        case .nimbostratus:
            value.shape = SIMD4(1.05,1.1,0.60,0.90); value.erosion = 0.035; value.density = 30; value.opaque = 1
        case .cumulonimbus:
            value.shape = SIMD4(1.05,1.8,0.85,0.25); value.erosion = 0.035; value.density = 32; value.opaque = 1
        }
        return value
    }

    public static func weatherProfile(_ kind: WeatherKind) -> CloudPresentation {
        switch kind {
        case .clear:
            var value = generic; value.volumeFraction = 0; return value
        case .partlyCloudy: return .profile(.cumulus)
        case .cloudy, .windy: return .profile(.stratocumulus)
        case .rain, .snow, .sleet: return .profile(.nimbostratus)
        case .thunderstorm: return .profile(.cumulonimbus)
        case .fog: return .profile(.stratus)
        }
    }

    public static func developing(_ development: CloudDevelopment) -> CloudPresentation {
        var value = profile(development == .toweringCumulus ? .cumulus : .cumulonimbus)
        // Development adds a background, not an isolated cloud showcase. Preserve
        // ordinary raised bank foreground; the developing storm keeps a broken base.
        // Live data never takes this path or has its reported cover reduced here.
        value.volumeFraction = development == .toweringCumulus ? 1 : 0.65
        value.opaque = 0
        value.convection = SIMD2(1, development == .toweringCumulus ? 0.55 : 0.95)
        return value
    }

    public static func live(snapshot: WeatherSnapshot, at date: Date) -> CloudPresentation {
        var value = generic // Unknown layers: a conservative main layer, no invented cirrus.
        let code = snapshot.weatherCode ?? -1
        if snapshot.kind == .thunderstorm { value = .profile(.cumulonimbus) }
        else if [51,53,55,56,57,77].contains(code) || snapshot.kind == .fog { value = .profile(.stratus) }
        else if [61,63,65,66,67,71,73,75].contains(code), snapshot.cloudCover >= 0.65 {
            value = .profile(.nimbostratus)
        }
        guard let layers = snapshot.cloudLayers, layers.isUsable(at: date) else { return value }
        let total = max(0.001, snapshot.cloudCover)
        if let low = layers.low, let middle = layers.middle {
            let main = max(low,middle) // Layer fractions overlap; never add their percentages.
            value.volumeFraction = Float(min(1,main / total))
            if snapshot.kind != .thunderstorm && value.opaque == 0 && ![51,53,55,56,57,77].contains(code) && snapshot.kind != .fog {
                // Continuous morphology weights avoid genus-flapping around a threshold.
                let lower = interpolate(generic,profile(.stratocumulus),progress: Float((low - 0.45) / 0.35))
                let upper = interpolate(profile(.altocumulus),profile(.altostratus),progress: Float((middle - 0.55) / 0.30))
                let lowDominance = max((low - middle + 0.10) / 0.20,(low - 0.50) / 0.20)
                let selected = interpolate(upper,lower,progress: Float(lowDominance))
                value.shape = selected.shape; value.erosion = selected.erosion; value.density = selected.density
            }
        }
        if let high = layers.high {
            value.highFraction = Float(min(1,high / total))
            // High cover supports a generic wispy-to-veil blend, not an inferred cirrocumulus observation.
            let veil = Float(max(0,min(1,(high - 0.50) / 0.40)))
            value.upperStyle = SIMD3(1 - veil,0,veil)
        }
        let thunder = snapshot.kind == .thunderstorm && [95,96,99].contains(code)
        let showers = snapshot.kind == .rain && [80,81,82].contains(code)
            && snapshot.precipitationMillimetersPerHour >= 0.1
        let age = date.timeIntervalSince(snapshot.observedAt)
        if (thunder || showers), !snapshot.isStale(at: date), (-300...4500).contains(age),
           let low = layers.low, let middle = layers.middle {
            func ramp(_ x: Double, _ a: Double, _ b: Double) -> Float {
                let t = Float(max(0,min(1,(x-a)/(b-a)))); return t*t*(3-2*t)
            }
            // No tower inference from ordinary partly cloudy skies, high-only cover,
            // missing layers, stale conditions or poor visibility. No invented rain.
            let evidence = ramp(low,0.18,0.48) * ramp(middle,0.12,0.42)
                * ramp(snapshot.cloudCover,0.30,0.60) * ramp(snapshot.visibilityMeters,3000,10000)
            value.convection = SIMD2(evidence * (thunder ? 1 : 0.75), thunder ? 0.95 : 0.55)
        }
        return value
    }

    public static func interpolate(_ a: CloudPresentation, _ b: CloudPresentation, progress: Float) -> CloudPresentation {
        let t = max(0,min(1,progress))
        if t == 0 { return a }; if t == 1 { return b }
        func blend(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        return CloudPresentation(shape: a.shape + (b.shape - a.shape) * t,
            erosion: blend(a.erosion,b.erosion), density: blend(a.density,b.density), opaque: blend(a.opaque,b.opaque),
            volumeFraction: blend(a.volumeFraction,b.volumeFraction), highFraction: blend(a.highFraction,b.highFraction),
            upperStyle: a.upperStyle + (b.upperStyle - a.upperStyle) * t,
            convection: a.convection + (b.convection - a.convection) * t)
    }
}
