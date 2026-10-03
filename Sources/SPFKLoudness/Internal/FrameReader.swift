// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AudioToolbox
import Foundation

/// Supplies interleaved Float32 frames to ``audioConverterCallback``.
protocol FrameReader: AnyObject {
    /// Frames in the source, or 0 when it cannot be known before reading.
    var lengthInFrames: Int64 { get }

    /// Reads up to `frameCount` frames into `buffer` and returns how many were written; 0 at the end.
    func read(into buffer: UnsafeMutablePointer<Float32>, frameCount: UInt32) throws -> UInt32

    /// Restarts reading from the first frame, for a short file that is looped.
    func rewind() throws
}

/// The object state of one analysis, carried through ``CallbackContext``, which the converter
/// receives as untyped memory and so cannot hold an object reference itself.
///
/// A C callback cannot throw, so a reader's error is parked in ``error`` and rethrown by the driver.
final class AnalysisHandle {
    let reader: any FrameReader
    var error: (any Error)?
    var gatingBlocks = LoudnessGatingBlocks()

    init(reader: any FrameReader) {
        self.reader = reader
    }
}
