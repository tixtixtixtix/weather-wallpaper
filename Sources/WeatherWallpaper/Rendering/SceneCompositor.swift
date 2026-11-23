import Metal
import MetalPerformanceShaders
import WeatherCore

private struct LightningGPUInstance {
    let endpoints: SIMD4<Float>
    let appearance: SIMD4<Float>
}

private struct MeteorDraw {
    var headDirection: SIMD4<Float>
    var train: SIMD4<Float>
}

/// Shared render graph: low-resolution linear cloud integration, optional emission/bloom,
/// then full-resolution celestial/atmosphere composition and GPU precipitation.
@MainActor
final class SceneCompositor {
    let resources: MetalResources
    private let cloudPipeline: MTLRenderPipelineState
    private let convectiveCloudPipeline: MTLRenderPipelineState
    private let iceCloudPipeline: MTLRenderPipelineState
    private let bankCloudPipeline: MTLRenderPipelineState
    private let cumulusCloudPipeline: MTLRenderPipelineState
    private let cumulusConvectivePipeline: MTLRenderPipelineState
    private let atmospherePipeline: MTLRenderPipelineState
    private let atmosphereEmissionPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let lensPipeline: MTLRenderPipelineState
    private let quadPrimitive: MTLPrimitiveType
    private let quadVertexCount: Int
    private let cloudPass = MTLRenderPassDescriptor()
    private let emissionPass = MTLRenderPassDescriptor()
    private let finalPass = MTLRenderPassDescriptor()
    private let lensPass = MTLRenderPassDescriptor()
    private let blur: MPSImageGaussianBlur
    private let economicalBlur: MPSImageGaussianBlur
    private var emission: MTLTexture?
    private var blurred: MTLTexture?
    private var cloudTarget: MTLTexture?
    private var rainScene: MTLTexture?
    private var lightDepth: MTLTexture?
    private let permitsLightCache: Bool
    private let usesBottomFadeScissor: Bool
    private let frameHistory: CloudFrameHistory?
    private var lightningBuffer: MTLBuffer?
    private var lightningCount = 0
    private var lightningKey: SIMD3<Float>?
    private var cachedCloudUniforms: ShaderUniforms?
    private var cachedCloudSize: (width: Int, height: Int)?
    private(set) var cloudReuseCount = 0

    var allocatedTransientBytes: Int {
        [cloudTarget, emission, blurred, lightDepth, rainScene].compactMap { $0 }.reduce(0) { $0 + $1.allocatedSize }
            + (frameHistory?.allocatedBytes ?? 0)
    }

    var cloudRenderSize: MTLSize? {
        cloudTarget.map { MTLSize(width: $0.width, height: $0.height, depth: 1) }
    }

    var lightCacheBytes: Int { lightDepth?.allocatedSize ?? 0 }
    var historyBytes: Int { frameHistory?.allocatedBytes ?? 0 }
    var historyFreshFrames: Int { frameHistory?.freshFrames ?? 0 }
    var historyReprojectedFrames: Int { frameHistory?.reprojectedFrames ?? 0 }
    var bloomBytes: Int { (emission?.allocatedSize ?? 0) + (blurred?.allocatedSize ?? 0) }
    var rainSceneBytes: Int { rainScene?.allocatedSize ?? 0 }

    init(resources: MetalResources, cloudPipeline: MTLRenderPipelineState? = nil,
         convectiveCloudPipeline: MTLRenderPipelineState? = nil,
         iceCloudPipeline: MTLRenderPipelineState? = nil,
          atmospherePipeline: MTLRenderPipelineState? = nil, atmosphereEmissionPipeline: MTLRenderPipelineState? = nil,
          particlePipeline: MTLRenderPipelineState? = nil,lensPipeline: MTLRenderPipelineState? = nil,usesQuadStrips: Bool = true,
         useLightCache: Bool = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_LIGHT_CACHE_REVIEW"] == "1",
         useCloudHistory: Bool = ProcessInfo.processInfo.environment["WEATHER_WALLPAPER_CLOUD_HISTORY_REVIEW"] == "1") {
        self.resources = resources
        self.cloudPipeline = cloudPipeline ?? resources.volumeCloudPipeline
        self.convectiveCloudPipeline = convectiveCloudPipeline ?? cloudPipeline ?? resources.convectiveCloudPipeline
        self.iceCloudPipeline = iceCloudPipeline ?? cloudPipeline ?? resources.iceCloudPipeline
        bankCloudPipeline = cloudPipeline ?? resources.bankCloudPipeline
        cumulusCloudPipeline = cloudPipeline ?? resources.cumulusCloudPipeline
        cumulusConvectivePipeline = convectiveCloudPipeline ?? cloudPipeline ?? resources.cumulusConvectivePipeline
        self.atmospherePipeline = atmospherePipeline ?? resources.atmospherePipeline
        self.atmosphereEmissionPipeline = atmosphereEmissionPipeline ?? resources.atmosphereEmissionPipeline
        self.particlePipeline = particlePipeline ?? resources.particlePipeline
        self.lensPipeline = lensPipeline ?? resources.lensPipeline
        quadPrimitive = usesQuadStrips ? .triangleStrip : .triangle
        quadVertexCount = usesQuadStrips ? 4 : 6
        permitsLightCache = useLightCache && cloudPipeline == nil
        usesBottomFadeScissor = cloudPipeline == nil && convectiveCloudPipeline == nil && iceCloudPipeline == nil
        frameHistory = useCloudHistory && !useLightCache && cloudPipeline == nil ? CloudFrameHistory(resources: resources) : nil
        for pass in [emissionPass,finalPass] {
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
        }
        cloudPass.colorAttachments[0].loadAction = .clear
        cloudPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        cloudPass.colorAttachments[0].storeAction = .store
        cloudPass.colorAttachments[1].loadAction = .clear
        cloudPass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        cloudPass.colorAttachments[1].storeAction = .store
        blur = MPSImageGaussianBlur(device: resources.device, sigma: 5)
        blur.edgeMode = .clamp
        economicalBlur = MPSImageGaussianBlur(device: resources.device, sigma: 2.5)
        economicalBlur.edgeMode = .clamp
    }

    private func releaseBloomTargets() { emission = nil; blurred = nil }

    func releaseTransientResources() {
        releaseBloomTargets()
        cloudTarget = nil
        rainScene = nil
        lightDepth = nil
        cachedCloudUniforms = nil
        cachedCloudSize = nil
        frameHistory?.invalidate()
        lightningBuffer = nil
        lightningCount = 0
        lightningKey = nil
        cloudPass.colorAttachments[0].texture = nil
        cloudPass.colorAttachments[1].texture = nil
        emissionPass.colorAttachments[0].texture = nil
        finalPass.colorAttachments[0].texture = nil
        lensPass.colorAttachments[0].texture = nil
    }

    private func prepareLightning(_ uniforms: ShaderUniforms) {
        guard uniforms.lightning.z > 0.001 && uniforms.options.y > 0 else { return }
        let key = SIMD3(uniforms.lightning.x, uniforms.lightning.y, uniforms.lightning.w)
        guard key != lightningKey || lightningBuffer == nil else { return }
        let sample = LightningSample(origin: key.x, seed: key.y, intensity: 1, reach: key.z)
        let instances = FractalLightning.segments(for: sample).map { segment in
            LightningGPUInstance(endpoints: SIMD4(segment.start.x, segment.start.y, segment.end.x, segment.end.y),
                appearance: SIMD4(segment.width, segment.brightness,
                                  max(0, (segment.start.y - 0.065) / max(0.1, sample.reach)), 0))
        }
        lightningBuffer = instances.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress, !bytes.isEmpty else { return nil }
            return resources.device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }
        lightningCount = lightningBuffer == nil ? 0 : instances.count
        lightningKey = key
    }

    private func drawLightning(_ encoder: MTLRenderCommandEncoder, uniforms: inout ShaderUniforms, emission: Bool) {
        guard uniforms.lightning.z > 0.001, uniforms.options.y > 0,
              let lightningBuffer, lightningCount > 0 else { return }
        encoder.setRenderPipelineState(emission ? resources.lightningEmissionPipeline : resources.lightningPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.setVertexBuffer(lightningBuffer, offset: 0, index: 1)
        if uniforms.rendering.z < 0.5 {
            encoder.setVertexTexture(resources.cloudAtlas, index: 0)
            encoder.setFragmentTexture(resources.cloudAtlas, index: 0)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lightningCount)
    }

    private static func closeVector(_ a: SIMD4<Float>, _ b: SIMD4<Float>, tolerance: Float) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.z - b.z) <= tolerance && abs(a.w - b.w) <= tolerance
    }

    private func canReuseCloudTarget(_ u: ShaderUniforms, width: Int, height: Int) -> Bool {
        guard let cached = cachedCloudUniforms,
              let size = cachedCloudSize, size.width == width, size.height == height else { return false }
        let now = Double(u.clock.x) + Double(u.viewport.z)
        let then = Double(cached.clock.x) + Double(cached.viewport.z)
        let dt = now - then
        let interval: Double = (u.weather.w < 0.25 && u.convection.x <= 0.001) ? (1.0 / 12.0) : (1.0 / 15.0)
        guard dt > 0, dt < interval * 0.95,
              u.viewport.x == cached.viewport.x, u.viewport.y == cached.viewport.y, u.viewport.w == cached.viewport.w,
              u.rendering == cached.rendering, u.morphology == cached.morphology,
              u.cloudStructure == cached.cloudStructure, u.upperStyle == cached.upperStyle,
              u.clouds == cached.clouds, u.atmosphere == cached.atmosphere,
              u.weather.x == cached.weather.x, u.weather.y == cached.weather.y, u.weather.z == cached.weather.z,
              u.convection.x == cached.convection.x, u.convection.y == cached.convection.y,
              u.lightning.z <= 0.001, cached.lightning.z <= 0.001,
              Self.closeVector(u.celestial, cached.celestial, tolerance: 0.0005),
              Self.closeVector(u.moon, cached.moon, tolerance: 0.0005),
              Self.closeVector(u.moonLight, cached.moonLight, tolerance: 0.0005) else { return false }
        return true
    }

    func encode(into texture: MTLTexture, buffer: MTLCommandBuffer, uniforms input: ShaderUniforms,
                meteor: MeteorAppearance? = nil, framesPerSecond: Int = 30, animated: Bool = true,
                widget: WidgetRainLayoutUniforms = .disabled, haze inputHaze: MoonlitHazeUniforms = .disabled,
                allowCloudReuse: Bool = false) {
        defer {
            // Reuse the descriptor objects, never retain drawables/retired targets.
            finalPass.colorAttachments[0].texture = nil
            lensPass.colorAttachments[0].texture = nil
            cloudPass.colorAttachments[0].texture = nil
            cloudPass.colorAttachments[1].texture = nil
            emissionPass.colorAttachments[0].texture = nil
        }
        var uniforms = input
        uniforms.upperStyle.w = 0
        prepareLightning(uniforms)
        var cloudLayer = resources.blackTexture
        if uniforms.rendering.z > 0.5 && (uniforms.cloudStructure.z > 0.075 || uniforms.clouds.w > 0.001 || uniforms.convection.x > 0.001) {
            let divisor = max(2, min(8, Int(uniforms.rendering.y)))
            let width = max(1, texture.width / divisor), height = max(1, texture.height / divisor)
            if cloudTarget?.width != width || cloudTarget?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                    width: width, height: height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                cloudTarget = resources.device.makeTexture(descriptor: descriptor)
                cloudTarget?.label = "Linear cloud scattering + opacity"
                cachedCloudUniforms = nil
                cachedCloudSize = nil
            }
            if let cloudTarget {
                if allowCloudReuse && animated && frameHistory == nil && canReuseCloudTarget(uniforms, width: width, height: height) {
                    cloudLayer = cloudTarget
                    cloudReuseCount += 1
                } else {
                // Sparse skies don't amortize a 3D cache build. Reserve it for
                // extensive decks; broken clouds keep exact bounded light probes.
                if permitsLightCache && uniforms.cloudStructure.z >= 0.65 && uniforms.convection.x <= 0.001 {
                    let side = uniforms.rendering.x > 24 ? 96 : 48
                    let layers = uniforms.rendering.x > 24 ? 32 : 24
                    if lightDepth?.width != side || lightDepth?.height != layers {
                        let descriptor = MTLTextureDescriptor()
                        descriptor.textureType = .type3D; descriptor.pixelFormat = .r16Float
                        descriptor.width = side; descriptor.height = layers; descriptor.depth = side
                        descriptor.storageMode = .private; descriptor.usage = [.shaderRead,.shaderWrite]
                        lightDepth = resources.device.makeTexture(descriptor: descriptor)
                        lightDepth?.label = "Bounded cloud light depth (no history)"
                    }
                    if let lightDepth, let compute = buffer.makeComputeCommandEncoder() {
                        compute.label = "Cloud light-depth cache"
                        compute.setComputePipelineState(resources.cloudLightDepthPipeline)
                        compute.setBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 0)
                        compute.setTexture(lightDepth,index: 0)
                        compute.setTexture(resources.noiseVolume,index: 1)
                        compute.dispatchThreads(MTLSize(width: side,height: layers,depth: side),
                                                threadsPerThreadgroup: MTLSize(width: 4,height: 4,depth: 4))
                        compute.endEncoding()
                        uniforms.upperStyle.w = 1
                    }
                } else { lightDepth = nil }
                if !animated { frameHistory?.invalidate() }
                let historyReady = animated && (frameHistory?.prepare(uniforms,width: width,height: height) ?? false)
                let reuse = historyReady && frameHistory?.canReuse(uniforms) == true
                let destination = historyReady && !reuse ? (frameHistory?.color ?? cloudTarget) : cloudTarget
                let pass = cloudPass
                pass.colorAttachments[0].texture = destination
                pass.colorAttachments[1].texture = historyReady && !reuse ? frameHistory?.depth : nil
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
                    encoder.label = reuse ? "Reproject fresh cloud history + reject unreliable pixels" : "Low-resolution cloud volume + distant cirrus"
                    if usesBottomFadeScissor {
                        // cloudBottomFade(uv.y) is identically zero for uv.y >= 0.84; skip fragment dispatch below it.
                        let activeHeight = min(height, Int(ceil(Double(height) * 0.84)) + 1)
                        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: activeHeight))
                    }
                    if reuse, let frameHistory, var previous = frameHistory.previous {
                        encoder.setRenderPipelineState(frameHistory.depth == nil ? frameHistory.pipelines.reprojectIce : frameHistory.pipelines.reproject)
                        encoder.setFragmentBytes(&previous,length: MemoryLayout<ShaderUniforms>.stride,index: 1)
                        encoder.setFragmentTexture(frameHistory.color,index: 2)
                        encoder.setFragmentTexture(frameHistory.depth ?? resources.blackTexture,index: 3)
                    } else if historyReady, let frameHistory, frameHistory.depth != nil {
                        encoder.setRenderPipelineState(frameHistory.pipelines.fresh)
                    } else {
                        let pipeline: MTLRenderPipelineState
                        if uniforms.convection.x > 0.001 {
                            pipeline = uniforms.cloudBillowMode == 2 ? cumulusConvectivePipeline : convectiveCloudPipeline
                        } else if uniforms.cloudStructure.z <= 0.075 { pipeline = iceCloudPipeline }
                        else if uniforms.cloudBillowMode == 0 { pipeline = bankCloudPipeline }
                        else if uniforms.cloudBillowMode == 2 { pipeline = cumulusCloudPipeline }
                        else { pipeline = cloudPipeline }
                        encoder.setRenderPipelineState(pipeline)
                    }
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(resources.noiseVolume, index: 0)
                    encoder.setFragmentTexture(lightDepth ?? resources.emptyLightDepth,index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding()
                    cloudLayer = destination
                    if destination === cloudTarget {
                        cachedCloudUniforms = uniforms
                        cachedCloudSize = (width, height)
                    } else {
                        cachedCloudUniforms = nil
                        cachedCloudSize = nil
                    }
                    if historyReady, let frameHistory {
                        if reuse { frameHistory.recordReuse() } else { frameHistory.recordFresh(uniforms) }
                        frameHistory.trackCompletion(of: buffer)
                    }
                } else { frameHistory?.invalidate(); cachedCloudUniforms = nil; cachedCloudSize = nil; uniforms.rendering.z = 0 }
                }
            } else { frameHistory?.invalidate(); cachedCloudUniforms = nil; cachedCloudSize = nil; uniforms.rendering.z = 0 } // Keep the previous renderer as an allocation fallback.
        } else {
            cloudTarget = nil
            lightDepth = nil
            cachedCloudUniforms = nil
            cachedCloudSize = nil
            frameHistory?.invalidate()
        }
        var light = resources.blackTexture
        let needsBloom = uniforms.options.w > 0 && (uniforms.lightning.z > 0.001
            || (uniforms.atmosphere.x > 0.01 && (uniforms.cloudStructure.z < 0.995 || uniforms.cloudStructure.w < 0.5)
                && (uniforms.rendering.z < 0.5 || uniforms.moonLight.w > 0)
                && uniforms.celestial.y > (uniforms.rendering.z > 0.5 ? -0.035 : -0.04)
                && uniforms.celestial.y < (uniforms.rendering.z > 0.5 ? 1.035 : 1.04)))
        if needsBloom {
            let downsample = max(4, min(8, Int(uniforms.clock.w)))
            let width = max(1, texture.width / downsample), height = max(1, texture.height / downsample)
            if emission?.width != width || emission?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                         width: width, height: height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
                emission = resources.device.makeTexture(descriptor: descriptor)
                blurred = resources.device.makeTexture(descriptor: descriptor)
            }
            if let emission, let blurred {
                let pass = emissionPass
                pass.colorAttachments[0].texture = emission
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
                    encoder.label = "Visible sun / lightning emission"
                    encoder.setRenderPipelineState(uniforms.rendering.z > 0.5 ? atmosphereEmissionPipeline : resources.emissionPipeline)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
                    if uniforms.rendering.z < 0.5 {
                        encoder.setVertexTexture(resources.cloudAtlas, index: 0)
                        encoder.setFragmentTexture(resources.cloudAtlas, index: 0)
                    }
                    encoder.setVertexTexture(cloudLayer,index: 3)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(cloudLayer, index: 3)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    drawLightning(encoder, uniforms: &uniforms, emission: true)
                    encoder.endEncoding()
                    let kernel = downsample >= 8 ? economicalBlur : blur
                    kernel.encode(commandBuffer: buffer, sourceTexture: emission, destinationTexture: blurred)
                    light = blurred
                }
            }
        } else {
            releaseBloomTargets()
        }
        // Refraction needs a sampled scene, never feedback from the drawable.
        // Allocate only while wet; no cloud changes or fullscreen blur.
        let lensCount = RainRenderingBudget.lensCount(intensity: uniforms.weather.x,scale: uniforms.options.x)
        if lensCount > 0 {
            if rainScene?.width != texture.width || rainScene?.height != texture.height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                    width: texture.width,height: texture.height,mipmapped: false)
                descriptor.storageMode = .private; descriptor.usage = [.renderTarget,.shaderRead]
                rainScene = resources.device.makeTexture(descriptor: descriptor)
                rainScene?.label = "Wet-weather scene for local lens refraction"
            }
        } else { rainScene = nil }
        let pass = finalPass
        pass.colorAttachments[0].texture = rainScene ?? texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Full-resolution atmosphere + photographic moon + GPU precipitation"
        encoder.setRenderPipelineState(uniforms.rendering.z > 0.5 ? atmospherePipeline : resources.skyPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        if uniforms.rendering.z < 0.5 {
            encoder.setVertexTexture(resources.cloudAtlas, index: 0)
            encoder.setFragmentTexture(resources.cloudAtlas, index: 0)
        }
        encoder.setVertexTexture(cloudLayer,index: 3)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        var haze = inputHaze
        encoder.setFragmentBytes(&haze,length: MemoryLayout<MoonlitHazeUniforms>.stride,index: 3)
        encoder.setFragmentTexture(resources.moonAlbedo, index: 1)
        encoder.setFragmentTexture(light, index: 2)
        encoder.setFragmentTexture(cloudLayer, index: 3)
        encoder.setFragmentTexture(resources.noiseVolume,index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if uniforms.rendering.z < 0.5 && (uniforms.clouds.x > 0.001 || uniforms.clouds.w > 0.001) {
            encoder.setRenderPipelineState(resources.cloudPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 24)
        }
        if let meteor, uniforms.rendering.z > 0.5, meteor.intensity > 0 {
            // Small capped exposure smear in height units; speed does not stretch the path.
            var draw = MeteorDraw(headDirection: SIMD4(meteor.head.x,meteor.head.y,meteor.direction.x,meteor.direction.y),
                train: SIMD4(meteor.trainLength,0.75 / Float(texture.height),
                             min(0.006,meteor.speed / Float(max(15,framesPerSecond)) * 0.18),meteor.intensity))
            encoder.setRenderPipelineState(resources.meteorPipeline)
            encoder.setVertexBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 0)
            encoder.setVertexBytes(&draw,length: MemoryLayout<MeteorDraw>.stride,index: 1)
            encoder.setFragmentBytes(&draw,length: MemoryLayout<MeteorDraw>.stride,index: 1)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6)
        }
        drawLightning(encoder, uniforms: &uniforms, emission: false)
        let rain = RainRenderingBudget.rainCount(intensity: uniforms.weather.x,scale: uniforms.options.x)
        let snow = Int(uniforms.weather.y * 550 * uniforms.options.x)
        if rain > 0 || snow > 0 || widget.showsGuide {
            widget.vectors.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!,length: bytes.count,index: 2)
                encoder.setFragmentBytes(bytes.baseAddress!,length: bytes.count,index: 2)
            }
        }
        if rain > 0 || snow > 0 {
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
            if rain > 0 {
                var kind: UInt32 = 0
                encoder.setVertexBytes(&kind, length: 4, index: 1)
                encoder.drawPrimitives(type: quadPrimitive, vertexStart: 0, vertexCount: quadVertexCount, instanceCount: rain)
                if animated && widget.count > 0 {
                    kind = 2
                    encoder.setVertexBytes(&kind,length: 4,index: 1)
                    encoder.drawPrimitives(type: quadPrimitive,vertexStart: 0,vertexCount: quadVertexCount,instanceCount: (rain/10)*6)
                }
            }
            if snow > 0 {
                var kind: UInt32 = 1
                encoder.setVertexBytes(&kind, length: 4, index: 1)
                encoder.drawPrimitives(type: quadPrimitive, vertexStart: 0, vertexCount: quadVertexCount, instanceCount: snow)
            }
        }
        if widget.showsGuide && widget.count > 0 {
            var kind: UInt32 = 3
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 0)
            encoder.setVertexBytes(&kind,length: MemoryLayout<UInt32>.stride,index: 1)
            encoder.drawPrimitives(type: quadPrimitive,vertexStart: 0,vertexCount: quadVertexCount,instanceCount: widget.count)
        }
        encoder.endEncoding()
        if let rainScene {
            lensPass.colorAttachments[0].texture = texture
            lensPass.colorAttachments[0].loadAction = .dontCare
            lensPass.colorAttachments[0].storeAction = .store
            guard let lens = buffer.makeRenderCommandEncoder(descriptor: lensPass) else { return }
            lens.label = "Local lens beads and sparse camera-impact droplets"
            lens.setRenderPipelineState(resources.rainCompositePipeline)
            lens.setFragmentTexture(rainScene,index: 0)
            lens.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
            lens.setRenderPipelineState(lensPipeline)
            lens.setVertexBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 0)
            lens.setFragmentBytes(&uniforms,length: MemoryLayout<ShaderUniforms>.stride,index: 0)
            lens.drawPrimitives(type: quadPrimitive,vertexStart: 0,vertexCount: quadVertexCount,instanceCount: lensCount)
            if animated {
                var kind: UInt32 = 5
                lens.setRenderPipelineState(particlePipeline)
                lens.setVertexBytes(&kind,length: 4,index: 1)
                let impacts = max(4,Int(64*min(1,uniforms.weather.x)*pow(uniforms.options.x,2)))
                lens.drawPrimitives(type: quadPrimitive,vertexStart: 0,vertexCount: quadVertexCount,instanceCount: impacts)
            }
            lens.endEncoding()
        }
    }
}
