// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-loudness

#import "LoudnessScanner.h"
#import "AudioProcessor.h"

/// A simple objc wrapper on top of the r128x wrapper for libebur128
@implementation LoudnessScanner

- (NSString *)description {
    return [NSString
        stringWithFormat:@"[LUFS: %.2f, Loudness Range: %.2f, True Peak: %.2f, "
                         @"Max Momentary: %.2f, Max Short-Term: %.2f]",
                         self.loudnessIntegrated, self.loudnessRange,
                         self.maxTruePeakLevel, self.maxMomentaryLoudness,
                         self.maxShortTermLoudness];
}

- (nullable instancetype)initWithPath:(nonnull NSString *)path {
    self = [super init];

    self.loudnessIntegrated = NAN;
    self.loudnessRange = NAN;
    self.maxTruePeakLevel = NAN;
    self.maxMomentaryLoudness = NAN;
    self.maxShortTermLoudness = NAN;

    if (![self measure:path]) {
        return nil;
    }

    return self;
}

- (bool)measure:(NSString *)path {
    Float64 loudnessIntegrated;
    Float64 loudnessRange;
    Float32 maxTruePeakLevel;
    Float64 maxMomentaryLoudness;
    Float64 maxShortTermLoudness;

    OSStatus readErr = eburAudioReader(
        (__bridge CFStringRef)(path), &loudnessIntegrated, &loudnessRange,
        &maxTruePeakLevel, &maxMomentaryLoudness, &maxShortTermLoudness);

    if (noErr != readErr) {
        NSLog(@"Failed to parse %@, with error %i", path, readErr);
        return false;
    }

    self.loudnessIntegrated = loudnessIntegrated;
    self.loudnessRange = loudnessRange;
    self.maxTruePeakLevel = maxTruePeakLevel;
    self.maxMomentaryLoudness = maxMomentaryLoudness;
    self.maxShortTermLoudness = maxShortTermLoudness;
    return true;
}

@end
