// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Accelerate
import AudioToolbox
import Foundation
import SPFKAudioBase
import SPFKLoudnessC

/// Performs EBU R128 loudness analysis on an audio file.
///
/// Uses Core Audio (`ExtAudioFile` + `AudioConverter`) for decoding and sample-rate
/// conversion, and libebur128 for the actual loudness measurement. The audio is
/// oversampled (4x for ≤48 kHz, 2x for ≤96 kHz, 1x above) to enable ITU-R BS.1770-4
/// true peak detection. True peak scanning uses `vDSP_maxmgv` for vectorized throughput.
///
/// The converter, ebur128 state and scratch buffers belong to one analysis and are released with it.
public enum LoudnessAnalyzer {
    /// Default read buffer size in frames. Sized for one second at 192 kHz.
    static let defaultBufferSize: UInt32 = 192_000

    /// Analyzes the audio file at `url` and returns its EBU R128 loudness metrics.
    ///
    /// When `minimumDuration` is greater than zero and the file is shorter than half
    /// that, the audio is looped so that libebur128 has enough material for a stable
    /// integrated loudness measurement.
    ///
    /// Reads the file's first audio track. Containers `ExtAudioFile` cannot open (Ogg, Matroska,
    /// MXF) and other tracks go through ``analyze(pcmSource:minimumDuration:isCancelled:)``.
    ///
    /// - Parameters:
    ///   - url: A file URL pointing to any format readable by `ExtAudioFile`
    ///     (WAV, AIFF, CAF, MP3, AAC, FLAC, etc.).
    ///   - minimumDuration: The minimum number of seconds of audio to feed to
    ///     libebur128. Files shorter than half this are looped to reach it.
    ///     Pass `nil` (the default) to disable looping.
    ///   - isCancelled: Polled during the decode loop; returning `true` throws
    ///     `CancellationError`. The default reads the calling task, which is what a caller
    ///     inside a `Task` wants; pass a closure to drive it deterministically from a test.
    /// - Returns: A ``LoudnessDescription`` containing integrated loudness, loudness range,
    ///   max true peak, max momentary loudness, and max short-term loudness.
    /// - Throws: `CancellationError` when `isCancelled` fires, or an `NSError` with
    ///   `NSOSStatusErrorDomain` if the file cannot be opened, its format cannot be read,
    ///   or the audio converter fails.
    public static func analyze(
        url: URL,
        minimumDuration: TimeInterval? = nil,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> LoudnessDescription {
        try measure(url: url, minimumDuration: minimumDuration, isCancelled: isCancelled).description
    }

    /// ``analyze(url:minimumDuration:isCancelled:)`` with the gating blocks the integrated value
    /// came from, for measuring a set of files together.
    public static func measure(
        url: URL,
        minimumDuration: TimeInterval? = nil,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> LoudnessMeasurement {
        let reader = try ExtAudioFileFrameReader(url: url)
        let clientASBD = reader.clientASBD

        return try measure(
            reader: reader,
            clientASBD: clientASBD,
            loops: loops(lengthInFrames: reader.lengthInFrames, sampleRate: clientASBD.mSampleRate, minimumDuration: minimumDuration),
            minimumDuration: minimumDuration,
            isCancelled: isCancelled
        )
    }

    /// Oversamples, measures and assembles the result for a ``FrameReader`` that never starves.
    static func measure(
        reader: any FrameReader,
        clientASBD: AudioStreamBasicDescription,
        loops: Bool,
        minimumDuration: TimeInterval?,
        isCancelled: @Sendable () -> Bool
    ) throws -> LoudnessMeasurement {
        let session = try AnalysisSession(reader: reader, clientASBD: clientASBD, loops: loops, minimumDuration: minimumDuration)

        while true {
            if isCancelled() { throw CancellationError() }

            switch try session.convert() {
            case .produced: continue
            case .finished: return session.measurement
            case .starved: throw NSError(description: "A file reader reported no frames without reaching its end")
            }
        }
    }

    /// The same for a reader that has to be refilled between conversions, which is where its
    /// source is awaited: the converter pulls its input from a C callback that cannot.
    static func measure(
        reader: any FrameReader,
        clientASBD: AudioStreamBasicDescription,
        loops: Bool,
        minimumDuration: TimeInterval?,
        isCancelled: @Sendable () -> Bool,
        refill: () async throws -> Void
    ) async throws -> LoudnessMeasurement {
        let session = try AnalysisSession(reader: reader, clientASBD: clientASBD, loops: loops, minimumDuration: minimumDuration)

        while true {
            if isCancelled() { throw CancellationError() }

            switch try session.convert() {
            case .produced: continue
            case .finished: return session.measurement
            case .starved: try await refill()
            }
        }
    }

    /// Whether a source of `lengthInFrames` is short enough to be looped up to `minimumDuration`.
    static func loops(lengthInFrames: Int64, sampleRate: Float64, minimumDuration: TimeInterval?) -> Bool {
        let fileDuration = Double(lengthInFrames) / sampleRate

        guard let minimumDuration, minimumDuration > 0, fileDuration > 0 else { return false }

        return fileDuration * 2 < minimumDuration
    }
}

// MARK: - Private Helpers

extension LoudnessAnalyzer {
    /// Bundles the AudioConverter and its associated buffers.
    struct ConverterResources {
        let ref: AudioConverterRef
        let outputASBD: AudioStreamBasicDescription
        let inputBuffer: UnsafeMutablePointer<Float32>
        let outputBuffer: UnsafeMutablePointer<UInt8>
        let outputFrameCount: UInt32
        func dispose() {
            AudioConverterDispose(ref)
            inputBuffer.deallocate()
            outputBuffer.deallocate()
        }
    }

    /// Creates an `AudioConverter` for oversampling and allocates the input/output buffers.
    static func createConverter(
        clientASBD: AudioStreamBasicDescription,
        overSamplingFactor: UInt32
    ) throws -> ConverterResources {
        var converterInASBD = clientASBD
        var converterOutASBD = clientASBD
        converterOutASBD.mSampleRate = Float64(overSamplingFactor) * clientASBD.mSampleRate

        var converterRef: AudioConverterRef?
        var err = AudioConverterNew(&converterInASBD, &converterOutASBD, &converterRef)
        guard err == noErr, let converterRef else { throw osStatusError(err) }

        let outputFrameCount = overSamplingFactor * defaultBufferSize
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: Int(outputFrameCount * converterOutASBD.mBytesPerFrame)
        )

        // Ask the converter how large the input buffer needs to be
        var inputBufferSize = outputFrameCount * converterOutASBD.mBytesPerFrame
        var propSize = UInt32(MemoryLayout<UInt32>.size)

        err = AudioConverterGetProperty(
            converterRef,
            kAudioConverterPropertyCalculateInputBufferSize,
            &propSize,
            &inputBufferSize
        )
        guard err == noErr else {
            outputBuffer.deallocate()
            AudioConverterDispose(converterRef)
            throw osStatusError(err)
        }

        let inputBuffer = UnsafeMutablePointer<Float32>.allocate(
            capacity: Int(inputBufferSize) / MemoryLayout<Float32>.size
        )

        return ConverterResources(
            ref: converterRef,
            outputASBD: converterOutASBD,
            inputBuffer: inputBuffer,
            outputBuffer: outputBuffer,
            outputFrameCount: outputFrameCount
        )
    }

    /// Initializes a libebur128 state for integrated loudness and loudness range measurement.
    static func createEBUR128State(channelCount: UInt32, sampleRate: Float64) throws -> UnsafeMutablePointer<ebur128_state> {
        guard let state = ebur128_init(
            UInt32(channelCount),
            UInt(sampleRate),
            Int32(EBUR128_MODE_I.rawValue | EBUR128_MODE_LRA.rawValue)
        ) else {
            throw osStatusError(OSStatus(kAudio_MemFullError))
        }
        return state
    }

    /// Builds a ``CallbackContext``, including the target frame calculation for looping.
    ///
    /// A source of unknown length is read to its end.
    static func makeContext(
        handle: AnalysisHandle,
        fileOutBuffer: UnsafeMutablePointer<Float32>,
        state: UnsafeMutablePointer<ebur128_state>,
        clientASBD: AudioStreamBasicDescription,
        loops: Bool,
        minimumDuration: TimeInterval?
    ) -> CallbackContext {
        // libebur128's own rounding of 100 ms, so each interval ends on one of its block boundaries.
        let reportIntervalFrames = (UInt32(clientASBD.mSampleRate) + 5) / 10

        var context = CallbackContext(
            handle: Unmanaged.passUnretained(handle),
            fileOutBuffer: fileOutBuffer,
            state: state,
            neededFrames: reportIntervalFrames,
            reportIntervalFrames: reportIntervalFrames,
            converterInASBD: clientASBD
        )

        context.fileLengthInFrames = handle.reader.lengthInFrames
        context.loops = loops

        if loops, let minimumDuration {
            context.targetFrames = Int64(minimumDuration * clientASBD.mSampleRate)
        } else if context.fileLengthInFrames > 0 {
            context.targetFrames = context.fileLengthInFrames
        } else {
            context.targetFrames = .max
        }

        return context
    }

    static func osStatusError(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
