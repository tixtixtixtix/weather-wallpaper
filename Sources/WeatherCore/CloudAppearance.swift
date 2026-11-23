import Foundation

/// Artistic cloud structure, distinct from the provider's reported fractional cover.
/// Rain thickens banks continuously; storms add deeper convection even between showers.
public struct CloudAppearance: Equatable, Sendable {
    public let coverage: Float
    public let opticalDepth: Float
    public let wetness: Float
    public let cirrus: Float
    public let volumeCoverage: Float
    public let presentation: CloudPresentation

    public init(scene: SceneState) {
        let cover = max(0, min(1, scene.cloud))
        let rain = max(0, min(1, scene.rain))
        let snow = max(0, min(1, scene.snow))
        let storm = max(0, min(1, scene.storm))
        let buildup = min(1, rain * 0.65 + snow * 0.25 + storm * 0.85)
        coverage = cover + (1 - cover) * buildup
        opticalDepth = 1 + rain * 1.9 + snow * 0.5 + storm * 2.2
        wetness = min(1, rain * 1.1 + snow * 0.2 + storm)
        presentation = scene.cloudPresentation ?? .generic
        volumeCoverage = coverage * presentation.volumeFraction
        // High clouds need explicit layer evidence or an illustrative preview selection.
        cirrus = min(1,cover * presentation.highFraction) * pow(max(0,1 - scene.fog),2)
    }
}
