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

    //setting ExtAudioFile out AudioBufferList
    UInt32 framesInFileOutBuffer = *ioNumberDataPackets;
    AudioStreamBasicDescription converterInASBD;
    UInt32 propSize = sizeof(converterInASBD);

    err = AudioConverterGetProperty(inAudioConverter,
                                    kAudioConverterCurrentInputStreamDescription,
                                    &propSize,
                                    &converterInASBD);

    if (err != noErr) {
        return err;
    }

    LoudnessData *userData = (LoudnessData *)inUserData;
    Float32 *fileOutBuffer = userData->mFileOutBuffer;
    AudioBufferList fileOutBufferList;
    fileOutBufferList.mNumberBuffers = 1;
    fileOutBufferList.mBuffers[0].mNumberChannels = converterInASBD.mChannelsPerFrame;
    fileOutBufferList.mBuffers[0].mDataByteSize = framesInFileOutBuffer * converterInASBD.mBytesPerFrame;
    fileOutBufferList.mBuffers[0].mData = fileOutBuffer;

    //read audio data from file
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
            CFNumberRef cmom = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &momentaryValue);
            CFArrayAppendValue(userData->momentaryBlocks, cmom);
            CFRelease(cmom);
        }

        double shortTermValue;
        ebur128_loudness_shortterm(userData->mState, &shortTermValue);

        if (!isinf(shortTermValue) && shortTermValue <= 0) {
            CFNumberRef cst = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &shortTermValue);
            CFArrayAppendValue(userData->shortTermBlocks, cst);
            CFRelease(cst);
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

    ioNumberDataPackets = &framesInFileOutBuffer;
    ioData->mBuffers[0].mData = fileOutBuffer;
    ioData->mBuffers[0].mDataByteSize = framesInFileOutBuffer * converterInASBD.mBytesPerFrame;
    return err;
}

// MARK: - Reader

OSStatus eburAudioReader(
    CFStringRef audioFilePath,
    double      *loudnessValue,
    double      *loudnessRange,
    Float32     *maxTruePeakLevel,
    double      *maxMomentaryLoudness,
    double      *maxShortTermLoudness
    ) {
    //
    OSStatus err = noErr;
    CFURLRef myFileRef = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                       audioFilePath,
                                                       kCFURLPOSIXPathStyle,
                                                       false);
    ExtAudioFileRef audioFileRef;

    err = ExtAudioFileOpenURL(myFileRef, &audioFileRef);

    if (err != noErr) {
        return err;
    }

    CFRelease(myFileRef);

    // getting input file asbd
    AudioStreamBasicDescription inFileASBD;
    UInt32 propSize = sizeof(inFileASBD);

    err = ExtAudioFileGetProperty(audioFileRef,
                                  kExtAudioFileProperty_FileDataFormat,
                                  &propSize,
                                  &inFileASBD);

    if (err != noErr) {
        return err;
    }

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

    if (err != noErr) {
        return err;
    }

    //setting AudioConverter in/out format
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
    AudioConverterRef converterRef;

    err = AudioConverterNew(&converterInASBD,
                            &converterOutASBD,
                            &converterRef);

    if (err != noErr) {
        return err;
    }

    // setting AudioConverter out AudioBufferList
    UInt32 framesInConverterOutBuffer = overSamplingFactor * DEFAULT_BUFFER_SIZE;
    UInt8 *converterOutBuffer = (UInt8 *)malloc(framesInConverterOutBuffer * converterOutASBD.mBytesPerFrame);

    if (converterOutBuffer == NULL) {
        return 1;
    }

    AudioBufferList converterOutBufferList;
    converterOutBufferList.mNumberBuffers = 1;
    converterOutBufferList.mBuffers[0].mNumberChannels = converterOutASBD.mChannelsPerFrame;
    converterOutBufferList.mBuffers[0].mDataByteSize = framesInConverterOutBuffer * converterOutASBD.mBytesPerFrame;
    converterOutBufferList.mBuffers[0].mData = converterOutBuffer;

    //allocating intermediate buffer
    UInt32 converterInputBufferSize = converterOutBufferList.mBuffers[0].mDataByteSize;
    propSize = sizeof(UInt32);

    err = AudioConverterGetProperty(converterRef,
                                    kAudioConverterPropertyCalculateInputBufferSize,
                                    &propSize,
                                    &converterInputBufferSize);

    if (err != noErr) {
        return err;
    }

    Float32 *fileOutBuffer = (Float32 *)malloc(converterInputBufferSize);

    if (fileOutBuffer == NULL) {
        return 1;
    }

    //setting userData
    LoudnessData userData = {
        0
    };

    userData.mAudioFileRef = &audioFileRef;

    ebur128_state *state = ebur128_init(
        clientASBD.mChannelsPerFrame,
        clientASBD.mSampleRate,
        EBUR128_MODE_I | EBUR128_MODE_LRA
        );

    if (state == NULL) {
        return 1;
    }

    userData.mState = state;
    userData.mFileOutBuffer = fileOutBuffer;
    userData.mFileFramesRead = 0;
    userData.mFramesProduced = 0;
    userData.mReportIntervalFrames = clientASBD.mSampleRate / 10;
    userData.mNeededFrames = userData.mReportIntervalFrames;

    UInt32 size = sizeof(SInt64);

    err = ExtAudioFileGetProperty(audioFileRef, kExtAudioFileProperty_FileLengthFrames, &size, &(userData.fileLengthInFrames));

    if (err != noErr) {
        return err;
    }

    Float32 maxTP = 0;

    userData.momentaryBlocks = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    userData.shortTermBlocks = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);

    if (userData.momentaryBlocks == NULL || userData.shortTermBlocks == NULL) {
        return -1;
    }

    //calling AudioConverterFillComplexBuffer
    UInt32 framesToRead;

    do {
        framesToRead = framesInConverterOutBuffer;

        err = AudioConverterFillComplexBuffer(converterRef,
                                              eburAudioConvCallback,
                                              &userData,
                                              &framesToRead,
                                              &converterOutBufferList,
                                              nil);

        if (err != noErr && err != 'insz') {
            return err;
        }

        Float32 *samples = (Float32 *)converterOutBufferList.mBuffers[0].mData;
        UInt32 nChannels = converterOutBufferList.mBuffers[0].mNumberChannels;
        userData.mFramesProduced += framesToRead;

        for (int i = 0; i < framesToRead; i++) {
            for (int j = 0; j < nChannels; j++) {
                if (fabsf(samples[(nChannels * i) + j]) > maxTP) {
                    maxTP = fabsf(samples[(nChannels * i) + j]);
                }
            }
        }
    } while (framesToRead > 0 && (userData.mFileFramesRead < userData.fileLengthInFrames));

    double il, lra;

    *maxMomentaryLoudness = maxValue(userData.momentaryBlocks);
    *maxShortTermLoudness = maxValue(userData.shortTermBlocks);

    ebur128_loudness_global(userData.mState, &il);
    il = rint(100 * il) / 100;
    *loudnessValue = il;

    ebur128_loudness_range(userData.mState, &lra);
    lra = rint(100 * lra) / 100;
    *loudnessRange = lra;

    maxTP = rintf(100 * 20 * log10(maxTP)) / 100;
    *maxTruePeakLevel = maxTP;

    CFRelease(userData.momentaryBlocks);
    CFRelease(userData.shortTermBlocks);
    free(fileOutBuffer);
    ebur128_destroy(&state);
    free(converterOutBuffer);
    AudioConverterDispose(converterRef);
    ExtAudioFileDispose(audioFileRef);

    if (err == 'insz') {
        err = noErr;
    }

    return err;
}

double maxValue(CFMutableArrayRef blocks) {
    // CFShow(blocks);

    double highest = -100;
    CFIndex count = CFArrayGetCount(blocks);

    for (CFIndex i = 0; i < count; ++i) {
        CFNumberRef cfValue = (CFNumberRef)CFArrayGetValueAtIndex(blocks, i);

        double value;
        CFNumberGetValue(cfValue, kCFNumberDoubleType, &value);

        if (value > highest) {
            highest = value;
        }
    }

    highest = rint(100 * highest) / 100;

    return highest;
}
