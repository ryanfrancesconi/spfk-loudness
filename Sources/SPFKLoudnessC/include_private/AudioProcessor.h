// Based on r128x by Manuel Naudin 2012-2013

#ifndef audioprocessor_h
#define audioprocessor_h

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include "ebur128.h"

typedef struct LoudnessData {
    ExtAudioFileRef *mAudioFileRef;
    Float32 *mFileOutBuffer;
    ebur128_state *mState;
    UInt32 mFileFramesRead;
    UInt32 mFramesProduced;
    UInt32 mNeededFrames;
    UInt32 mReportIntervalFrames;
    SInt64 fileLengthInFrames;
    AudioStreamBasicDescription mConverterInASBD;
    double maxMomentary;
    double maxShortTerm;
    bool hasMomentary;
    bool hasShortTerm;
} LoudnessData;

OSStatus
eburAudioConvCallback(AudioConverterRef            inAudioConverter,
                      UInt32                       *ioNumberDataPackets,
                      AudioBufferList              *ioData,
                      AudioStreamPacketDescription **outDataPacketDescription,
                      void                         *inUserData);

OSStatus
eburAudioReader(CFStringRef audioFilePath,
                double      *loudnessValue,
                double      *loudnessRange,
                Float32     *maxTruePeakLevel,
                double      *maxMomentaryLoudness,
                double      *maxShortTermLoudness);

#endif // !audioprocessor_h
