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
    UInt32 mReportIntervalFrames; // experimental block logging every interval
    SInt64 fileLengthInFrames;
    CFMutableArrayRef momentaryBlocks; // to store momentary blocks
    CFMutableArrayRef shortTermBlocks; // to store short-term blocks
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

double
maxValue(CFMutableArrayRef blocks);

#endif // !audioprocessor_h
