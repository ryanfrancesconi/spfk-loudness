// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKLoudnessC
import SPFKUtils

extension LoudnessDescription {
    public init(parsing url: URL) async throws {
        let tmpfile: URL? = try? await AudioTools.createLoopedAudio(input: url, minimumDuration: 5)

        defer {
            if let tmpfile, tmpfile.exists {
                try? tmpfile.delete()
                Log.debug("Removed tmpfile at", tmpfile.path)
            }
        }

        let url = tmpfile ?? url

        guard let scanner = LoudnessScanner(path: url.path) else {
            throw NSError(description: "Failed to analyze '\(url.lastPathComponent)'")
        }

        self = LoudnessDescription(
            loudnessValue: scanner.loudnessValue.isFinite ? scanner.loudnessValue : nil,
            loudnessRange: scanner.loudnessRange.isFinite ? scanner.loudnessRange : nil,
            maxTruePeakLevel: scanner.maxTruePeakLevel.isFinite ? scanner.maxTruePeakLevel : nil,
            maxMomentaryLoudness: scanner.maxMomentaryLoudness.isFinite ? scanner.maxMomentaryLoudness : nil,
            maxShortTermLoudness: scanner.maxShortTermLoudness.isFinite ? scanner.maxShortTermLoudness : nil
        )
    }
}
