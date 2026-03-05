// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AudioToolbox
import Foundation
import SPFKLoudnessC

/// Mutable state shared between the ``AudioConverterComplexInputDataProc`` callback and
/// the main processing loop. Passed as `inUserData` via `UnsafeMutablePointer`.
///
/// The callback reads audio from ``audioFileRef``, feeds it to libebur128 in 100 ms
/// chunks, and tracks the running-max momentary and short-term loudness values.
struct CallbackContext {
    /// The open audio file being read.
    var audioFileRef: ExtAudioFileRef
    /// Scratch buffer for decoded Float32 PCM frames (owned by the caller).
    var fileOutBuffer: UnsafeMutablePointer<Float32>
    /// The libebur128 analysis state.
    var state: UnsafeMutablePointer<ebur128_state>
    /// Total frames consumed from the file so far.
    var fileFramesRead: UInt32 = 0
    /// Total oversampled frames produced by the converter so far.
    var framesProduced: UInt32 = 0
    /// Frames remaining before the next 100 ms ebur128 measurement boundary.
    var neededFrames: UInt32
    /// Number of frames in a 100 ms interval at the file's sample rate.
    var reportIntervalFrames: UInt32
    /// Total frame count of the source file.
    var fileLengthInFrames: Int64 = 0
    /// Total frames to process (equals ``fileLengthInFrames`` when not looping,
    /// or a higher value representing the looped target duration).
    var targetFrames: Int64 = 0
    /// The ASBD describing the Float32 PCM client format (pre-oversampling).
    var converterInASBD: AudioStreamBasicDescription
    /// Running maximum of 400 ms momentary loudness readings.
    var maxMomentary: Float64 = 0
    /// Running maximum of 3 s short-term loudness readings.
    var maxShortTerm: Float64 = 0
    /// Whether at least one valid momentary reading has been captured.
    var hasMomentary: Bool = false
    /// Whether at least one valid short-term reading has been captured.
    var hasShortTerm: Bool = false
}
