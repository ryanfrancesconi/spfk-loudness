// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AudioToolbox
import Foundation
import SPFKLoudnessC

/// `AudioConverterComplexInputDataProc` that supplies decoded PCM frames to the
/// sample-rate converter. On each invocation it reads a chunk from the source file,
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
