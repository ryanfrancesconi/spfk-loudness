// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-loudness

// A simple object wrapper on top of the r128x wrapper for libebur128

#import "AudioProcessor.h"
#import "LoudnessScanner.h"

@implementation LoudnessScanner

- (NSString *)description {
    return [NSString
            stringWithFormat:@"[%@ LUFS: %f, Loudness Range: %f, True Peak: %f]",
            self.className, self.loudnessValue, self.loudnessRange,
            self.maxTruePeakLevel];
}

- (id)initWithPath:(NSString *)path {
    self = [super init];

    [self measure:path];

    return self;
}

- (void)measure:(NSString *)path {
    Float64 loudnessValue;
    Float64 loudnessRange;
    Float32 maxTruePeakLevel;
    Float64 maxMomentaryLoudness;
    Float64 maxShortTermLoudness;

    if (noErr != eburAudioReader(
            (__bridge CFStringRef)(path),
            &loudnessValue,
            &loudnessRange,
            &maxTruePeakLevel,
            &maxMomentaryLoudness,
            &maxShortTermLoudness)
        ) {
        // failed to parse this file
        self.loudnessValue = NAN;
        self.loudnessRange = NAN;
        self.maxTruePeakLevel = NAN;
        self.maxMomentaryLoudness = NAN;
        self.maxShortTermLoudness = NAN;
        return;
    }

    self.loudnessValue = loudnessValue;
    self.loudnessRange = loudnessRange;
    self.maxTruePeakLevel = maxTruePeakLevel;
    self.maxMomentaryLoudness = maxMomentaryLoudness;
    self.maxShortTermLoudness = maxShortTermLoudness;
}

@end
