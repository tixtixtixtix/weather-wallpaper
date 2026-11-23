import Foundation
import Metal
import MetalKit

enum RenderingError: LocalizedError {
    case metalUnavailable, commandQueueUnavailable, missingShaders, missingArtwork(String), allocationFailed

    var errorDescription: String? {
        switch self {
        case .metalUnavailable: "This Mac doesn't have an available Metal GPU."
        case .commandQueueUnavailable: "Couldn't create a Metal command queue."
        case .missingShaders: "The wallpaper shaders are missing. Rebuild the app in Xcode."
        case .allocationFailed: "The GPU couldn't allocate the atmosphere's rendering resources."
        case let .missingArtwork(name): "Missing wallpaper artwork: \(name). Rebuild the app in Xcode."
        }
    }
}

/// One device, library, queue and shared pipeline collection for every display and preview.
@MainActor
final class MetalResources {
    static let shared: Result<MetalResources, Error> = Result { try MetalResources() }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let particlePipeline: MTLRenderPipelineState
    let rainCompositePipeline: MTLRenderPipelineState
    let lensPipeline: MTLRenderPipelineState
    let lightningPipeline: MTLRenderPipelineState
    let lightningEmissionPipeline: MTLRenderPipelineState
    let moonAlbedo: MTLTexture
    let blackTexture: MTLTexture
    let noiseVolume: MTLTexture
    let volumeCloudPipeline: MTLRenderPipelineState
    let convectiveCloudPipeline: MTLRenderPipelineState
    let iceCloudPipeline: MTLRenderPipelineState
    let bankCloudPipeline: MTLRenderPipelineState
    let cumulusCloudPipeline: MTLRenderPipelineState
    let cumulusConvectivePipeline: MTLRenderPipelineState
    let atmospherePipeline: MTLRenderPipelineState
    let atmosphereEmissionPipeline: MTLRenderPipelineState
    let meteorPipeline: MTLRenderPipelineState
    let cloudLightDepthPipeline: MTLComputePipelineState
    let emptyLightDepth: MTLTexture
    private let library: MTLLibrary
    private let bundle: Bundle
    let cloudHistoryBudget = CloudHistoryBudget()

    /// Legacy sky resources load on demand so shipping hybrid mode avoids ~12.6 MiB of unused VRAM and startup shader compiles.
    lazy var cloudAtlas: MTLTexture = {
        guard let url = bundle.url(forResource: "CloudAtlas", withExtension: "png") else { return blackTexture }
        let loader = MTKTextureLoader(device: device)
        return (try? loader.newTexture(URL: url, options: [.SRGB: false, .generateMipmaps: true,
                                                           .textureStorageMode: MTLStorageMode.private.rawValue])) ?? blackTexture
    }()

    lazy var skyPipeline: MTLRenderPipelineState = {
        let sky = MTLRenderPipelineDescriptor()
        sky.label = "Procedural atmosphere"
        sky.vertexFunction = library.makeFunction(name: "skyVertex")
        sky.fragmentFunction = library.makeFunction(name: "skyFragment")
        sky.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        return try! device.makeRenderPipelineState(descriptor: sky)
    }()

    lazy var emissionPipeline: MTLRenderPipelineState = {
        let emission = MTLRenderPipelineDescriptor()
        emission.label = "Quarter-resolution HDR light"
        emission.vertexFunction = library.makeFunction(name: "skyVertex")
        emission.fragmentFunction = library.makeFunction(name: "emissionFragment")
        emission.colorAttachments[0].pixelFormat = .rgba16Float
        return try! device.makeRenderPipelineState(descriptor: emission)
    }()

    lazy var cloudPipeline: MTLRenderPipelineState = {
        let clouds = MTLRenderPipelineDescriptor()
        clouds.label = "Instanced cloud formations"
        clouds.vertexFunction = library.makeFunction(name: "cloudVertex")
        clouds.fragmentFunction = library.makeFunction(name: "cloudFragment")
        let cloudAttachment = clouds.colorAttachments[0]!
        cloudAttachment.pixelFormat = .bgra8Unorm_srgb
        cloudAttachment.isBlendingEnabled = true
        cloudAttachment.sourceRGBBlendFactor = .one
        cloudAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        cloudAttachment.sourceAlphaBlendFactor = .one
        cloudAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try! device.makeRenderPipelineState(descriptor: clouds)
    }()
    // Only the opt-in prototype compiles these pipelines. Never compile per frame.
    lazy var cloudHistoryPipelines: Result<CloudHistoryPipelines,Error> = Result {
        func pipeline(_ name: String, depth: Bool, volume: Bool = true) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = name
            descriptor.vertexFunction = library.makeFunction(name: "atmosphereVertex")
            let constants = MTLFunctionConstantValues(); var enabled = volume
            constants.setConstantValue(&enabled,type: .bool,index: 2)
            descriptor.fragmentFunction = try library.makeFunction(name: name,constantValues: constants)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            if depth { descriptor.colorAttachments[1].pixelFormat = .r16Float }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        return try CloudHistoryPipelines(fresh: pipeline("cloudHistoryFragment",depth: true),
                                         reproject: pipeline("reprojectCloudFragment",depth: false),
                                         reprojectIce: pipeline("reprojectCloudFragment",depth: false,volume: false))
    }

    func cloudVolumePipeline(for uniforms: ShaderUniforms) -> MTLRenderPipelineState {
        if uniforms.convection.x > 0.001 {
            return uniforms.cloudBillowMode == 2 ? cumulusConvectivePipeline : convectiveCloudPipeline
        }
        if uniforms.cloudStructure.z <= 0.075 { return iceCloudPipeline }
        switch uniforms.cloudBillowMode {
        case 0: return bankCloudPipeline
        case 2: return cumulusCloudPipeline
        default: return volumeCloudPipeline
        }
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderingError.metalUnavailable }
        guard let queue = device.makeCommandQueue() else { throw RenderingError.commandQueueUnavailable }
        self.device = device
        self.queue = queue
        queue.label = "Weather Wallpaper · shared GPU queue"
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        self.bundle = bundle
        let library: MTLLibrary
        if let compiled = try? device.makeDefaultLibrary(bundle: bundle) {
            library = compiled
        } else if let url = bundle.url(forResource: "Sky", withExtension: "metal"),
                  let atmosphere = bundle.url(forResource: "Atmosphere", withExtension: "metal") {
            // SwiftPM copies Metal source; the shipping Xcode app uses a precompiled metallib.
            let source = try [url, atmosphere].map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
            library = try device.makeLibrary(source: source, options: nil)
        } else { throw RenderingError.missingShaders }
        self.library = library

        func rainPipeline(_ vertex: String,_ fragment: String,blend: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm_srgb
            color.isBlendingEnabled = blend
            color.sourceRGBBlendFactor = .sourceAlpha; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .zero; color.destinationAlphaBlendFactor = .one
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        rainCompositePipeline = try rainPipeline("rainCompositeVertex","rainCompositeFragment",blend: false)
        lensPipeline = try rainPipeline("lensVertex","lensFragment",blend: true)

        let loader = MTKTextureLoader(device: device)
        func texture(_ name: String, extension ext: String, srgb: Bool) throws -> MTLTexture {
            guard let url = bundle.url(forResource: name, withExtension: ext) else {
                throw RenderingError.missingArtwork(name)
            }
            return try loader.newTexture(URL: url, options: [.SRGB: srgb, .generateMipmaps: true,
                                                              .textureStorageMode: MTLStorageMode.private.rawValue])
        }
        moonAlbedo = try texture("MoonAlbedo", extension: "jpg", srgb: true)
        let black = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        black.storageMode = device.hasUnifiedMemory ? .shared : .managed
        blackTexture = device.makeTexture(descriptor: black)!
        var zero: UInt32 = 0
        blackTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)

        func atmospherePipeline(_ fragment: String, format: MTLPixelFormat, convection: Bool = false, volume: Bool = true, billow: UInt32 = 1) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = library.makeFunction(name: fragment == "atmosphereComposite" || fragment == "atmosphereEmission"
                ? "solarAtmosphereVertex" : "atmosphereVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            if fragment == "volumeCloudFragment" {
                let constants = MTLFunctionConstantValues()
                var enabled = convection
                constants.setConstantValue(&enabled,type: .bool,index: 0)
                var volumeEnabled = volume
                constants.setConstantValue(&volumeEnabled,type: .bool,index: 2)
                var mode = billow
                constants.setConstantValue(&mode,type: .uint,index: 3)
                descriptor.fragmentFunction = try library.makeFunction(name: fragment,constantValues: constants)
            }
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        volumeCloudPipeline = try atmospherePipeline("volumeCloudFragment", format: .rgba16Float)
        convectiveCloudPipeline = try atmospherePipeline("volumeCloudFragment",format: .rgba16Float,convection: true)
        iceCloudPipeline = try atmospherePipeline("volumeCloudFragment",format: .rgba16Float,volume: false)
        bankCloudPipeline = try atmospherePipeline("volumeCloudFragment",format: .rgba16Float,billow: 0)
        cumulusCloudPipeline = try atmospherePipeline("volumeCloudFragment",format: .rgba16Float,billow: 2)
        cumulusConvectivePipeline = try atmospherePipeline("volumeCloudFragment",format: .rgba16Float,convection: true,billow: 2)
        self.atmospherePipeline = try atmospherePipeline("atmosphereComposite", format: .bgra8Unorm_srgb)
        atmosphereEmissionPipeline = try atmospherePipeline("atmosphereEmission", format: .rgba16Float)
        let meteor = MTLRenderPipelineDescriptor()
        meteor.label = "Bounded shooting star"
        meteor.vertexFunction = library.makeFunction(name: "meteorVertex")
        meteor.fragmentFunction = library.makeFunction(name: "meteorFragment")
        let meteorColor = meteor.colorAttachments[0]!
        meteorColor.pixelFormat = .bgra8Unorm_srgb
        meteorColor.isBlendingEnabled = true
        meteorColor.sourceRGBBlendFactor = .one
        meteorColor.destinationRGBBlendFactor = .one
        meteorColor.sourceAlphaBlendFactor = .zero
        meteorColor.destinationAlphaBlendFactor = .one
        meteorPipeline = try device.makeRenderPipelineState(descriptor: meteor)
        let lightKernel = try library.makeFunction(name: "makeCloudLightDepth",constantValues: MTLFunctionConstantValues())
        cloudLightDepthPipeline = try device.makeComputePipelineState(function: lightKernel)
        let emptyDescriptor = MTLTextureDescriptor()
        emptyDescriptor.textureType = .type3D; emptyDescriptor.pixelFormat = .r16Float
        emptyDescriptor.width = 1; emptyDescriptor.height = 1; emptyDescriptor.depth = 1
        emptyDescriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let empty = device.makeTexture(descriptor: emptyDescriptor) else { throw RenderingError.allocationFailed }
        var emptyValue: UInt16 = 0
        empty.replace(region: MTLRegionMake3D(0,0,0,1,1,1),mipmapLevel: 0,slice: 0,withBytes: &emptyValue,bytesPerRow: 2,bytesPerImage: 2)
        emptyLightDepth = empty

        // One shared periodic shape/erosion field (4.6 MiB texels, ~6 MiB with M4 padding).
        let noiseDescriptor = MTLTextureDescriptor()
        noiseDescriptor.textureType = .type3D
        noiseDescriptor.pixelFormat = .rg8Unorm
        noiseDescriptor.width = 128; noiseDescriptor.height = 128; noiseDescriptor.depth = 128
        noiseDescriptor.mipmapLevelCount = 8
        noiseDescriptor.storageMode = .private
        noiseDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let noise = device.makeTexture(descriptor: noiseDescriptor),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder(),
              let kernel = library.makeFunction(name: "makeAtmosphereNoise") else { throw RenderingError.allocationFailed }
        noise.label = "Shared periodic cloud shape and erosion"
        let compute = try device.makeComputePipelineState(function: kernel)
        encoder.setComputePipelineState(compute)
        encoder.setTexture(noise, index: 0)
        encoder.dispatchThreads(MTLSize(width: 128, height: 128, depth: 128),
                                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4))
        encoder.endEncoding()
        guard let mipmaps = command.makeBlitCommandEncoder() else { throw RenderingError.allocationFailed }
        mipmaps.generateMipmaps(for: noise)
        mipmaps.endEncoding()
        command.commit()
        command.waitUntilCompleted() // Once at resource creation, never in the animation loop.
        if let error = command.error { throw error }
        noiseVolume = noise

        func lightningPipeline(format: MTLPixelFormat, fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Fractal lightning · \(fragment)"
            descriptor.vertexFunction = library.makeFunction(name: "lightningVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = format
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .zero
            color.destinationAlphaBlendFactor = .one
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.lightningPipeline = try lightningPipeline(format: .bgra8Unorm_srgb, fragment: "lightningFragment")
        lightningEmissionPipeline = try lightningPipeline(format: .rgba16Float, fragment: "lightningEmissionFragment")

        let particles = MTLRenderPipelineDescriptor()
        particles.label = "Instanced precipitation"
        particles.vertexFunction = library.makeFunction(name: "particleVertex")
        particles.fragmentFunction = library.makeFunction(name: "particleFragment")
        let attachment = particles.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm_srgb
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        particlePipeline = try device.makeRenderPipelineState(descriptor: particles)
    }
}
