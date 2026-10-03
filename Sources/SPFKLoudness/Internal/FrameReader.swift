// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AudioToolbox
import Foundation

/// Supplies interleaved Float32 frames to ``audioConverterCallback``.
protocol FrameReader: AnyObject {
    /// Frames in the source, or 0 when it cannot be known before reading.
    var lengthInFrames: Int64 { get }

    /// Reads up to `frameCount` frames into `buffer` and returns how many were written; 0 at the end.
    func read(into buffer: UnsafeMutablePointer<Float32>, frameCount: UInt32) throws -> UInt32

    /// Restarts reading from the first frame, for a short file that is looped.
    func rewind() throws
}

/// Carries a ``FrameReader`` through ``CallbackContext``, which the converter receives as untyped
/// memory and so cannot hold an object reference itself.
///
/// A C callback cannot throw, so a reader's error is parked in ``error`` and rethrown by the driver.
final class FrameReaderHandle {
    let reader: any FrameReader
    var error: (any Error)?

    init(reader: any FrameReader) {
        self.reader = reader
    }
}

// MARK: - ExtAudioFile

final class ExtAudioFileFrameReader: FrameReader {
    private let audioFileRef: ExtAudioFileRef
    private let clientASBD: AudioStreamBasicDescription
    let lengthInFrames: Int64

    init(audioFileRef: ExtAudioFileRef, clientASBD: AudioStreamBasicDescription) throws {
        self.audioFileRef = audioFileRef
        self.clientASBD = clientASBD

        var length: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        let err = ExtAudioFileGetProperty(audioFileRef, kExtAudioFileProperty_FileLengthFrames, &size, &length)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        lengthInFrames = length
    }

    func read(into buffer: UnsafeMutablePointer<Float32>, frameCount: UInt32) throws -> UInt32 {
        var frames = frameCount

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: clientASBD.mChannelsPerFrame,
                mDataByteSize: frameCount * clientASBD.mBytesPerFrame,
                mData: buffer
            )
        )

        let err = ExtAudioFileRead(audioFileRef, &frames, &bufferList)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        return frames
    }

    func rewind() throws {
        let err = ExtAudioFileSeek(audioFileRef, 0)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
    }
}
