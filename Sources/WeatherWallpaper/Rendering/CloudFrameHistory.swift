import Foundation
import Metal

/// Shared hard cap across preview + every display. No eviction churn or disk cache.
final class CloudHistoryBudget: @unchecked Sendable {
    let limit: Int
    private let lock = NSLock()
    private var used = 0

    init(limit: Int = 32 * 1024 * 1024) { self.limit = limit }
    var allocated: Int { lock.lock(); defer { lock.unlock() }; return used }
    func reserve(_ bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, bytes <= limit-used else { return false }
        used += bytes
        return true
    }
    func release(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        assert(bytes >= 0 && bytes <= used)
        used -= bytes
    }
}

struct CloudHistoryPipelines {
    let fresh: MTLRenderPipelineState
    let reproject: MTLRenderPipelineState
    let reprojectIce: MTLRenderPipelineState
}

/// Keep the reservation alive until every GPU command referencing the retired
/// textures completes, including resize/hide/deallocation with frames in flight.
final class CloudHistoryLease: @unchecked Sendable {
    private let budget: CloudHistoryBudget
    let bytes: Int
    init(budget: CloudHistoryBudget, bytes: Int) { self.budget = budget; self.bytes = bytes }
    deinit { budget.release(bytes) }
}

/// Experimental, one-fresh-frame cloud history. Reprojection never feeds itself.
/// All celestial bodies, bloom, precipitation and final composition remain current.
@MainActor
final class CloudFrameHistory {
    private let resources: MetalResources
    private let budget: CloudHistoryBudget
    let pipelines: CloudHistoryPipelines
    private(set) var color: MTLTexture?
    private(set) var depth: MTLTexture?
    private(set) var previous: ShaderUniforms?
    private var lease: CloudHistoryLease?
    var allocatedBytes: Int { lease?.bytes ?? 0 }
    private(set) var freshFrames = 0
    private(set) var reprojectedFrames = 0
    private var reused = false
    private var volume = false
    private(set) var generation = 0

    init?(resources: MetalResources, budget: CloudHistoryBudget? = nil) {
        guard let pipelines = try? resources.cloudHistoryPipelines.get() else { return nil }
        self.resources = resources
        self.pipelines = pipelines
        self.budget = budget ?? resources.cloudHistoryBudget
    }

    func invalidate() {
        color = nil; depth = nil; previous = nil; reused = false
        lease = nil
        generation += 1
    }

    static func eligible(_ u: ShaderUniforms) -> Bool {
        guard u.rendering.z == 1, u.rendering.x < 96, u.convection.x <= 0.001,
              u.lightning.z == 0, u.weather.x == 0, u.weather.y == 0, u.weather.z == 0,
              u.atmosphere.w < 0.98 else { return false }
        // Mixed high/low motion needs more than one representative depth. Do not
        // pretend that one cached surface can reconstruct every cloud layer.
        return (u.cloudStructure.z >= 0.55 && u.clouds.w <= 0.001)
            || (u.cloudStructure.z <= 0.075 && u.clouds.w > 0.001)
    }

    func prepare(_ u: ShaderUniforms, width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, Self.eligible(u) else { invalidate(); return false }
        let needsDepth = u.cloudStructure.z > 0.075
        if color?.width == width && color?.height == height && volume == needsDepth { return true }
        invalidate()
        // Reject oversized histories before allocating; allocatedSize is checked
        // again because Metal padding can exceed the texel-size estimate.
        let estimate = width * height * (needsDepth ? 10 : 8)
        guard estimate <= 16*1024*1024, budget.reserve(estimate) else { return false }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: width,height: height,mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget,.shaderRead]
        guard let image = resources.device.makeTexture(descriptor: descriptor) else { budget.release(estimate); return false }
        var metadata: MTLTexture?
        if needsDepth {
            descriptor.pixelFormat = .r16Float
            metadata = resources.device.makeTexture(descriptor: descriptor)
            if metadata == nil { budget.release(estimate); return false }
        }
        let actual = image.allocatedSize + (metadata?.allocatedSize ?? 0)
        if actual > 16*1024*1024 { budget.release(estimate); return false }
        if actual > estimate {
            guard budget.reserve(actual-estimate) else { budget.release(estimate); return false }
        } else { budget.release(estimate-actual) }
        color = image; depth = metadata; volume = needsDepth
        lease = CloudHistoryLease(budget: budget,bytes: actual)
        image.label = "One fresh cloud-history image (no feedback)"
        metadata?.label = "Cloud opacity-weighted mean distance"
        return true
    }

    private static func clock(_ u: ShaderUniforms) -> Double { Double(u.clock.x)+Double(u.viewport.z) }
    private static func phase(_ coarse: Float, _ fine: Float, _ rate: Float) -> Float {
        let value = coarse*rate
        return value-floor(value)+fine*rate
    }
    private static func transport(_ u: ShaderUniforms) -> SIMD2<Float> {
        SIMD2((phase(u.clock.y,u.options.z,0.003)+phase(u.clock.x,u.viewport.z,0.000162))/0.13,
              phase(u.clock.x,u.viewport.z,0.00003375)+phase(u.clock.y,u.options.z,0.0007))
    }
    private static func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, tolerance: Float) -> Bool {
        abs(a.x-b.x) <= tolerance && abs(a.y-b.y) <= tolerance
            && abs(a.z-b.z) <= tolerance && abs(a.w-b.w) <= tolerance
    }

    func canReuse(_ u: ShaderUniforms) -> Bool {
        guard let p = previous, color != nil, !reused, Self.eligible(u) else { return false }
        let age = Self.clock(u)-Self.clock(p)
        guard age > 0, age <= 0.075,
              u.viewport.x == p.viewport.x, u.viewport.y == p.viewport.y, u.viewport.w == p.viewport.w,
              u.rendering == p.rendering, u.weather == p.weather, u.clouds == p.clouds,
              u.morphology == p.morphology, u.cloudStructure == p.cloudStructure,
              u.upperStyle == p.upperStyle, u.atmosphere.z == p.atmosphere.z, u.atmosphere.w == p.atmosphere.w,
              (u.atmosphere.x > 0.02) == (p.atmosphere.x > 0.02),
              abs(u.atmosphere.x-p.atmosphere.x) < 0.0005, abs(u.atmosphere.y-p.atmosphere.y) < 0.0005,
              Self.close(u.celestial,p.celestial,tolerance: 0.0002), Self.close(u.moon,p.moon,tolerance: 0.0002),
              Self.close(u.moonLight,p.moonLight,tolerance: 0.0002) else { return false }
        let delta = Self.transport(u)-Self.transport(p)
        return abs(delta.x) < 0.15 && abs(delta.y) < 0.01
    }

    func recordFresh(_ u: ShaderUniforms) { previous = u; reused = false; freshFrames += 1 }
    func recordReuse() { reused = true; reprojectedFrames += 1 }

    func trackCompletion(of buffer: MTLCommandBuffer) {
        let generation = generation
        buffer.addCompletedHandler { [weak self, lease] command in
            withExtendedLifetime(lease) {
                if command.status == .error {
                    Task { @MainActor in
                        if self?.generation == generation { self?.invalidate() }
                    }
                }
            }
        }
    }
}
