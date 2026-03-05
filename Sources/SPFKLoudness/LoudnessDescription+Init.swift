// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Foundation
import SPFKAudioBase

extension LoudnessDescription {
    /// Analyzes the audio file at `url` and populates all five EBU R128 loudness metrics.
    ///
    /// Very short files (under 5 seconds) are looped in-memory so that libebur128 has
    /// enough material for a stable integrated loudness measurement.
    ///
    /// The raw measurement values are passed through ``validated()`` before assignment,
    /// which clears any metrics that fall outside the representable range (±99.99).
    ///
    /// - Parameter url: A file URL for any audio format supported by Core Audio.
    /// - Throws: If the file cannot be opened or decoded.
    public init(parsing url: URL) async throws {
        self = try LoudnessAnalyzer.analyze(url: url, minimumDuration: 5).validated()
    }
}
