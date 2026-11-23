// swift Scripts/GenerateClouds.swift — original, offline volumetric artwork, no third-party tools.
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("A Metal GPU is required to generate cloud artwork")
}
let source = try String(contentsOf: root.appendingPathComponent("Scripts/CloudBaker.metal"), encoding: .utf8)
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "bakeClouds")!)
let size = 1536
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
descriptor.usage = [.shaderWrite]
descriptor.storageMode = .private
let texture = device.makeTexture(descriptor: descriptor)!
let buffer = device.makeBuffer(length: size * size * 4, options: .storageModeShared)!
let command = queue.makeCommandBuffer()!
let encoder = command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setTexture(texture, index: 0)
encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
encoder.endEncoding()
let blit = command.makeBlitCommandEncoder()!
blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
          sourceSize: MTLSize(width: size, height: size, depth: 1), to: buffer, destinationOffset: 0,
          destinationBytesPerRow: size * 4, destinationBytesPerImage: size * size * 4)
blit.endEncoding()
command.commit()
command.waitUntilCompleted()
if let error = command.error { throw error }
let data = Data(bytes: buffer.contents(), count: size * size * 4)
let provider = CGDataProvider(data: data as CFData)!
// Straight alpha, linear grayscale irradiance. Runtime recolouring is done in linear light.
let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                    space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
let url = root.appendingPathComponent("Sources/WeatherWallpaper/Resources/CloudAtlas.png")
let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(output, image, nil)
guard CGImageDestinationFinalize(output) else { fatalError("Couldn't write cloud atlas") }
print("Generated cirrus, stratocumulus, cumulus and rain/anvil banks in the same 1536-pixel atlas: \(url.path)")
