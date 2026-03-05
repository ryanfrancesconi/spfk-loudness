// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Accelerate
import AudioToolbox
import Foundation
import SPFKLoudnessC

// MARK: - Result

/// The five EBU R128 loudness metrics produced by ``LoudnessAnalyzer``.
struct LoudnessResult {
    /// Integrated loudness (LUFS) — the overall program loudness per BS.1770-4.
    var loudnessIntegrated: Float64
    /// Loudness range (LU) — the distribution spread per EBU Tech 3342.
    var loudnessRange: Float64
    /// Maximum true peak level (dBTP) — derived from oversampled sample magnitudes.
    var maxTruePeakLevel: Float32
    /// Highest momentary loudness (LUFS) — the running max of 400 ms windows.
    var maxMomentaryLoudness: Float64
    /// Highest short-term loudness (LUFS) — the running max of 3 s windows.
    var maxShortTermLoudness: Float64
}

// MARK: - Callback Context

/// Mutable state shared between the ``AudioConverterComplexInputDataProc`` callback and
/// the main processing loop. Passed as `inUserData` via `UnsafeMutablePointer`.
///
/// The callback reads audio from ``audioFileRef``, feeds it to libebur128 in 100 ms
/// chunks, and tracks the running-max momentary and short-term loudness values.
private struct CallbackContext {
    /// The open audio file being read.
    var audioFileRef: ExtAudioFileRef
    /// Scratch buffer for decoded Float32 PCM frames (owned by the caller).
    var fileOutBuffer: UnsafeMutablePointer<Float32>
    /// The libebur128 analysis state.
    var state: UnsafeMutablePointer<ebur128_state>
    /// Total frames consumed from the file so far.
    var fileFramesRead: UInt32 = 0
    /// Total oversampled frames produced by the converter so far.
    var framesProduced: UInt32 = 0
    /// Frames remaining before the next 100 ms ebur128 measurement boundary.
    var neededFrames: UInt32
    /// Number of frames in a 100 ms interval at the file's sample rate.
    var reportIntervalFrames: UInt32
    /// Total frame count of the source file.
    var fileLengthInFrames: Int64 = 0
    /// Total frames to process (equals ``fileLengthInFrames`` when not looping,
    /// or a higher value representing the looped target duration).
    var targetFrames: Int64 = 0
    /// The ASBD describing the Float32 PCM client format (pre-oversampling).
    var converterInASBD: AudioStreamBasicDescription
    /// Running maximum of 400 ms momentary loudness readings.
    var maxMomentary: Float64 = 0
    /// Running maximum of 3 s short-term loudness readings.
    var maxShortTerm: Float64 = 0
    /// Whether at least one valid momentary reading has been captured.
    var hasMomentary: Bool = false
    /// Whether at least one valid short-term reading has been captured.
    var hasShortTerm: Bool = false
}

// MARK: - AudioConverter Callback

/// `AudioConverterComplexInputDataProc` that supplies decoded PCM frames to the
/// sample-rate converter. On each invocation it reads a chunk from the source file,
/// feeds the frames to libebur128 in 100 ms segments, and updates the running-max
/// momentary/short-term loudness in ``CallbackContext``.
private let audioConverterCallback: AudioConverterComplexInputDataProc = {
    _,
    ioNumberDataPackets,
    ioData,
    _,
    inUserData in

    guard let inUserData else { return OSStatus(kAudio_ParamError) }
    let context = inUserData.assumingMemoryBound(to: CallbackContext.self)

    let converterInASBD = context.pointee.converterInASBD
    var framesInFileOutBuffer = ioNumberDataPackets.pointee
    let fileOutBuffer = context.pointee.fileOutBuffer

    var fileOutBufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: converterInASBD.mChannelsPerFrame,
            mDataByteSize: framesInFileOutBuffer * converterInASBD.mBytesPerFrame,
            mData: fileOutBuffer
        )
    )

    let err = ExtAudioFileRead(
        context.pointee.audioFileRef,
        &framesInFileOutBuffer,
        &fileOutBufferList
    )

    if err != noErr { return err }

    // Handle looping: if we hit EOF but haven't reached the target, seek back
    if framesInFileOutBuffer == 0, context.pointee.fileFramesRead < context.pointee.targetFrames {
        let seekErr = ExtAudioFileSeek(context.pointee.audioFileRef, 0)
        if seekErr != noErr { return seekErr }

        framesInFileOutBuffer = ioNumberDataPackets.pointee
        fileOutBufferList.mBuffers.mDataByteSize = framesInFileOutBuffer * converterInASBD.mBytesPerFrame
        fileOutBufferList.mBuffers.mData = UnsafeMutableRawPointer(fileOutBuffer)

        let rereadErr = ExtAudioFileRead(
            context.pointee.audioFileRef,
            &framesInFileOutBuffer,
            &fileOutBufferList
        )
        if rereadErr != noErr { return rereadErr }
    }

    context.pointee.fileFramesRead += framesInFileOutBuffer

    var framesInBuffer = framesInFileOutBuffer
    var pushedFrames: UInt32 = 0

    while framesInBuffer >= context.pointee.neededFrames {
        let offset = fileOutBuffer.advanced(by: Int(pushedFrames * converterInASBD.mChannelsPerFrame))

        ebur128_add_frames_float(
            context.pointee.state,
            offset,
            Int(context.pointee.neededFrames)
        )

        var momentaryValue: Float64 = 0
        ebur128_loudness_momentary(context.pointee.state, &momentaryValue)

        if !momentaryValue.isInfinite, momentaryValue <= 0 {
            if !context.pointee.hasMomentary || momentaryValue > context.pointee.maxMomentary {
                context.pointee.maxMomentary = momentaryValue
                context.pointee.hasMomentary = true
            }
        }

        var shortTermValue: Float64 = 0
        ebur128_loudness_shortterm(context.pointee.state, &shortTermValue)

        if !shortTermValue.isInfinite, shortTermValue <= 0 {
            if !context.pointee.hasShortTerm || shortTermValue > context.pointee.maxShortTerm {
                context.pointee.maxShortTerm = shortTermValue
                context.pointee.hasShortTerm = true
            }
        }

        framesInBuffer -= context.pointee.neededFrames
        pushedFrames += context.pointee.neededFrames
        context.pointee.neededFrames = context.pointee.reportIntervalFrames
    }

    if framesInBuffer > 0 {
        let offset = fileOutBuffer.advanced(by: Int(pushedFrames * converterInASBD.mChannelsPerFrame))
        ebur128_add_frames_float(
            context.pointee.state,
            offset,
            Int(framesInBuffer)
        )
        context.pointee.neededFrames -= framesInBuffer
    }

    ioNumberDataPackets.pointee = framesInFileOutBuffer
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(fileOutBuffer)
    ioData.pointee.mBuffers.mDataByteSize = framesInFileOutBuffer * converterInASBD.mBytesPerFrame

    return noErr
}

// MARK: - Analyzer

/// Default read buffer size in frames. Sized for one second at 192 kHz.
private let defaultBufferSize: UInt32 = 192000

/// Performs EBU R128 loudness analysis on an audio file.
///
/// Uses Core Audio (`ExtAudioFile` + `AudioConverter`) for decoding and sample-rate
/// conversion, and libebur128 for the actual loudness measurement. The audio is
/// oversampled (4x for ≤48 kHz, 2x for ≤96 kHz, 1x above) to enable ITU-R BS.1770-4
/// true peak detection. True peak scanning uses `vDSP_maxmgv` for vectorized throughput.
///
/// All resources are cleaned up via `defer` — the audio file, converter, ebur128 state,
/// and scratch buffers are released regardless of how the function exits.
enum LoudnessAnalyzer {
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
    ///     Pass `0` (the default) to disable looping.
    /// - Returns: A ``LoudnessResult`` containing integrated loudness, loudness range,
    ///   max true peak, max momentary loudness, and max short-term loudness.
    /// - Throws: An `NSError` with `NSOSStatusErrorDomain` if the file cannot be
    ///   opened, its format cannot be read, or the audio converter fails.
    static func analyze(url: URL, minimumDuration: TimeInterval = 0) throws -> LoudnessResult {
        // Open audio file
        var audioFileRef: ExtAudioFileRef?
        var err = ExtAudioFileOpenURL(url as CFURL, &audioFileRef)

        guard err == noErr, let audioFileRef else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to open '\(url.lastPathComponent)' (OSStatus \(err))"])
        }

        defer { ExtAudioFileDispose(audioFileRef) }

        // Get input file format
        var inFileASBD = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        err = ExtAudioFileGetProperty(
            audioFileRef,
            kExtAudioFileProperty_FileDataFormat,
            &propSize,
            &inFileASBD
        )
        guard err == noErr else { throw osStatusError(err) }

        // Set client format: Float32 interleaved PCM
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

        // Oversampling factor for true peak detection
        let overSamplingFactor: UInt32
        if clientASBD.mSampleRate <= 48000 {
            overSamplingFactor = 4
        } else if clientASBD.mSampleRate <= 96000 {
            overSamplingFactor = 2
        } else {
            overSamplingFactor = 1
        }

        // Create AudioConverter
        let converterInASBD = clientASBD
        var converterOutASBD = clientASBD
        converterOutASBD.mSampleRate = Float64(overSamplingFactor) * clientASBD.mSampleRate

        var converterRef: AudioConverterRef?
        var converterInCopy = converterInASBD
        err = AudioConverterNew(&converterInCopy, &converterOutASBD, &converterRef)
        guard err == noErr, let converterRef else { throw osStatusError(err) }
        defer { AudioConverterDispose(converterRef) }

        // Allocate converter output buffer
        let framesInConverterOutBuffer = overSamplingFactor * defaultBufferSize
        let converterOutBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: Int(framesInConverterOutBuffer * converterOutASBD.mBytesPerFrame)
        )
        defer { converterOutBuffer.deallocate() }

        var converterOutBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: converterOutASBD.mChannelsPerFrame,
                mDataByteSize: framesInConverterOutBuffer * converterOutASBD.mBytesPerFrame,
                mData: converterOutBuffer
            )
        )

        // Calculate input buffer size
        var converterInputBufferSize = converterOutBufferList.mBuffers.mDataByteSize
        propSize = UInt32(MemoryLayout<UInt32>.size)

        err = AudioConverterGetProperty(
            converterRef,
            kAudioConverterPropertyCalculateInputBufferSize,
            &propSize,
            &converterInputBufferSize
        )
        guard err == noErr else { throw osStatusError(err) }

        let fileOutBuffer = UnsafeMutablePointer<Float32>.allocate(
            capacity: Int(converterInputBufferSize) / MemoryLayout<Float32>.size
        )
        defer { fileOutBuffer.deallocate() }

        // Initialize ebur128 state
        guard let state = ebur128_init(
            UInt32(clientASBD.mChannelsPerFrame),
            UInt(clientASBD.mSampleRate),
            Int32(EBUR128_MODE_I.rawValue | EBUR128_MODE_LRA.rawValue)
        ) else {
            throw osStatusError(OSStatus(kAudio_MemFullError))
        }
        defer {
            var mutableState: UnsafeMutablePointer<ebur128_state>? = state
            ebur128_destroy(&mutableState)
        }

        // Set up callback context
        let reportIntervalFrames = UInt32(clientASBD.mSampleRate / 10)
        var context = CallbackContext(
            audioFileRef: audioFileRef,
            fileOutBuffer: fileOutBuffer,
            state: state,
            neededFrames: reportIntervalFrames,
            reportIntervalFrames: reportIntervalFrames,
            converterInASBD: converterInASBD
        )

        // Get file length
        var size = UInt32(MemoryLayout<Int64>.size)
        err = ExtAudioFileGetProperty(
            audioFileRef,
            kExtAudioFileProperty_FileLengthFrames,
            &size,
            &context.fileLengthInFrames
        )
        guard err == noErr else { throw osStatusError(err) }

        // Compute target frames for looping short files
        let fileDuration = Double(context.fileLengthInFrames) / clientASBD.mSampleRate

        if minimumDuration > 0, fileDuration > 0, fileDuration < minimumDuration {
            context.targetFrames = Int64(minimumDuration * clientASBD.mSampleRate)
        } else {
            context.targetFrames = context.fileLengthInFrames
        }

        // Process audio
        var maxTP: Float32 = 0

        repeat {
            var framesToRead = framesInConverterOutBuffer

            // Reset converter output buffer for each iteration
            converterOutBufferList.mBuffers.mDataByteSize = framesInConverterOutBuffer * converterOutASBD.mBytesPerFrame
            converterOutBufferList.mBuffers.mData = UnsafeMutableRawPointer(converterOutBuffer)

            err = AudioConverterFillComplexBuffer(
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

                let totalSamples = Int(framesToRead * nChannels)
                var blockMax: Float32 = 0
                vDSP_maxmgv(samples, 1, &blockMax, vDSP_Length(totalSamples))
                if blockMax > maxTP {
                    maxTP = blockMax
                }
            }

            if framesToRead == 0 { break }

        } while context.fileFramesRead < context.targetFrames

        // Extract results
        var il: Float64 = 0
        var lra: Float64 = 0

        ebur128_loudness_global(state, &il)
        il = rint(100 * il) / 100

        ebur128_loudness_range(state, &lra)
        lra = rint(100 * lra) / 100

        maxTP = rintf(100 * 20 * log10(maxTP)) / 100

        let maxMomentaryLoudness = context.hasMomentary
            ? rint(100 * context.maxMomentary) / 100
            : .nan

        let maxShortTermLoudness = context.hasShortTerm
            ? rint(100 * context.maxShortTerm) / 100
            : .nan

        return LoudnessResult(
            loudnessIntegrated: il,
            loudnessRange: lra,
            maxTruePeakLevel: maxTP,
            maxMomentaryLoudness: maxMomentaryLoudness,
            maxShortTermLoudness: maxShortTermLoudness
        )
    }

    private static func osStatusError(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
