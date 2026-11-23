import AVFoundation
import CoreVideo
import Foundation

/// Opt-in visual-review artifact only. No video encoding or readback runs in the app.
@MainActor
final class ReviewVideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private let fps: Int32

    init(url: URL, width: Int, height: Int, fps: Int = 30) throws {
        self.width = width; self.height = height
        self.fps = Int32(max(1,fps))
        // Each review has a unique name; never overwrite a user's existing movie.
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000,
                                              AVVideoExpectedSourceFrameRateKey: fps]
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ bytes: [UInt8], frame: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var pixel: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixel) else { throw CocoaError(.fileWriteUnknown) }
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        bytes.withUnsafeBytes { source in
            guard let address = source.baseAddress else { return }
            for row in 0..<height {
                destination.advanced(by: row * stride).copyMemory(from: address.advanced(by: row * width * 4), byteCount: width * 4)
            }
        }
        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
