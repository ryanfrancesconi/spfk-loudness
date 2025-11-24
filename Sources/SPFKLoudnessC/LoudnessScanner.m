// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/SPFKLoudness

// A simple object wrapper on top of the r128x wrapper for libebur128

#import "ExtAudioProcessor.h"
#import "LoudnessScanner.h"

@implementation LoudnessScanner

- (NSString *)description {
    return [NSString stringWithFormat:@"[%@ LUFS: %f, Loudness Range: %f, True Peak: %f]",
            self.className,
            self.lufs,
            self.loudnessRange,
            self.truePeak];
}

- (id)initWithPath:(NSString *)path {
    self = [super init];

    [self measure:path];

    return self;
}

- (void)measure:(NSString *)path {
    Float64 il, lra;
    Float32 max_tp;

    if (noErr != ExtAudioReader((__bridge CFStringRef)(path), &il, &lra, &max_tp)) {
        // failed to parse this file
        self.lufs = NAN;
        self.loudnessRange = NAN;
        self.truePeak = NAN;
        return;
    }

    self.lufs = il;
    self.loudnessRange = lra;
    self.truePeak = max_tp;
}

@end
