// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AudioToolbox
import Foundation
import SPFKLoudnessC

/// `AudioConverterComplexInputDataProc` that supplies decoded PCM frames to the
/// sample-rate converter. On each invocation it reads a chunk from the source,
/// feeds the frames to libebur128 in 100 ms segments, and updates the running-max
/// momentary/short-term loudness in ``CallbackContext``.
let audioConverterCallback: AudioConverterComplexInputDataProc = {
    _,
        ioNumberDataPackets,
        ioData,
        _,
        inUserData in
    guard let inUserData else { return OSStatus(kAudio_ParamError) }
    let context = inUserData.assumingMemoryBound(to: CallbackContext.self)

    let converterInASBD = context.pointee.converterInASBD
    let fileOutBuffer = context.pointee.fileOutBuffer
    let handle = context.pointee.reader.takeUnretainedValue()
    var framesInFileOutBuffer: UInt32

    do {
        framesInFileOutBuffer = try handle.reader.read(into: fileOutBuffer, frameCount: ioNumberDataPackets.pointee)

        // Handle looping: if we hit EOF but haven't reached the target, rewind
        if framesInFileOutBuffer == 0, context.pointee.loops,
           context.pointee.fileFramesRead < context.pointee.targetFrames
        {
            try handle.reader.rewind()
            framesInFileOutBuffer = try handle.reader.read(into: fileOutBuffer, frameCount: ioNumberDataPackets.pointee)
        }
    } catch {
        handle.error = error
        return OSStatus(kAudioConverterErr_UnspecifiedError)
    }

    context.pointee.fileFramesRead += Int64(framesInFileOutBuffer)

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
