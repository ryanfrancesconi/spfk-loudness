// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Accelerate
import AVFAudio
import Foundation
import SPFKBase

/// Reads a ``SequentialPCMSource`` as interleaved Float32 frames.
///
/// The source cannot seek, so a looped file is replayed from the frames kept on its first pass.
/// Only a short file is looped, which is what bounds that copy.
final class PCMSourceFrameReader: FrameReader {
    private let source: any SequentialPCMSource
    private let channelCount: Int
    private let retainsFrames: Bool
    private var chunk: AVAudioPCMBuffer?
    private var retained: [Float32] = []
    private var replayPosition: Int?

    let lengthInFrames: Int64
    let channelLabels: [AudioChannelLabel]?

    init(source: any SequentialPCMSource, retainsFramesForLooping: Bool) throws {
        let format = source.processingFormat

        guard format.commonFormat == .pcmFormatFloat32 else {
            throw NSError(description: "A PCM source must deliver Float32 samples, not \(format)")
        }

        self.source = source
        channelCount = Int(format.channelCount)
        retainsFrames = retainsFramesForLooping
        lengthInFrames = max(0, source.totalFrameCount)
        channelLabels = format.channelLayout.flatMap { ChannelMap.labels(of: $0.layout) }
    }

    func read(into buffer: UnsafeMutablePointer<Float32>, frameCount: UInt32) throws -> UInt32 {
        if let replayPosition {
            return replay(into: buffer, frameCount: frameCount, from: replayPosition)
        }

        let chunk = try chunkBuffer(capacity: frameCount)
        let frames = try source.readNextChunk(into: chunk, frameCount: frameCount)

        guard frames > 0 else { return 0 }

        try interleave(chunk, frames: Int(frames), into: buffer)

        if retainsFrames {
            retained.append(contentsOf: UnsafeBufferPointer(start: buffer, count: Int(frames) * channelCount))
        }

        return frames
    }

    func rewind() throws {
        guard retainsFrames else {
            throw NSError(description: "A sequential PCM source cannot be rewound")
        }

        replayPosition = 0
    }

    private func replay(into buffer: UnsafeMutablePointer<Float32>, frameCount: UInt32, from position: Int) -> UInt32 {
        let samples = min(Int(frameCount) * channelCount, retained.count - position)

        guard samples > 0 else { return 0 }

        retained.withUnsafeBufferPointer {
            guard let base = $0.baseAddress else { return }
            buffer.update(from: base + position, count: samples)
        }

        replayPosition = position + samples
        return UInt32(samples / channelCount)
    }

    private func chunkBuffer(capacity: UInt32) throws -> AVAudioPCMBuffer {
        if let chunk, chunk.frameCapacity >= capacity {
            return chunk
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: capacity) else {
            throw NSError(description: "Failed to allocate a \(capacity)-frame PCM buffer")
        }

        chunk = buffer
        return buffer
    }

    private func interleave(_ chunk: AVAudioPCMBuffer, frames: Int, into buffer: UnsafeMutablePointer<Float32>) throws {
        guard let channels = chunk.floatChannelData else {
            throw NSError(description: "A PCM source delivered no float channel data")
        }

        if chunk.format.isInterleaved {
            buffer.update(from: channels[0], count: frames * channelCount)
            return
        }

        for channel in 0 ..< channelCount {
            vDSP_mmov(channels[channel], buffer + channel, 1, vDSP_Length(frames), 1, vDSP_Length(channelCount))
        }
    }
}
