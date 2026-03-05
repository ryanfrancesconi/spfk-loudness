// Based on r128x by Manuel Naudin 2012-2013

#define DEFAULT_BUFFER_SIZE 192000

#include <math.h>
#include "AudioProcessor.h"

// MARK: - Callback

OSStatus eburAudioConvCallback(AudioConverterRef            inAudioConverter,
                               UInt32                       *ioNumberDataPackets,
                               AudioBufferList              *ioData,
                               AudioStreamPacketDescription **outDataPacketDescription,
                               void                         *inUserData) {
    OSStatus err = noErr;

    LoudnessData *userData = (LoudnessData *)inUserData;
    AudioStreamBasicDescription converterInASBD = userData->mConverterInASBD;

    UInt32 framesInFileOutBuffer = *ioNumberDataPackets;
    Float32 *fileOutBuffer = userData->mFileOutBuffer;
    AudioBufferList fileOutBufferList;
    fileOutBufferList.mNumberBuffers = 1;
    fileOutBufferList.mBuffers[0].mNumberChannels = converterInASBD.mChannelsPerFrame;
    fileOutBufferList.mBuffers[0].mDataByteSize = framesInFileOutBuffer * converterInASBD.mBytesPerFrame;
    fileOutBufferList.mBuffers[0].mData = fileOutBuffer;

    // read audio data from file
    ExtAudioFileRef *audioFileRef = userData->mAudioFileRef;

    err = ExtAudioFileRead(*audioFileRef,
                           &framesInFileOutBuffer,
                           &fileOutBufferList);

    if (err != noErr) {
        return err;
    }

    userData->mFileFramesRead += framesInFileOutBuffer;
    UInt32 framesInBuffer = framesInFileOutBuffer;
    UInt32 pushedFrames = 0;
    Float32 *offset;

    while (framesInBuffer >= userData->mNeededFrames) {
        offset = (fileOutBuffer + (pushedFrames * converterInASBD.mChannelsPerFrame));

        ebur128_add_frames_float(userData->mState,
                                 offset,
                                 (size_t)userData->mNeededFrames);

        double momentaryValue;
        ebur128_loudness_momentary(userData->mState, &momentaryValue);

        if (!isinf(momentaryValue) && momentaryValue <= 0) {
            if (!userData->hasMomentary || momentaryValue > userData->maxMomentary) {
                userData->maxMomentary = momentaryValue;
                userData->hasMomentary = true;
            }
        }

        double shortTermValue;
        ebur128_loudness_shortterm(userData->mState, &shortTermValue);

        if (!isinf(shortTermValue) && shortTermValue <= 0) {
            if (!userData->hasShortTerm || shortTermValue > userData->maxShortTerm) {
                userData->maxShortTerm = shortTermValue;
                userData->hasShortTerm = true;
            }
        }

        framesInBuffer -= userData->mNeededFrames;
        pushedFrames += userData->mNeededFrames;
        userData->mNeededFrames = userData->mReportIntervalFrames;
    }

    if (framesInBuffer > 0) {
        offset = (fileOutBuffer + (pushedFrames * converterInASBD.mChannelsPerFrame));
        ebur128_add_frames_float(userData->mState,
                                 offset,
                                 (size_t)framesInBuffer);
        userData->mNeededFrames -= framesInBuffer;
    }

    *ioNumberDataPackets = framesInFileOutBuffer;
    ioData->mBuffers[0].mData = fileOutBuffer;
    ioData->mBuffers[0].mDataByteSize = framesInFileOutBuffer * converterInASBD.mBytesPerFrame;
    return err;
}

// MARK: - Reader

OSStatus eburAudioReader(
    CFStringRef audioFilePath,
    double      *loudnessIntegrated,
    double      *loudnessRange,
    float       *maxTruePeakLevel,
    double      *maxMomentaryLoudness,
    double      *maxShortTermLoudness
    ) {
    OSStatus err = noErr;

    // Resources that need cleanup — initialize to safe defaults
    CFURLRef myFileRef = NULL;
    ExtAudioFileRef audioFileRef = NULL;
    AudioConverterRef converterRef = NULL;
    UInt8 *converterOutBuffer = NULL;
    Float32 *fileOutBuffer = NULL;
    ebur128_state *state = NULL;

    myFileRef = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                              audioFilePath,
                                              kCFURLPOSIXPathStyle,
                                              false);

    if (myFileRef == NULL) {
        err = kAudio_MemFullError;
        goto cleanup;
    }

    err = ExtAudioFileOpenURL(myFileRef, &audioFileRef);
    if (err != noErr) { goto cleanup; }

    CFRelease(myFileRef);
    myFileRef = NULL;

    // getting input file asbd
    AudioStreamBasicDescription inFileASBD;
    UInt32 propSize = sizeof(inFileASBD);

    err = ExtAudioFileGetProperty(audioFileRef,
                                  kExtAudioFileProperty_FileDataFormat,
                                  &propSize,
                                  &inFileASBD);
    if (err != noErr) { goto cleanup; }

    // setting ExtAudioFile client format
    AudioStreamBasicDescription clientASBD;
    clientASBD.mChannelsPerFrame = inFileASBD.mChannelsPerFrame;
    clientASBD.mSampleRate = inFileASBD.mSampleRate;
    clientASBD.mFormatID = kAudioFormatLinearPCM;
    clientASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    clientASBD.mBitsPerChannel = 32;
    clientASBD.mFramesPerPacket = 1;
    clientASBD.mBytesPerFrame = 4 * clientASBD.mChannelsPerFrame;
    clientASBD.mBytesPerPacket = clientASBD.mBytesPerFrame;
    propSize = sizeof(clientASBD);

    err = ExtAudioFileSetProperty(audioFileRef,
                                  kExtAudioFileProperty_ClientDataFormat,
                                  propSize,
                                  &clientASBD);
    if (err != noErr) { goto cleanup; }

    // setting AudioConverter in/out format
    AudioStreamBasicDescription converterInASBD = clientASBD;
    AudioStreamBasicDescription converterOutASBD = clientASBD;
    int overSamplingFactor;

    if (clientASBD.mSampleRate <= 48000) {
        overSamplingFactor = 4;
    } else if (clientASBD.mSampleRate <= 96000) {
        overSamplingFactor = 2;
    } else {
        overSamplingFactor = 1;
    }

    converterOutASBD.mSampleRate = overSamplingFactor * clientASBD.mSampleRate;

    err = AudioConverterNew(&converterInASBD,
                            &converterOutASBD,
                            &converterRef);
    if (err != noErr) { goto cleanup; }

    // setting AudioConverter out AudioBufferList
    UInt32 framesInConverterOutBuffer = overSamplingFactor * DEFAULT_BUFFER_SIZE;
    converterOutBuffer = (UInt8 *)malloc(framesInConverterOutBuffer * converterOutASBD.mBytesPerFrame);

    if (converterOutBuffer == NULL) {
        err = kAudio_MemFullError;
        goto cleanup;
    }

    AudioBufferList converterOutBufferList;
    converterOutBufferList.mNumberBuffers = 1;
    converterOutBufferList.mBuffers[0].mNumberChannels = converterOutASBD.mChannelsPerFrame;
    converterOutBufferList.mBuffers[0].mDataByteSize = framesInConverterOutBuffer * converterOutASBD.mBytesPerFrame;
    converterOutBufferList.mBuffers[0].mData = converterOutBuffer;

    // allocating intermediate buffer
    UInt32 converterInputBufferSize = converterOutBufferList.mBuffers[0].mDataByteSize;
    propSize = sizeof(UInt32);

    err = AudioConverterGetProperty(converterRef,
                                    kAudioConverterPropertyCalculateInputBufferSize,
                                    &propSize,
                                    &converterInputBufferSize);
    if (err != noErr) { goto cleanup; }

    fileOutBuffer = (Float32 *)malloc(converterInputBufferSize);

    if (fileOutBuffer == NULL) {
        err = kAudio_MemFullError;
        goto cleanup;
    }

    // setting userData
    LoudnessData userData = {};

    userData.mAudioFileRef = &audioFileRef;

    state = ebur128_init(
        clientASBD.mChannelsPerFrame,
        clientASBD.mSampleRate,
        EBUR128_MODE_I | EBUR128_MODE_LRA
        );

    if (state == NULL) {
        err = kAudio_MemFullError;
        goto cleanup;
    }

    userData.mState = state;
    userData.mFileOutBuffer = fileOutBuffer;
    userData.mFileFramesRead = 0;
    userData.mFramesProduced = 0;
    userData.mReportIntervalFrames = clientASBD.mSampleRate / 10;
    userData.mNeededFrames = userData.mReportIntervalFrames;
    userData.mConverterInASBD = converterInASBD;
    userData.maxMomentary = 0;
    userData.maxShortTerm = 0;
    userData.hasMomentary = false;
    userData.hasShortTerm = false;

    UInt32 size = sizeof(SInt64);

    err = ExtAudioFileGetProperty(audioFileRef, kExtAudioFileProperty_FileLengthFrames, &size, &(userData.fileLengthInFrames));
    if (err != noErr) { goto cleanup; }

    Float32 maxTP = 0;

    // calling AudioConverterFillComplexBuffer
    UInt32 framesToRead;

    do {
        framesToRead = framesInConverterOutBuffer;

        err = AudioConverterFillComplexBuffer(converterRef,
                                              eburAudioConvCallback,
                                              &userData,
                                              &framesToRead,
                                              &converterOutBufferList,
                                              nil);

        if (err != noErr && err != kAudioConverterErr_InvalidInputSize) {
            goto cleanup;
        }

        if (framesToRead > 0) {
            Float32 *samples = (Float32 *)converterOutBufferList.mBuffers[0].mData;
            UInt32 nChannels = converterOutBufferList.mBuffers[0].mNumberChannels;
            userData.mFramesProduced += framesToRead;

            for (int i = 0; i < framesToRead; i++) {
                for (int j = 0; j < nChannels; j++) {
                    Float32 absVal = fabsf(samples[(nChannels * i) + j]);
                    if (absVal > maxTP) {
                        maxTP = absVal;
                    }
                }
            }
        }
    } while (framesToRead > 0 && (userData.mFileFramesRead < userData.fileLengthInFrames));

    // extract results
    double il, lra;

    *maxMomentaryLoudness = userData.hasMomentary ? rint(100 * userData.maxMomentary) / 100 : NAN;
    *maxShortTermLoudness = userData.hasShortTerm ? rint(100 * userData.maxShortTerm) / 100 : NAN;

    ebur128_loudness_global(userData.mState, &il);
    il = rint(100 * il) / 100;
    *loudnessIntegrated = il;

    ebur128_loudness_range(userData.mState, &lra);
    lra = rint(100 * lra) / 100;
    *loudnessRange = lra;

    maxTP = rintf(100 * 20 * log10(maxTP)) / 100;
    *maxTruePeakLevel = maxTP;

    if (err == kAudioConverterErr_InvalidInputSize) {
        err = noErr;
    }

cleanup:
    if (myFileRef != NULL) { CFRelease(myFileRef); }
    if (fileOutBuffer != NULL) { free(fileOutBuffer); }
    if (state != NULL) { ebur128_destroy(&state); }
    if (converterOutBuffer != NULL) { free(converterOutBuffer); }
    if (converterRef != NULL) { AudioConverterDispose(converterRef); }
    if (audioFileRef != NULL) { ExtAudioFileDispose(audioFileRef); }

    return err;
}
