// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Accelerate
import AudioToolbox
import Foundation
import SPFKLoudnessC

// MARK: - Result

struct LoudnessResult {
    var loudnessIntegrated: Float64
    var loudnessRange: Float64
    var maxTruePeakLevel: Float32
    var maxMomentaryLoudness: Float64
    var maxShortTermLoudness: Float64
}

// MARK: - Callback Context

/// Mirrors the C `LoudnessData` struct, passed as `inUserData` to the AudioConverter callback.
private struct CallbackContext {
    var audioFileRef: ExtAudioFileRef
    var fileOutBuffer: UnsafeMutablePointer<Float32>
    var state: UnsafeMutablePointer<ebur128_state>
    var fileFramesRead: UInt32 = 0
    var framesProduced: UInt32 = 0
    var neededFrames: UInt32
    var reportIntervalFrames: UInt32
    var fileLengthInFrames: Int64 = 0
    var converterInASBD: AudioStreamBasicDescription
    var maxMomentary: Float64 = 0
    var maxShortTerm: Float64 = 0
    var hasMomentary: Bool = false
    var hasShortTerm: Bool = false
}

// MARK: - AudioConverter Callback

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

private let defaultBufferSize: UInt32 = 192000

enum LoudnessAnalyzer {
    static func analyze(url: URL) throws -> LoudnessResult {
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

        } while context.fileFramesRead < context.fileLengthInFrames

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
