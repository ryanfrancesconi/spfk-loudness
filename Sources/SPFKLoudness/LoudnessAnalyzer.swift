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
    /// When `minimumDuration` is greater than zero and the file is shorter than that
    /// threshold, the audio is looped in-memory (via `ExtAudioFileSeek`) so that
    /// libebur128 has enough material for a stable integrated loudness measurement.
    ///
    /// - Parameters:
    ///   - url: A file URL pointing to any format readable by Core Audio
    ///     (WAV, AIFF, CAF, MP3, AAC, OGG, FLAC, etc.).
    ///   - minimumDuration: The minimum number of seconds of audio to feed to
    ///     libebur128. Files shorter than this are looped to reach the target.
    ///     Pass `nil` (the default) to disable looping.
    /// - Returns: A ``LoudnessDescription`` containing integrated loudness, loudness range,
    ///   max true peak, max momentary loudness, and max short-term loudness.
    /// - Throws: An `NSError` with `NSOSStatusErrorDomain` if the file cannot be
    ///   opened, its format cannot be read, or the audio converter fails.
    public static func analyze(url: URL, minimumDuration: TimeInterval? = nil) throws -> LoudnessDescription {
        let audioFileRef = try openAudioFile(url: url)
        defer { ExtAudioFileDispose(audioFileRef) }

        let clientASBD = try configureClientFormat(for: audioFileRef)

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

        var context = try makeContext(
            audioFileRef: audioFileRef,
            fileOutBuffer: converter.inputBuffer,
            state: state,
            clientASBD: clientASBD,
            minimumDuration: minimumDuration
        )

        let maxTruePeak = try processAudio(
            converterRef: converter.ref,
            context: &context,
            converterOutASBD: converter.outputASBD,
            converterOutBuffer: converter.outputBuffer,
            framesPerIteration: converter.outputFrameCount
        )

        return extractResults(state: state, context: context, maxTruePeak: maxTruePeak)
    }
}

// MARK: - Private Helpers

extension LoudnessAnalyzer {
    /// Opens an audio file for reading via Extended Audio File Services.
    private static func openAudioFile(url: URL) throws -> ExtAudioFileRef {
        var audioFileRef: ExtAudioFileRef?
        let err = ExtAudioFileOpenURL(url as CFURL, &audioFileRef)

        guard err == noErr, let audioFileRef else {
            throw NSError(
                domain: NSOSStatusErrorDomain, code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "Failed to open '\(url.lastPathComponent)' (OSStatus \(err))"]
            )
        }
        return audioFileRef
    }

    /// Reads the file's native format and sets the client format to Float32 interleaved PCM.
    private static func configureClientFormat(for audioFileRef: ExtAudioFileRef) throws -> AudioStreamBasicDescription {
        var inFileASBD = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        var err = ExtAudioFileGetProperty(
            audioFileRef,
            kExtAudioFileProperty_FileDataFormat,
            &propSize,
            &inFileASBD
        )
        guard err == noErr else { throw osStatusError(err) }

        var clientASBD = AudioStreamBasicDescription()
        clientASBD.mChannelsPerFrame = inFileASBD.mChannelsPerFrame
        clientASBD.mSampleRate = inFileASBD.mSampleRate
        clientASBD.mFormatID = kAudioFormatLinearPCM
        clientASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        clientASBD.mBitsPerChannel = 32
        clientASBD.mFramesPerPacket = 1
        clientASBD.mBytesPerFrame = 4 * clientASBD.mChannelsPerFrame
        clientASBD.mBytesPerPacket = clientASBD.mBytesPerFrame
        propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        err = ExtAudioFileSetProperty(
            audioFileRef,
            kExtAudioFileProperty_ClientDataFormat,
            propSize,
            &clientASBD
        )
        guard err == noErr else { throw osStatusError(err) }

        return clientASBD
    }

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

    /// Builds a ``CallbackContext``, including the file length query and target frame calculation for looping.
    private static func makeContext(
        audioFileRef: ExtAudioFileRef,
        fileOutBuffer: UnsafeMutablePointer<Float32>,
        state: UnsafeMutablePointer<ebur128_state>,
        clientASBD: AudioStreamBasicDescription,
        minimumDuration: TimeInterval?
    ) throws -> CallbackContext {
        let reportIntervalFrames = UInt32(clientASBD.mSampleRate / 10)

        var context = CallbackContext(
            audioFileRef: audioFileRef,
            fileOutBuffer: fileOutBuffer,
            state: state,
            neededFrames: reportIntervalFrames,
            reportIntervalFrames: reportIntervalFrames,
            converterInASBD: clientASBD
        )

        var size = UInt32(MemoryLayout<Int64>.size)
        let err = ExtAudioFileGetProperty(
            audioFileRef,
            kExtAudioFileProperty_FileLengthFrames,
            &size,
            &context.fileLengthInFrames
        )
        guard err == noErr else { throw osStatusError(err) }

        let fileDuration = Double(context.fileLengthInFrames) / clientASBD.mSampleRate

        if let minimumDuration,
           minimumDuration > 0,
           fileDuration > 0,
           fileDuration * 2 < minimumDuration
        {
            context.targetFrames = Int64(minimumDuration * clientASBD.mSampleRate)
        } else {
            context.targetFrames = context.fileLengthInFrames
        }

        return context
    }

    /// Drives the `AudioConverter`, feeding decoded audio through the callback and tracking true peak.
    ///
    /// - Returns: The maximum true-peak sample magnitude (linear scale, pre-dBTP conversion).
    private static func processAudio(
        converterRef: AudioConverterRef,
        context: inout CallbackContext,
        converterOutASBD: AudioStreamBasicDescription,
        converterOutBuffer: UnsafeMutablePointer<UInt8>,
        framesPerIteration: UInt32
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

            if err != noErr, err != kAudioConverterErr_InvalidInputSize {
                throw osStatusError(err)
            }

            if framesToRead > 0 {
                let samples = converterOutBufferList.mBuffers.mData!
                    .assumingMemoryBound(to: Float32.self)
                let nChannels = converterOutBufferList.mBuffers.mNumberChannels
                context.framesProduced += framesToRead

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
