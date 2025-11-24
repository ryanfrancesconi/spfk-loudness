// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/SPFKLoudness

// A helper object wrapper on top of the r128x wrapper to libebur128

#import <Foundation/Foundation.h>

@interface LoudnessScanner : NSObject

@property Float64 lufs;
@property Float64 loudnessRange;
@property Float32 truePeak;

- (id)initWithPath:(NSString *)path;

@end
