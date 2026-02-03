// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

// A helper object wrapper on top of the r128x wrapper to libebur128

#import <Foundation/Foundation.h>

@interface LoudnessScanner : NSObject

@property Float64 loudnessIntegrated;
@property Float64 loudnessRange;
@property Float32 maxTruePeakLevel;
@property Float64 maxMomentaryLoudness;
@property Float64 maxShortTermLoudness;

- (nullable id)initWithPath:(nonnull NSString *)path;

@end
