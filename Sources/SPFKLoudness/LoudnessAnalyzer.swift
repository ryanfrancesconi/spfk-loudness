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
/// All resources are cleaned up via `defer` — the audio file, converter, ebur128 state,
/// and scratch buffers are released regardless of how the function exits.
public enum LoudnessAnalyzer {
    /// Default read buffer size in frames. Sized for one second at 192 kHz.
    private static let defaultBufferSize: UInt32 = 192_000

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

    /// Oversamples, measures and assembles the result for any ``FrameReader``.
    static func measure(
        reader: any FrameReader,
        clientASBD: AudioStreamBasicDescription,
        loops: Bool,
        minimumDuration: TimeInterval?,
        isCancelled: @Sendable () -> Bool
    ) throws -> LoudnessMeasurement {
        let overSamplingFactor: UInt32 = if clientASBD.mSampleRate <= 48000 {
            4
        } else if clientASBD.mSampleRate <= 96000 {
            2
        } else {
            1
        }

        let converter = try createConverter(clientASBD: clientASBD, overSamplingFactor: overSamplingFactor)
        defer { AudioConverterDispose(converter.ref) }
        defer { converter.inputBuffer.deallocate() }
        defer { converter.outputBuffer.deallocate() }

        let state = try createEBUR128State(channelCount: clientASBD.mChannelsPerFrame, sampleRate: clientASBD.mSampleRate)
        defer {
            var mutableState: UnsafeMutablePointer<ebur128_state>? = state
            ebur128_destroy(&mutableState)
        }

        let channelMap = reader.channelLabels
            .flatMap(ChannelMap.ebur128Channels(for:))
            .flatMap { $0.count == Int(clientASBD.mChannelsPerFrame) ? $0 : nil }

        for (index, channel) in (channelMap ?? []).enumerated() {
            ebur128_set_channel(state, UInt32(index), channel)
        }

        let handle = AnalysisHandle(reader: reader)

        var context = makeContext(
            handle: handle,
            fileOutBuffer: converter.inputBuffer,
            state: state,
            clientASBD: clientASBD,
            loops: loops,
            minimumDuration: minimumDuration
        )

        let maxTruePeak = try withExtendedLifetime(handle) {
            try processAudio(
                converterRef: converter.ref,
                context: &context,
                handle: handle,
                converterOutASBD: converter.outputASBD,
                converterOutBuffer: converter.outputBuffer,
                framesPerIteration: converter.outputFrameCount,
                isCancelled: isCancelled
            )
        }

        return LoudnessMeasurement(
            description: extractResults(state: state, context: context, maxTruePeak: maxTruePeak),
            gatingBlocks: handle.gatingBlocks,
            usesDeclaredChannelLayout: channelMap != nil
        )
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
    private struct ConverterResources {
        let ref: AudioConverterRef
        let outputASBD: AudioStreamBasicDescription
        let inputBuffer: UnsafeMutablePointer<Float32>
        let outputBuffer: UnsafeMutablePointer<UInt8>
        let outputFrameCount: UInt32
    }

    /// Creates an `AudioConverter` for oversampling and allocates the input/output buffers.
    private static func createConverter(
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
    private static func createEBUR128State(channelCount: UInt32, sampleRate: Float64) throws -> UnsafeMutablePointer<ebur128_state> {
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
    private static func makeContext(
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

    /// Drives the `AudioConverter`, feeding decoded audio through the callback and tracking true peak.
    ///
    /// `isCancelled` is polled per iteration rather than inside the callback: ``CallbackContext``
    /// is handed to `AudioConverterFillComplexBuffer` as untyped memory and so cannot hold an
    /// object reference. One iteration bounds the latency at the cost of `framesPerIteration`.
    ///
    /// - Returns: The maximum true-peak sample magnitude (linear scale, pre-dBTP conversion).
    private static func processAudio(
        converterRef: AudioConverterRef,
        context: inout CallbackContext,
        handle: AnalysisHandle,
        converterOutASBD: AudioStreamBasicDescription,
        converterOutBuffer: UnsafeMutablePointer<UInt8>,
        framesPerIteration: UInt32,
        isCancelled: @Sendable () -> Bool
    ) throws -> Float32 {
        var maxTruePeak: Float32 = 0

        var converterOutBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: converterOutASBD.mChannelsPerFrame,
                mDataByteSize: framesPerIteration * converterOutASBD.mBytesPerFrame,
                mData: converterOutBuffer
            )
        )

        repeat {
            if isCancelled() { throw CancellationError() }

            var framesToRead = framesPerIteration

            converterOutBufferList.mBuffers.mDataByteSize = framesPerIteration * converterOutASBD.mBytesPerFrame
            converterOutBufferList.mBuffers.mData = UnsafeMutableRawPointer(converterOutBuffer)

            let err = AudioConverterFillComplexBuffer(
                converterRef,
                audioConverterCallback,
                &context,
                &framesToRead,
                &converterOutBufferList,
                nil
            )

            if let error = handle.error {
                throw error
            }

            if err != noErr, err != kAudioConverterErr_InvalidInputSize {
                throw osStatusError(err)
            }

            if framesToRead > 0 {
                let samples = converterOutBufferList.mBuffers.mData!
                    .assumingMemoryBound(to: Float32.self)
                let nChannels = converterOutBufferList.mBuffers.mNumberChannels

                var blockMax: Float32 = 0
                vDSP_maxmgv(samples, 1, &blockMax, vDSP_Length(framesToRead * nChannels))

                if blockMax > maxTruePeak {
                    maxTruePeak = blockMax
                }
            }

            if framesToRead == 0 { break }

        } while context.fileFramesRead < context.targetFrames

        return maxTruePeak
    }

    /// Queries libebur128 for final metrics and assembles a ``LoudnessDescription``.
    private static func extractResults(
        state: UnsafeMutablePointer<ebur128_state>,
        context: CallbackContext,
        maxTruePeak: Float32
    ) -> LoudnessDescription {
        var il: Float64 = 0
        ebur128_loudness_global(state, &il)
        il = rint(100 * il) / 100

        var lra: Float64 = 0
        ebur128_loudness_range(state, &lra)
        lra = rint(100 * lra) / 100

        let truePeakDBTP = rintf(100 * 20 * log10(maxTruePeak)) / 100

        let maxMomentaryLoudness = context.hasMomentary
            ? rint(100 * context.maxMomentary) / 100
            : .nan

        let maxShortTermLoudness = context.hasShortTerm
            ? rint(100 * context.maxShortTerm) / 100
            : .nan

        return LoudnessDescription(
            loudnessIntegrated: il,
            loudnessRange: lra,
            maxTruePeakLevel: truePeakDBTP,
            maxMomentaryLoudness: maxMomentaryLoudness,
            maxShortTermLoudness: maxShortTermLoudness
        )
    }

    private static func osStatusError(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
