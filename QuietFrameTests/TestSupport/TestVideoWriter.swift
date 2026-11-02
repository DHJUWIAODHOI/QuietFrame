import AVFoundation
import CoreVideo
import Foundation
@testable import QuietFrame

/// Writes short H.264 clips of noisy frames, which compress to several container chunks.
enum TestVideoWriter {
    static func writeVideo(
        to url: URL,
        width: Int = 160,
        height: Int = 120,
        frameCount: Int,
        framesPerSecond: Int32,
        seed: UInt64 = 99
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VaultError.fileOperationFailed }
        writer.startSession(atSourceTime: .zero)
        var generator = SeededGenerator(seed: seed)
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw VaultError.fileOperationFailed }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw VaultError.fileOperationFailed }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = base.bindMemory(to: UInt8.self, capacity: CVPixelBufferGetDataSize(pixelBuffer))
                for index in 0..<CVPixelBufferGetDataSize(pixelBuffer) {
                    bytes[index] = UInt8(truncatingIfNeeded: generator.next())
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: framesPerSecond)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? VaultError.fileOperationFailed
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: framesPerSecond))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VaultError.fileOperationFailed }
    }
}
